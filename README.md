# Tier-1 Single-Node Edge Medical Imaging Ingest

A single-node appliance that receives DICOM from local modalities, de-identifies
it on-node, and uploads it to XNAT. Part of
[NIF FDRI Stream 2](https://github.com/Australian-Imaging-Service).

One Ubuntu machine runs the whole pipeline on a single-node
[k0s](https://k0sproject.io/) cluster:

```
modality --C-STORE--> Orthanc (deid) --> xnat-ingest group-orthanc --> xnat-ingest assign --> xnat-ingest upload --> XNAT (HTTPS)
```

There is **no** SeaweedFS, **no** S3 hop, **no** k0smotron / child cluster /
konnectivity, **no** separate edge worker, **no** nginx-ingress, and **no**
cert-manager. Original DICOMs never leave the node; only de-identified data is
uploaded to XNAT. Optional observability (Loki + Prometheus + Grafana +
Alertmanager + Vector) runs natively on the same node.

Everything above is deployed by **one Helm chart**, `charts/edge`, configured by
**one file**, `sites/<site>/values.yaml`, plus that site's SOPS-encrypted
`secrets.enc.yaml`. There is no second, env-var-shaped configuration to keep in
step with it.

## Prerequisites

- **One Ubuntu node**: Ubuntu 22.04+, 8GB+ RAM, 100GB+ disk. This single machine
  runs k0s and every pipeline component.
- **One XNAT instance**: reachable over HTTPS, with a local (non-AAF/OIDC) service
  account and a pre-existing project for the sessions to land in. Scope that
  account to the projects in this site's AET map and nothing else — tier-1
  uploads from the same machine that faces the modalities, so the credential
  lives here.
- **DICOM source(s)**: one or more modalities on the local LAN that can C-STORE to
  this node on port **4242** with `AET=AISEDGE`. Each modality's Called-AET must
  appear in `orthanc.deid.aetMap` in your site file. An AET that is *not* listed
  is quarantined, not discarded (see below).
- **`AIS_DEID_HMAC_SALT`**: a per-deployment secret. Generate one with
  `openssl rand -hex 32` and put it in the `orthanc-deid-salt` Secret in
  `sites/<site>/secrets.enc.yaml`. Effectively permanent: rotating it
  re-pseudonymises every patient and silently breaks linkage to everything
  already in XNAT.
- **`sops` and `age`** on whichever machine edits the site secrets
  (`scripts/site-secrets.sh` refuses to run without them). `python3` with PyYAML
  is needed by `install.sh`, which reads the site file directly. `kubectl` and
  `helm` are installed by step 1 on a `fresh` install.
- **Outbound internet**: needed to pull the k0s binary and container images, and
  ongoing HTTPS to the XNAT server. The observability subcharts are *vendored*
  (`charts/edge/charts/*.tgz`), so no chart repository is contacted at install
  time.

## Quick Start

### The two files a site owns

Both live under `sites/<site>/` and are scaffolded from `sites/example-single/`.
Nothing else needs editing.

| File | What it holds | Scaffolded from |
|---|---|---|
| `sites/<site>/values.yaml` | The entire non-secret configuration: `nodeIP`, `installMode`, storage paths, `orthanc.deid.aetMap`, `orthanc.deid.profile`, loop intervals, `upload.mode: direct`, `dataPolicy`, `observability` | `sites/example-single/values.yaml` |
| `sites/<site>/secrets.enc.yaml` | Four Secrets, SOPS-encrypted, **all in namespace `xnat-ingest`**: `xnat-credentials` (server/username/password), `orthanc-deid-salt` (`AIS_DEID_HMAC_SALT`), `grafana-admin-credentials`, `alertmanager-smtp` | `sites/example-single/secrets.example.yaml` |

`sites/<site>/values.yaml` is safe to commit — it contains no credentials, only
Secret *names*. `secrets.enc.yaml` is committed **encrypted**; `git diff` then
shows which keys changed without showing their values.

You never edit `charts/edge/values.yaml`. That file holds the defaults and the
reasoning behind them; your site file holds the facts that are true of your site.

### Steps

```bash
# 1. Clone this repo on the node
git clone <repo-url> && cd k0s-k0smotron-mvp

# 2. One age key per operator, then make it a recipient in .sops.yaml
scripts/site-secrets.sh init-key
scripts/site-secrets.sh add-recipient age1...        # the public key it printed

# 3. Scaffold the site (copies sites/example-single/)
scripts/site-secrets.sh new my-hospital single

# 4. Fill in the two files
$EDITOR sites/my-hospital/values.yaml                # nodeIP, aetMap, deid profile
openssl rand -hex 32                                 # -> AIS_DEID_HMAC_SALT
$EDITOR sites/my-hospital/secrets.enc.yaml           # still PLAINTEXT at this point
scripts/site-secrets.sh encrypt my-hospital          # do not commit before this

# 5. Confirm the de-id policy, deliberately: set
#      orthanc.deid.policyReviewed: true
#    in sites/my-hospital/values.yaml. The chart REFUSES to render while it is
#    false and deid is on — nothing downstream re-checks what was removed.

# 6. Install
chmod +x install.sh scripts/*.sh
./install.sh my-hospital          # interactive
# or: ./install.sh -y my-hospital # non-interactive / CI (auto-confirm)
```

`install.sh` is three steps, and it reads `sites/<site>/values.yaml` for all of
them:

1. **single-node k0s** — `k0s install controller --single`, plus `kubectl`,
   `helm` and local-path (`scripts/01-install-k0s.sh`). Answer `s` at the prompt
   to skip it when the cluster already exists.
2. **site Secrets** — `scripts/site-secrets.sh apply <site>` creates any
   namespace the Secrets name and decrypts straight into the cluster through a
   pipe. Plaintext never touches disk. Secrets go **before** the workloads: a pod
   that starts without its Secret sits in `CreateContainerConfigError`.
3. **the chart** — `helm upgrade --install <site> charts/edge -n xnat-ingest
   --create-namespace -f sites/<site>/values.yaml`.

Architecture, data flow, security model, and component-by-component reference are
all below.

---

## Architecture

Everything runs on one node, in one namespace, from one Helm release. Modalities
C-STORE to Orthanc on the node's own IP (port 4242 on the local LAN). Orthanc
de-identifies in-process, keeps the deid'd instance, and backs up the original to
a node-local directory that never leaves the machine. `xnat-ingest group-orthanc`,
`xnat-ingest assign`, and `xnat-ingest upload` move the deid'd data to XNAT over
HTTPS. The only inbound port is DICOM 4242; the only outbound path is HTTPS to
XNAT (plus the Grafana NodePort for the local admin).

```
════════════════════════════════════════════════════════════════════════════════
  SINGLE NODE   (nodeIP)            inbound: DICOM :4242 (LAN)   outbound: :443 XNAT
════════════════════════════════════════════════════════════════════════════════

  Host directories  (the pipeline stages share ONE filesystem so hardlinks resolve)
    /data/xnat-ingest/orthanc-storage   deid'd DICOM instances (Orthanc storage)
    /data/xnat-ingest/grouped           grouped studies (group-orthanc output)
    /data/xnat-ingest/assigned          PROJECT.SUBJECT.SESSION/ dirs (assign output)
    /data/facility-backup               ORIGINAL DICOMs (real IDs) — never leaves node
      └─ __unmapped_aet__/<AET>/...     quarantine: AE title not in aetMap

  ┌─ namespace: xnat-ingest — one release of charts/edge ─────────────────────┐
  │   <rel>-orthanc      DICOM SCP :4242 (hostPort, AET=AISEDGE)               │
  │     Lua deidentify-and-forward.lua:                                        │
  │       OnStoredInstance  write ORIGINAL → /facility-backup, then /modify    │
  │                         per orthanc.deid.profile; keep only the deid'd copy│
  │       OnStableStudy     label study `xnat-ingest-ready`                    │
  │     env  AIS_DEID_HMAC_SALT (Secret orthanc-deid-salt)                     │
  │     REST :8042 (ClusterIP) — how group-orthanc pulls                       │
  │        │                                                                   │
  │        ▼  REST-pull labelled studies                                       │
  │   <rel>-group-orthanc  loop 60s; hardlinks deid'd DICOMs from              │
  │                        /data/orthanc-storage → /data/grouped               │
  │   <rel>-assign         loop 60s; assigns IDs, /data/grouped →              │
  │                        /data/assigned/PROJECT.SUBJECT.SESSION              │
  │   <rel>-upload         loop; reads LOCAL /data/assigned directly;          │
  │                        uploads to XNAT over HTTPS                          │
  │                        Secret xnat-credentials (server, username, password)│
  │   <rel>-data-policy    DaemonSet; walks the declared dataPolicy stages and │
  │                        reports disk + reclaim decisions (deletes nothing   │
  │                        while dataPolicy.enabled is false)                  │
  │                                                                            │
  │   observability.stack.enabled: true adds, in this same namespace:          │
  │     ais-loki (SingleBinary, filesystem on a PVC) · ais-kps-prometheus ·    │
  │     ais-kps-alertmanager · <rel>-grafana (NodePort) ·                      │
  │     <rel>-vector (DaemonSet → http://ais-loki:3100, plain HTTP)            │
  └────────────────────────────────────────────────────────────────────────────┘

                     │  HTTPS REST (XNAT credentials live only here)
                     ▼
  ┌──────────────────────────┐
  │  XNAT Server             │   ◄──────── Modalities C-STORE to
  │ (separate infrastructure)│             AET=AISEDGE on :4242 (LAN)
  └──────────────────────────┘
```

`<rel>` is the Helm release name, which `install.sh` sets to the site name.

## Data Flow

```
1. Modality C-STOREs to Orthanc on the node
   - Orthanc receives on port 4242 with AET=AISEDGE
   - orthanc.deid.aetMap maps the Called-AET → XNAT project. It is rendered
     into /etc/ais-edge/routing.json, which the Lua hook reads.
         │
         ▼
2. Orthanc Lua hook (files/deidentify-and-forward.lua)
   - OnStoredInstance:
     a. Writes the ORIGINAL to /facility-backup/ (site-controlled retention)
     b. /modify with orthanc.deid.profile; UIDs are kept so the deid'd
        instance lands in the same Study
     c. Deletes the ORIGINAL from Orthanc (keeps the deid'd instance in storage)
     - An AET missing from the map is REJECTED for ingest but NOT discarded:
       the original goes to /facility-backup/__unmapped_aet__/<AET>/... and is
       only then removed from Orthanc. If that write fails, the instance stays.
   - OnStableStudy (after orthanc.stableAge=30s of silence):
     d. PUTs label "xnat-ingest-ready" on the study
         │
         ▼
3. xnat-ingest group-orthanc (REST-pull mode)
   - Polls Orthanc's REST API every ingest.orthancGroup.interval (default 60s)
   - Filters: has label ingest.orthancGroup.toProcessLabel ("xnat-ingest-ready"),
     lacks ingest.orthancGroup.processedLabel ("xnat-ingest-processed")
   - Hardlinks instances from /data/orthanc-storage into grouped studies under
     /data/grouped  (same filesystem — hardlink, not copy)
   - PUTs the processed label on the study
         │
         ▼
4. xnat-ingest assign (ID assignment)
   - Reads /data/grouped every ingest.assign.interval
   - Derives XNAT project/subject/session IDs from the DICOM clinical-trial tags
     the Orthanc hook writes (ingest.assign.tagMapping:
     project=ClinicalTrialProtocolID — sourced from the AET map,
     subject=ClinicalTrialSubjectID, session=ClinicalTrialTimePointID)
   - Collates each study into /data/assigned/PROJECT.SUBJECT.SESSION/
   - With dataPolicy.derived.grouped.reclaim=onAssigned it also passes
     --unlink-source all, dropping each grouped tree once assigned. Without
     that, assign rebuilds its work list from a live directory listing every
     pass and re-assigns the same sessions forever.
         │
         ▼
5. xnat-ingest upload (local source → XNAT)
   - Reads the LOCAL /data/assigned directory directly (no S3)
   - Uploads sessions to XNAT via REST over HTTPS (XNAT credentials only here)
   - Creates project/subject/session/scan hierarchy in XNAT
   - Skips sessions already in XNAT (idempotent); loops every
     upload.direct.loop seconds, and leaves a session alone until it has been
     quiet for upload.direct.waitPeriod
```

The deid happens at step 2 inside Orthanc; everything downstream of
`OnStoredInstance` works with deid'd identifiers. The original DICOM exists only
in `/data/facility-backup` (real identifiers, site-retained) and nowhere else —
it never leaves the node and is never uploaded.

Orthanc and all three xnat-ingest stages mount the pipeline volume
(`storage.pipeline.hostPath`, default `/data/xnat-ingest`) at `/data`. Because
`orthanc-storage`, `grouped`, `assigned`, and the upload source all live on the
same filesystem, `group-orthanc` can hardlink (rather than copy) and the upload
pod reads byte-for-byte the same assigned files. Cross-filesystem hardlinks fail
with `EXDEV` and `hardlink_or_copy` then silently degrades to a full byte copy of
every study, so these directories **must** be on one physical mount. The facility
backup is deliberately a *separate* volume (`storage.facilityBackup.hostPath`,
mounted at `/facility-backup`): a wedged or full pipeline volume must not be able
to take the originals with it.

## Security Model

```
Single node                                    XNAT
├─ XNAT credentials (local Secret)             ├─ User data
├─ AIS_DEID_HMAC_SALT (local Secret)           │
├─ ORIGINAL DICOMs in /data/facility-backup    │
│  (real identifiers; never leaves the node)   │
├─ Inbound: DICOM :4242 on the local LAN only  │
└─ Outbound: HTTPS :443 to XNAT                 │
```

- **De-identification happens on-node, before anything is uploaded.** Only deid'd
  data is assigned and sent to XNAT. `orthanc.deid.policyReviewed` must be set to
  true by a human before the chart will render: a wrong-but-present profile looks
  identical to a right one from the outside.
- **Original DICOMs stay put.** They live only in `/data/facility-backup` under
  site-controlled retention and are never transmitted anywhere.
- **Credentials are never in a chart or a values file.** Every one is referenced
  by Secret name; the Secrets themselves live SOPS-encrypted in
  `sites/<site>/secrets.enc.yaml` and are decrypted straight into the cluster.
  All four are in namespace `xnat-ingest` — a pod cannot read a Secret from
  another namespace, and that failure shows up only as
  `CreateContainerConfigError`.
- **XNAT credentials are local** to this node and used only for the outbound
  HTTPS upload.
- **One inbound port.** DICOM 4242 on the local LAN, from modalities. Nothing is
  exposed to the internet. Outbound is HTTPS to XNAT (and, if observability is
  enabled, the Grafana NodePort for the local admin on the LAN).
- **No S3 keys, no CA distribution, no per-site key scoping.** This is a single,
  self-contained appliance — there is no fleet, no shared object store, and no
  transport CA to manage. Vector reaches Loki over plain HTTP because nothing
  leaves the node.

| If compromised... | Impact |
|--------------------|--------|
| The node | This is the whole appliance — harden it accordingly. An attacker gets the local DICOMs (originals in `/data/facility-backup`, deid'd in Orthanc storage), the XNAT credentials, and the deid salt. Restrict LAN access to :4242 and OS-level access to the machine. |
| The DICOM port (:4242) | Anyone on the LAN who can reach :4242 can push studies. Unlisted AETs cannot reach XNAT — they are quarantined under `/facility-backup/__unmapped_aet__/` — but they still consume disk. Keep it on a trusted modality VLAN. |
| The XNAT credentials | Scope the XNAT service account to the target project only (Member/Collaborator), so a leak can't reach unrelated data. |
| An age private key | Whoever holds it can decrypt every `sites/*/secrets.enc.yaml` it is a recipient of. SOPS has no escrow: losing *every* recipient key for a file means that file is gone. Back the key up, and rotate a file with `sops updatekeys` after adding a recipient. |

## Repository Structure

```
k0s-k0smotron-mvp/
├── README.md                              ← You are here
├── install.sh                             ← Three steps: k0s, Secrets, chart
├── .sops.yaml                             ← SOPS recipients + which keys get encrypted
├── charts/edge/                           ← THE chart. Everything runs from here.
│   ├── Chart.yaml                         ← pins + vendors the observability subcharts
│   ├── values.yaml                        ← defaults and the reasoning; do NOT edit per site
│   ├── charts/                            ← vendored kube-prometheus-stack-87.19.2.tgz,
│   │                                        loki-7.1.0.tgz (no repo fetch at install)
│   ├── files/                             ← loaded with .Files.Get, never templated
│   │   ├── deidentify-and-forward.lua     ← deid + facility-backup + label hook
│   │   ├── deidentification-profile.example.json  ← start your profile here
│   │   ├── data-policy.sh                 ← the retention/reporting engine
│   │   ├── vector-local.yaml              ← tier-1 Vector config (in-cluster Loki, no TLS)
│   │   └── vector.yaml                    ← tier-2 variant (mTLS to a management Loki)
│   └── templates/
│       ├── orthanc-deployment.yaml        ← Orthanc Deployment + Service
│       ├── orthanc-config.yaml            ← orthanc.json, routing.json, deid profile
│       ├── ingest-pipeline.yaml           ← group-orthanc + assign
│       ├── upload.yaml                    ← direct upload to XNAT (tier-1) / s3 (tier-2)
│       ├── storage.yaml                   ← StorageClass + both hostPath PVs/PVCs
│       ├── data-policy.yaml               ← the dataPolicy DaemonSet
│       ├── vector.yaml                    ← hand-written Vector DaemonSet
│       ├── validate.yaml / _helpers.tpl   ← render-time refusals (see below)
│       └── NOTES.txt                      ← post-install summary of what was deployed
├── sites/
│   ├── example-single/                    ← TIER-1 template: values.yaml + secrets.example.yaml
│   ├── example-edge/                      ← tier-2 edge template (not used on this tier)
│   └── <your-site>/                       ← values.yaml + secrets.enc.yaml (committed ENCRYPTED)
├── config/
│   └── k0s-controller.yaml                ← single-node k0s cluster config
├── scripts/
│   ├── 01-install-k0s.sh                  ← k0s --single + kubectl + helm + local-path
│   ├── site-secrets.sh                    ← init-key | add-recipient | new | encrypt | edit | apply | check
│   └── ci/                                ← render, lint and contract checks (`make ci`)
└── docs/                                  ← Component + operations reference
```

There is no shell-side template rendering: the chart is the only thing that turns
configuration into manifests, so a value is stated once and read once.

`charts/edge/templates/_helpers.tpl` refuses to render on several conditions,
each of which otherwise fails *silently* at runtime — de-id enabled without
`policyReviewed`, an empty `aetMap` (every modality quarantined), an empty
`profile` (studies reach XNAT with PHI intact and nothing looks wrong), deid
without `storage.facilityBackup.enabled`, and `upload.mode` set to both paths at
once. `install.sh` adds one more: tier-1 requires `upload.mode: direct`, because
`s3` would have the uploader retrying an endpoint that never answers while the
disk quietly filled.

## Installing on an Existing Kubernetes Cluster

If you already have a single-node Kubernetes cluster (k3s, kubeadm, MicroK8s, …):

1. Set `installMode: existing` in `sites/<site>/values.yaml`.
2. Ensure `kubectl` is configured and points at your cluster (`~/.kube/config`),
   and that `helm`, `sops`, `age` and `python3` are installed.
3. If a `hostpath-pipeline` StorageClass already exists, set
   `storage.storageClass.create: false` — a StorageClass is cluster-scoped, so
   two releases both creating it collide.
4. If you enable observability, note that its PVCs ask for the `local-path`
   StorageClass **by name** (that is what `scripts/01-install-k0s.sh` installs), so
   a differently-named default class is not enough. Either provide `local-path`,
   or override the `storageClass` / `storageClassName` keys in the `loki:` and
   `kube-prometheus-stack:` blocks of your site file.
5. Run `./install.sh <site>` and answer `s` to step 1 when it prompts. Do **not**
   use `-y` here: it auto-confirms every step, including the k0s install.

Note that Orthanc uses `hostPort: 4242` and both volumes are `hostPath` PVs, so
the DICOM modalities must be able to reach the node's IP and the node must have
the configured paths available.

## XNAT Configuration

Before ingesting data, ensure:

1. **The XNAT project exists** — create it in the XNAT web UI first. Its ID must
   match the `project` value in `orthanc.deid.aetMap` (the single source of the
   destination project). The Lua hook does not create the project. Use IDs in
   `[A-Za-z0-9_]` only — xnat-ingest normalises other characters (e.g. a hyphen)
   to `_`, so `test-project` would become `test_project`.
2. **The XNAT user is a local account** — not AAF/OIDC. Create via
   Administer → Users.
3. **The XNAT user has project permissions** — at least Member or Collaborator on
   the target project.

`xnat-ingest` authenticates via `POST /data/JSESSION` with username/password and
uses the session token for subsequent REST calls. If your XNAT presents a private
or self-signed certificate, set `upload.direct.verifySsl: false`; the upload pod
then runs with `--dont-verify-ssl`.

## Tested Versions

| Component | Version | Notes |
|-----------|---------|-------|
| Ubuntu | 22.04.5 LTS | The single node |
| k0s | v1.35.2+k0s.0 | Single-node cluster (`k0s install controller --single`); pinned in `install.sh` via `K0S_VERSION` |
| local-path-provisioner | v0.0.36 | StorageClass `local-path`, used by the observability PVCs |
| Orthanc | 1.12.11 (plugins) | `jodogne/orthanc-plugins:1.12.11` — DICOM SCP on port 4242. Needs ≥ 1.12.0 for study-level labels |
| xnat-ingest | 0.12.3 | `ghcr.io/australian-imaging-service/xnat-ingest:0.12.3` — upstream; JSON logging, `group-orthanc` Orthanc REST-pull, `assign` ID-assignment, and local-path upload source |
| kube-prometheus-stack | 87.19.2 | Vendored subchart, `fullnameOverride: ais-kps`. Ships Prometheus v3.13.1, Alertmanager v0.33.1, Grafana 13.1.1, kube-state-metrics v2.19.1 |
| Loki | 7.1.0 (app 3.6.8) | Vendored subchart, `fullnameOverride: ais-loki`. SingleBinary, **filesystem** storage on a PVC (no object store) |
| Vector | timberio/vector 0.49.0-distroless-libc | Hand-written DaemonSet, tails all pod logs, pushes to the in-cluster Loki |
| data-policy engine | curlimages/curl 8.11.1 | Needs `df`, `find`, `stat`, `date`, `awk` **and** `curl`; busybox has no curl and its wget cannot issue the DELETE the orthanc-rest backend needs |

Image tags are pinned in `charts/edge/values.yaml` (`orthanc.image.tag`,
`ingest.image.tag`, …) and can be overridden per site in
`sites/<site>/values.yaml`. The observability subcharts are pinned in
`Chart.yaml` *and* vendored under `charts/edge/charts/`: a hospital appliance
must not need a working path to `grafana.github.io` in order to reinstall.

## Testing

Drop a study by C-STORE. The Called-AET (`-aec`) must be listed in
`orthanc.deid.aetMap` — that's how the deid hook knows which XNAT project to
route to. An unlisted AET is quarantined under
`/facility-backup/__unmapped_aet__/<AET>/`, not ingested and not deleted.

```bash
# C-STORE a study to Orthanc on the node (from a machine with dcmtk):
storescu -aec <AET-from-aetMap> -aet TEST_MOD <nodeIP> 4242 study/*.dcm

# Watch the Orthanc deid + label events
kubectl logs -n xnat-ingest -l component=dicom-receiver -f \
  | grep -E 'instance_deidentified|study_labeled_ready|REJECT|ABORT|ERROR'

# Watch group-orthanc REST-pull from Orthanc and hardlink into /data/grouped
kubectl logs -n xnat-ingest -l component=group -f
# Watch assign collate grouped studies into /data/assigned
kubectl logs -n xnat-ingest -l component=assign -f

# Watch upload to XNAT
kubectl logs -n xnat-ingest -l component=upload -f
```

Then confirm the session appears in the XNAT project's web UI. The original study
stays in `/data/facility-backup`; only the de-identified session is uploaded.

## Health Checks

```bash
# All pods in the release namespace should be Running
kubectl get pods -n xnat-ingest

# Node should be Ready
kubectl get nodes

# The pipeline log tails
kubectl logs -n xnat-ingest -l component=dicom-receiver --tail=20  # Orthanc + deid
kubectl logs -n xnat-ingest -l component=group        --tail=20    # group-orthanc → /data/grouped
kubectl logs -n xnat-ingest -l component=assign       --tail=20    # assign → /data/assigned
kubectl logs -n xnat-ingest -l component=upload       --tail=20    # upload → XNAT
kubectl logs -n xnat-ingest -l component=data-policy  --tail=20    # disk + reclaim decisions

# What the release thinks it deployed (AET map, upload mode, data policy,
# the Secrets it expects to already exist)
helm get notes <site> -n xnat-ingest

# XNAT reachability
curl -sk <XNAT_URL>                                             # should return HTML

# Grafana (only if observability.stack.enabled)
#   http://<nodeIP>:30030
```

## Failure Scenarios

| Scenario | What happens | Recovery |
|----------|-------------|---------|
| Modality sends an unmapped AET | Orthanc rejects it for ingest and quarantines the ORIGINAL under `/facility-backup/__unmapped_aet__/<AET>/`; `REJECT` logged. If the quarantine write fails, the instance is kept in Orthanc (`ABORT`) rather than lost | Add the AET to `orthanc.deid.aetMap`, re-run `./install.sh <site>`, and re-send the study |
| Network drops mid-upload | The in-flight session upload fails | The upload loop retries the still-assigned session on the next cycle |
| Node reboots | k0s auto-starts; pods resume; assigned files are safe on the local disk | Nothing — the pipeline picks up where it left off |
| Orthanc pod restarts | In-flight receive interrupted | Modality re-sends, or the study completes on the next stable cycle |
| XNAT is down | Uploads fail; sessions accumulate in `/data/assigned` | XNAT returns; the upload loop clears the backlog |
| DICOM missing AccessionNumber | `assign` routes the session to `/data/assigned/__invalid__/` | Manual rename/move; real clinical DICOMs populate this field |
| `/data` disk fills | Nothing is deleted while `dataPolicy.enabled` is false, so both volumes grow unbounded. The data-policy DaemonSet reports free disk and what it *would* reclaim | Expand the disk, or turn on `dataPolicy` (read a week of `dryRun` decisions first — this node holds the only copy of the facility backup) |
| `helm upgrade` refuses to render | One of the render-time guards fired (see Repository Structure) | The failure text names the values path and why it matters — fix the site file, do not bypass |
| DICOM missing `SeriesDescription` | `group-orthanc` raises `ImagingSessionParseError: Did not find 'SeriesDescription'` and exports nothing. assign then receives an empty session and names it `assigned/__invalid__/INVALID_MISSING_CLINICALTRIALPROTOCOLID_...` — which points at the de-identification profile rather than the real cause | Read the group stage's log first. Confirm de-identification really did set the tags with `curl localhost:8042/instances/<id>/simplified-tags` on the receiver pod; if it did, the fault is upstream in grouping |
| XNAT presents an untrusted certificate | The upload pod `CrashLoopBackOff`s with `SSLCertVerificationError ... self-signed certificate`, and no session is ever delivered | `openssl s_client -connect <xnat>:443` to confirm (`Verify return code: 18`). Set `upload.direct.verifySsl: false` for that site, and revert it when XNAT gets a real certificate |
| Session already delivered, uploader loops again | `'DICOM' resource ... already exists on XNAT with different checksums` is logged at ERROR and inflates the "Upload errors" panel, although nothing is wrong | Look for a matching `Successfully uploaded all files in` line for the same session. If present, the session is delivered |

## Observability

Optional log-aggregation, metrics, dashboarding, and alerting — native to the
single node, with simpler plumbing than a fleet needs. **Two switches, and they
are deliberately orthogonal:**

- `observability.enabled` — run Vector on this node, i.e. ship logs *somewhere*.
- `observability.stack.enabled` — host the log/metric store *here*. Defaults to
  **false**, and must: it gates the two subchart dependencies in `Chart.yaml`,
  and a Helm dependency whose condition path does not resolve is treated as
  enabled.

With the stack on, `charts/edge` installs, in the same namespace as the pipeline:

- **Loki** (`ais-loki`) — SingleBinary, **filesystem** storage on a PVC. Not S3:
  there is no object store on a single node. Its ruler is wired to
  `ais-kps-alertmanager` explicitly, because `fullnameOverride` makes the
  Alertmanager Service `ais-kps-alertmanager` rather than
  `<release>-kube-prometheus-stack-alertmanager` — get that wrong and Loki pushes
  every alert to a name that does not resolve, with Loki, the rules and the
  dashboards all looking healthy.
- **Prometheus** (`ais-kps-prometheus`) — scrapes pod `/metrics` and
  kube-state-metrics, stores time series, evaluates `PrometheusRule` objects.
  `nodeExporter`, `kubeControllerManager`, `kubeScheduler`, `kubeProxy` and
  `kubeEtcd` are **disabled**: those targets do not exist on a single k0s node
  and, left on, produce permanently-firing "target down" noise that trains
  operators to ignore Alertmanager.
- **Grafana** (`<release>-grafana`) — **NodePort**, since there is no ingress on
  tier-1: `http://<nodeIP>:30030`.
- **Alertmanager** (`ais-kps-alertmanager`).
- **Vector** (`<release>-vector`) — a hand-written DaemonSet
  (`charts/edge/templates/vector.yaml`), *not* the Vector subchart. Tier-1 loads
  `files/vector-local.yaml`, which is `files/vector.yaml` minus the sink `tls:`
  block, because tier-1's Loki is in-cluster over plain HTTP with no client
  certificate. Both are read with `.Files.Get` and never templated: they are full
  of Vector's own `{{ }}` event syntax, and letting Helm evaluate it renders every
  stream label as an empty string — which silently breaks every alert and
  dashboard that selects on one.

The split between the two rule engines is unchanged: pipeline-event alerts are
LogQL over the JSON event stream and belong in the **Loki ruler**; K8s object
state is a metric and belongs in **Prometheus**. See
[`docs/alerting-architecture.md`](docs/alerting-architecture.md) for the
reasoning and [`docs/dashboards.md`](docs/dashboards.md) for what each pipeline
panel measures.

### Which keys actually take effect

Worth knowing before you tune anything, because the two layers look alike:

- **The subchart blocks at the bottom of the values file are the live settings.**
  Grafana's NodePort is `kube-prometheus-stack.grafana.service.nodePort`;
  retention is `kube-prometheus-stack.prometheus.prometheusSpec.retention` and
  `loki.loki.limits_config.retention_period`; PVC sizes and storage classes are
  likewise under `loki:` / `kube-prometheus-stack:`.
- **`observability.stack.*` is the intended site-level surface, and today only
  part of it is wired.** `install.sh` reads `observability.stack.enabled` and
  `observability.stack.grafana.nodePort` (the latter purely to print the URL at
  the end); no chart template consumes `retentionDays`, `grafana.*`,
  `prometheus.*`, `lokiStorage` or `alerting.*` yet. So if you change the
  NodePort, change it in **both** places or the printed URL and the Service will
  disagree; and set retention in the subchart blocks, as
  `charts/edge/values.yaml` (`dataPolicy.telemetry`) instructs.
- **Alertmanager routing is not generated from `alerting.*` yet.** The
  `alertmanager-smtp` Secret and the `emailTo` / `smtpHost` / `smtpUsername`
  values exist and are the right place to record the site's settings, but the
  Alertmanager runs on the subchart's default configuration until they are
  wired — do not assume mail is leaving the node without testing it. (Gmail
  needs an App Password: a 2FA account rejects the account password with
  `535 BadCredentials`, and the only symptom is alerts that never arrive.)
- **The Grafana admin login comes from the chart-generated Secret**, not from
  `grafana-admin-credentials`:

  ```bash
  kubectl -n xnat-ingest get secret <release>-grafana \
    -o jsonpath='{.data.admin-password}' | base64 -d; echo
  ```

For component-by-component reference see [`docs/`](docs/README.md).

## Uninstall

The release is a Helm release, so removing it is:

```bash
helm uninstall <site> -n xnat-ingest
```

What that deliberately does **not** remove: the namespace, both
PersistentVolumes and both PersistentVolumeClaims (`helm.sh/resource-policy:
keep` plus `persistentVolumeReclaimPolicy: Retain`), and the Secrets — which the
chart never created in the first place. Received DICOM cannot be destroyed by an
uninstall. Removing the data is a separate, deliberate act:

```bash
sudo rm -rf /data/xnat-ingest/grouped /data/xnat-ingest/assigned   # derived data
# /data/facility-backup holds the ORIGINALS. This node is the only copy.
```

On a `fresh` install the node itself can be reset with `sudo k0s stop && sudo k0s
reset`, which takes the cluster with it.

## Network Ports

| From | To | Port | Purpose | Encrypted? |
|------|-----|------|---------|---|
| Modalities (LAN) | Node | **4242** | DICOM C-STORE (DIMSE, `AET=AISEDGE`) | No (local LAN; keep on a trusted modality VLAN) |
| Node | XNAT | **443** | XNAT REST API uploads (HTTPS) | TLS |
| Local admin (LAN) | Node | **30030** | Grafana UI (only if `observability.stack.enabled`) | No (local LAN) |

The only inbound port is DICOM 4242 on the local LAN. The only outbound path is
HTTPS to XNAT. No inbound ports are exposed to the internet.

**Site IT firewall rule:** allow the modalities to reach the node on TCP 4242, and
allow the node to reach the XNAT server on TCP 443.
