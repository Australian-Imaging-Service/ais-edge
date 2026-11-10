# Tier-1 Single-Node Edge Medical Imaging Ingest

The pipeline tool is accessionflow (called xnat-ingest before 0.18.0).

A single-node appliance that receives DICOM from local modalities, de-identifies
it on-node, and uploads it to XNAT. Part of
[NIF FDRI Stream 2](https://github.com/Australian-Imaging-Service).

One Ubuntu machine runs the whole pipeline on a single-node
[k0s](https://k0sproject.io/) cluster:

```
modality --C-STORE--> Orthanc (receive) --> group-orthanc --> assign --> deidentify --> upload --> XNAT (HTTPS)
```

There is **no** SeaweedFS, **no** S3 hop, **no** k0smotron / child cluster /
konnectivity, **no** separate edge worker, **no** nginx-ingress, and **no**
cert-manager. The chart uploads the deidentify-stage output, not the facility
backup. That output can retain fields and labels the recipe does not remove.
Review those and any separately managed backup exports before patient use. Optional observability (Loki + Prometheus + Grafana +
Alertmanager + Vector) runs natively on the same node.

Everything above is deployed by **one Helm chart**, `charts/edge`, configured by
**one file**, `sites/<site>/values.yaml`, plus that site's SOPS-encrypted
`secrets.enc.yaml`. There is no second, env-var-shaped configuration to keep in
step with it.

## Prerequisites

- **One Ubuntu node**: Ubuntu 22.04 is the recorded test platform. The earlier
  8GB RAM / 100GB disk sizing suggestion is historical, not a measured
  0.20.0 minimum (not verified 2026-11-10). Size memory for concurrent stages,
  archive buffers and optional observability; size disk for retained originals
  and outages. Validate any newer OS and the actual workload before deployment.
- **One XNAT instance**: reachable over HTTPS, with a local (non-AAF/OIDC) service
  account and a pre-existing project for the sessions to land in. Scope that
  account to the projects selected by the site's tag mapping or project constant. Tier-1
  uploads from the same machine that faces the modalities, so the credential
  lives here.
- **DICOM sources**: modalities that can C-STORE to the node on port **4242**
  with the configured called AE title (`AISEDGE` by default). The shipped
  receiver accepts any calling AET. Under ingest, an AET map does not select a
  project or quarantine an unknown sender. Restrict senders at the network edge.
- **Approved labels and recipe**: `ingest.assign.tagMapping` selects source
  tags for XNAT project, subject and session. Its ingest defaults are StudyID,
  PatientID and AccessionNumber. A raw MRN selected as subject becomes the XNAT
  label before de-identification. Review those values and the complete recipe
  in `ingest.deidentify.specs` before receiving patient data.
- **`AIS_DEID_HMAC_SALT`**: generate a value with `openssl rand -hex 32` and
  put it in Secret `orthanc-deid-salt`. The backup Lua script requires it at
  load time, and install/verify checks reject the placeholder. Its value is
  unused for ingest de-identification. It does not salt XNAT labels.
- **Re-identification protection**: the chart writes maps under `/data/reid`.
  Set `ingest.deidentify.reidEncryptKeySecret` for production input. Without it,
  the maps are plain JSON on the pipeline volume. The Secret must contain
  `XINGEST_REID_ENCRYPT_KEY`; keep recovery keys separately from the maps.

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
| `sites/<site>/values.yaml` | The entire non-secret configuration: `nodeIP`, `installMode`, storage paths, `ingest.assign.tagMapping`, `ingest.deidentify.specs`, loop intervals, `upload.mode: direct`, `dataPolicy`, `observability` | `sites/example-single/values.yaml` |
| `sites/<site>/secrets.enc.yaml` | Four Secrets, SOPS-encrypted, **all in namespace `xnat-ingest`**: `xnat-credentials` (server/username/password), `orthanc-deid-salt` (`AIS_DEID_HMAC_SALT`), `grafana-admin-credentials`, `alertmanager-smtp` | `sites/example-single/secrets.example.yaml` |

`sites/<site>/values.yaml` is safe to commit — it contains no credentials, only
Secret *names*. `secrets.enc.yaml` is committed **encrypted**; `git diff` then
shows which keys changed without showing their values.

You never edit `charts/edge/values.yaml`. That file holds the defaults and the
reasoning behind them; your site file holds the facts that are true of your site.

### Steps

```bash
# 0. Install the two tools the secrets step needs. Nothing else installs them,
#    and step 2 is the first command that fails without them.
sudo apt-get install -y age
curl -fsSLO https://github.com/getsops/sops/releases/download/v3.13.3/sops_3.13.3_amd64.deb
sudo apt-get install -y ./sops_3.13.3_amd64.deb

# 1. Clone this repo on the node. NAME THE BRANCH: the default branch is `main`,
#    which is TIER 2 (a management cluster plus edges). This tier is on
#    `tier-1-solution`, and the two are not interchangeable.
git clone --branch tier-1-solution <repo-url> && cd ais-edge

# 2. One age key per operator, then make it a recipient in .sops.yaml
scripts/site-secrets.sh init-key
scripts/site-secrets.sh add-recipient age1...        # the public key it printed

# 3. Scaffold the site. single selects the only tier-1 template, example-single.
#    The name becomes the release name. Use lowercase letters, digits and
#    hyphens, starting with a letter. Do not use an underscore.
scripts/site-secrets.sh new my-hospital single

# 4. Fill in the two files
$EDITOR sites/my-hospital/values.yaml                # nodeIP, tagMapping, ingest recipe
openssl rand -hex 32                                 # -> AIS_DEID_HMAC_SALT
$EDITOR sites/my-hospital/secrets.enc.yaml           # still PLAINTEXT at this point
#   fill in every REPLACE_ on an UNCOMMENTED line, and set `server:` to your
#   XNAT. The server ships as https://xnat.example.org and is NOT a REPLACE_
#   token, so filling in only the REPLACE_ ones leaves it pointing at nothing.
#   REPLACE_ also appears in comments (the orthanc-credentials block, which you
#   only uncomment if you turn Orthanc auth on) — leave those alone.
scripts/site-secrets.sh encrypt my-hospital          # do not commit before this

#   ALERTING IS TWO HALVES, IN TWO FILES. The secrets file makes you fill in
#   REPLACE_SMTP_USERNAME and REPLACE_SMTP_APP_PASSWORD, which is only the
#   credential for talking to the relay. Who receives the mail and which relay
#   to use are in the VALUES file, under observability.stack.alerting, and they
#   ship empty. With Vector and the local stack both enabled, the chart now
#   refuses empty emailTo or smtpHost. Fill them in, then test a synthetic
#   notification; a valid rendered route does not prove relay delivery.

# 5. Confirm the de-id policy, deliberately: set
#      deid.policyReviewed: true
#    in sites/my-hospital/values.yaml. The chart REFUSES to render while it is
#    false. Review labels, recipe output and reid-map protection first.

# 6. Install
chmod +x install.sh scripts/*.sh
./install.sh my-hospital          # interactive
# or: ./install.sh -y my-hospital # non-interactive / CI (auto-confirm)

# 7. PROVE IT WORKS. Do not skip this — `helm install` succeeding only means the
#    objects were accepted, not that anything is running or reachable.
scripts/verify-live.sh my-hospital
```

`install.sh` is three steps, and it reads `sites/<site>/values.yaml` for all of
them:

1. **single-node k0s** — `k0s install controller --single`, plus `kubectl`,
   `helm` and local-path (`scripts/01-install-k0s.sh`). Answer `s` at the prompt
   to skip it when the cluster already exists.
2. **site Secrets** — `scripts/site-secrets.sh apply <site>` creates any
   namespace the Secrets name and decrypts straight into the cluster through a
   pipe without a plaintext manifest in the checkout. Editor files, swap and
   Kubernetes storage are outside that guarantee. Secrets go **before** workloads: a pod
   that starts without its Secret sits in `CreateContainerConfigError`.
3. **the chart** — `helm upgrade --install <site> charts/edge -n xnat-ingest
   --create-namespace -f sites/<site>/values.yaml`.

### Then verify, every time

```bash
scripts/verify-live.sh <site>          # normal exit = failure count (cap 250); read skips too
```

`install.sh` prints this at the end, and it is the difference between "Helm
accepted the manifests" and "this site can actually receive a study and deliver
it". It reads the SAME `sites/<site>/values.yaml` the install used, so it checks
*your* paths, namespace, AE title and node IP — nothing in it is hardcoded, and
a site that keeps its data somewhere other than `/data` is checked where it
actually lives. CI asserts that its fallbacks still match the chart's defaults,
so a site that omits a key cannot be verified against a stale path.

What it covers, and what it deliberately does not:

| Checked | How |
|---|---|
| Secrets exist, and the de-id salt is not still the placeholder | reads them from the cluster |
| Every PVC is `Bound`, and configured data directories are present | Pipeline stage directories share a filesystem for hardlinks. The backup is a byte copy and may use a separate disk; that comparison can report `SKIP`. |
| Each pipeline stage is **Ready**, not merely `Running` | a `Running` pod with a failing probe is not working |
| XNAT is reachable **and the credentials are accepted** | from *inside* the upload pod, honouring the site's `upload.direct.verifySsl` |
| Grafana answers on its NodePort | HTTP probe |
| The alert rules actually loaded | counts the rule groups Prometheus holds |
| DICOM port 4242 | Uses `ss` to check a local listener. If the port is not visible but the receiver pod is Running, reports `SKIP`; otherwise reports failure. This is not a C-STORE test. Send a synthetic study from the modality network as well. |

Re-run it after any `helm upgrade`, after rotating a Secret, and after a reboot.

Architecture, data flow, security model, and component-by-component reference are
all below.

---

## Architecture

The application chart runs on one node in its release namespace. Kubernetes
system components and the local-path provisioner use their own namespaces.
The one application Helm release contains the pipeline and optional stack.
Modalities C-STORE to Orthanc on the node's IP at port 4242. Orthanc stores the
original instances and, when enabled, writes a separate facility-backup copy.
It does not modify headers or apply AET routing under the default ingest mode.

Use **`deid.engine: ingest` for every new site**. accessionflow groups the input,
assigns the XNAT labels, applies the site's recipe, and uploads the output.
Assignment precedes de-identification. The label values therefore need review
independently of the DICOM recipe. A recipe cannot change an already assigned
project, subject or session label.

`deid.engine: orthanc` is deprecated. Existing-engine details are in
[Deprecated Orthanc Lua engine](docs/components/deidentification.md#deprecated-orthanc-lua-engine).
See [the source-label guide](docs/choosing-a-deid-engine.md) for ingest setup.

The DICOM endpoint is inbound from the modality LAN. Upload uses outbound HTTPS
to XNAT. Optional Grafana access is a separate inbound NodePort, and alert email
needs outbound access to the configured SMTP relay. Restrict those paths to the
intended networks; enabling observability does not make them part of DICOM.

```
════════════════════════════════════════════════════════════════════════════════
  SINGLE NODE   (nodeIP)            inbound: DICOM :4242 (LAN)   outbound: :443 XNAT
════════════════════════════════════════════════════════════════════════════════

  Host directories  (the pipeline stages share ONE filesystem so hardlinks resolve)
    /data/xnat-ingest/orthanc-storage   ORIGINAL DICOM instances (Orthanc storage)
    /data/xnat-ingest/grouped           grouped studies (group-orthanc output)
    /data/xnat-ingest/assigned          PROJECT.SUBJECT.SESSION/ dirs (assign output)
    /data/facility-backup               ORIGINAL DICOMs (real IDs); chart does not upload this directory
    /data/xnat-ingest/deidentified     recipe output; upload reads this
    /data/xnat-ingest/reid             sensitive metadata maps; encrypt with key Secret
    /data/xnat-ingest/packaged         optional package output; upload follows it

  ┌─ namespace: xnat-ingest — one release of charts/edge ─────────────────────┐
  │   <rel>-orthanc      DICOM SCP :4242 (hostPort, AET=AISEDGE)               │
  │     Lua deidentify-and-forward.lua:                                        │
  │       OnStoredInstance  copy ORIGINAL to /facility-backup, then return   │
  │                         No AET routing or header modification in ingest  │
  │       Ready-label filter is cleared; group waits for stable input        │
  │     env  AIS_DEID_HMAC_SALT (Secret orthanc-deid-salt)                     │
  │     REST :8042 (ClusterIP) — how group-orthanc pulls                       │
  │        │                                                                   │
  │        ▼  REST-pull stable studies                                       │
  │   <rel>-group-orthanc  loop 60s; hardlinks original DICOMs from              │
  │                        /data/orthanc-storage → /data/grouped               │
  │   <rel>-assign         loop 60s; assigns IDs, /data/grouped →              │
  │                        /data/assigned/PROJECT.SUBJECT.SESSION              │
  │   <rel>-deidentify     recipe: /data/assigned -> /data/deidentified       │
  │                        mapping: /data/reid (sensitive; key optional)     │
  │   <rel>-upload         reads LOCAL /data/deidentified by default;         │
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
  │  XNAT Server             │   Upload destination, not the edge DICOM receiver
  │ (separate infrastructure)│   Modalities send to Orthanc on the node above
  └──────────────────────────┘
```

`<rel>` is the Helm release name, which `install.sh` sets to the site name.

## Data Flow

```
1. Receive
   Modality --C-STORE--> Orthanc at <nodeIP>:4242, called AET=AISEDGE.
   The original stays in Orthanc storage. The enabled backup callback writes
   a byte copy to /facility-backup and returns before AET routing.
   No unknown-AET quarantine is created under ingest.
         |
         v
2. Group
   group-orthanc polls the REST API and waits for stable input.
   The chart clears --to-process-label under ingest.
   Instances are hardlinked from /data/orthanc-storage into /data/grouped.
   Processed labels and export snapshots identify what was staged.
         |
         v
3. Assign
   /data/grouped -> /data/assigned/PROJECT.SUBJECT.SESSION/
   Derived mapping: StudyID / PatientID / AccessionNumber.
   constantProjectId can supply one project for all sessions.
   These values become XNAT labels before any recipe changes the headers.
   Missing values are held in assigned/__invalid__, still identifiable.
         |
         v
4. Deidentify
   /data/assigned -> /data/deidentified
   Recipe: <project or __default__>/medimage/dicom-series.
   Only named tags change. The example removes PatientID and AccessionNumber,
   adds de-identification markers, and retains private tags, sex and age.
   /data/reid holds sensitive mappings; a key Secret enables encryption.
         |
         v
5. Upload
   /data/deidentified -> XNAT over HTTPS.
   Optional package runs first and changes the upload source to /data/packaged.
   The uploader uses assigned session IDs and resource manifests.
   Its quiet period reduces overlap; it cannot prove a study is complete.
```

The recipe runs at step 4. Original data exists in Orthanc, grouped and assigned
storage before that point. The facility backup is a separate retained copy.
Reid maps can retain original metadata after processing. Include all these
locations in the site's access and retention policy. File-drop input feeds the
group/assign path without passing through the Orthanc backup callback.

All pipeline stages mount the same PVC at `/data`, backed by
`storage.pipeline.hostPath` (default `/data/xnat-ingest`). Keep stage directories
on one filesystem so hardlinks can be used. A hardlink cannot cross filesystems;
`hardlink_or_copy` can fall back to a full byte copy, which changes disk and time
requirements. The facility backup is written as a copy to its own volume and can
be on another disk. It is not subject to the pipeline hardlink requirement.

Cleanup follows separate handoffs. `grouped.reclaim: onAssigned` can cause
assignment to retire its successful input snapshot. Under `--unlink-source all`,
that can include files not represented in the output session. Keep manual
files outside pipeline inputs; no backup verification precedes that unlink. Under ingest, assigned reclaim `auto`
resolves to `onDeidentified`. Deidentified reclaim `auto` resolves to `onUploaded`,
or `onPackaged` when packaging is enabled. The terminal reclaimer verifies the
files it removes against XNAT and uses the upload-tree writer lock. A successful
upload message alone is not permission to erase an original or a conflict.

Validate each boundary with synthetic data before enabling patient traffic:

| Boundary | Evidence to check |
|---|---|
| receiver to backup | The configured backup contains the original bytes. A separate backup disk is permitted. |
| group to assign | The session is complete enough to stage and its source labels are populated. |
| assign to deidentify | The labels are approved for XNAT; the input still contains identifiers until processed. |
| deidentify to upload | The expected recipe changed the expected fields, and manifests describe the output files. |
| upload to XNAT | The destination labels, scan resources and stored data match the intended output. |
| cleanup | Each selected condition has fresh evidence, and unresolved input or conflicts remain available. |

Keep the site mapping, recipe and image reference together in review. A change
to any one can change where a session lands or what information it contains.
An engine default is not a substitute for validating a site's actual input.

## Security Model

```
Single node                                    XNAT
├─ XNAT credentials (local Secret)             ├─ User data
├─ AIS_DEID_HMAC_SALT (local Secret)           │
├─ ORIGINAL DICOMs in /data/facility-backup    │
│  (real identifiers; no chart upload path)    │
├─ Inbound: DICOM :4242 on the local LAN only  │
└─ Outbound: HTTPS :443 to XNAT                 │
```

- **De-identification happens on-node, before anything is uploaded.** Assignment sees original data. Deidentified
  output is what the default uploader reads. `deid.policyReviewed` must be set to
  true by a human before the chart will render, whichever engine is selected: a
  present recipe is not proof of a correct policy. Review labels separately.
- **Original data stays on the node.** It exists in the backup and in pipeline
  directories before deidentify. The recipe output is sent to XNAT. Protect
  `/data/reid` as identifying data, and review private fields and pixel content.
- **No automatic label pseudonymisation.** PatientID or an accession chosen as
  a label reaches XNAT before the recipe can change it. Use approved values.
- **Credentials are never in a chart or a values file.** Every one is referenced
  by Secret name; the Secrets themselves live SOPS-encrypted in
  `sites/<site>/secrets.enc.yaml` and are decrypted straight into the cluster.
  The four example Secrets and any optional reid encryption Secret must be in
  namespace `xnat-ingest`. A Secret volume or environment reference cannot read
  another namespace. Missing references can prevent the pod from starting.
- **XNAT credentials are local** to this node. The uploader uses them for
  delivery. The staged reclaimer also uses them to verify the remote archive
  before deleting terminal local output.
- **Restrict inbound access.** DICOM 4242 receives modality traffic on the LAN.
  A Grafana NodePort, when enabled, is also inbound access for administrators.
  Restrict both at the network boundary. XNAT transfer is outbound HTTPS. SMTP
  alert delivery and installation downloads need their configured destinations.
- **No S3 keys, no CA distribution, no per-site key scoping.** This is a single,
  self-contained appliance — there is no fleet, no shared object store, and no
  transport CA to manage. Vector reaches Loki over plain HTTP because nothing
  leaves the node.

| If compromised... | Impact |
|--------------------|--------|
| The node | This is the whole appliance; harden it accordingly. An attacker gets the local DICOMs (originals in the backup, Orthanc and pre-deid pipeline directories, plus sensitive reid maps), the XNAT credentials, and the deid salt. Restrict LAN access to :4242 and OS-level access to the machine. |
| The DICOM port (:4242) | Anyone on the LAN who can reach :4242 can push studies. Ingest does not use an AET allowlist for project routing or quarantine. Any accepted input with usable labels can enter the pipeline and consume disk. Keep it on a trusted modality VLAN. |
| The XNAT credentials | Scope the upload account to the intended projects with create/read/update permissions, normally the Member role. Collaborator is read-only. Check effective access, including custom roles and other project grants. See [XNAT roles](https://wiki.xnat.org/documentation/understanding-user-roles-and-permissions). |
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
│   │   ├── deidentify-and-forward.lua     ← facility-backup callback under ingest
│   │   ├── deidentification-profile.example.json  ← deprecated-engine reference profile
│   │   ├── deid-specs.example/               ← recipes for the accessionflow deidentify stage
│   │   ├── data-policy.sh                 ← the retention/reporting engine
│   │   ├── vector-local.yaml              ← tier-1 Vector config (in-cluster Loki, no TLS)
│   │   └── vector.yaml                    ← tier-2 variant (mTLS to a management Loki)
│   └── templates/
│       ├── orthanc-deployment.yaml        ← Orthanc Deployment + Service
│       ├── orthanc-config.yaml            ← orthanc.json, routing.json, deid profile
│       ├── ingest-pipeline.yaml           ← group-orthanc + assign
│       ├── upload.yaml                    ← direct upload to XNAT (the only mode on tier-1)
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
configuration into manifests, so the rendered templates are the workload source. Values can be read by several
consumers, including installation and verification scripts; verify that a
custom setting reaches each consumer that needs it.

`charts/edge/templates/_helpers.tpl` refuses configurations that cannot work.
These include a false policy-review gate, ingest without a recipe source,
ClinicalTrial-prefixed ingest tag mappings, obsolete stage-enable keys, and
recipes supplied under an engine that would ignore them. Empty required Secret
names also fail rendering. The guards do not inspect incoming DICOM values.

Tier-1 accepts only `upload.mode: direct`. The chart and installer both enforce
this because the S3 route needs the tier-2 management plane on the main branch.
A new site should retain the example's ingest selector and review the source
mapping, recipe, reid encryption and data policy as a single configuration.
Legacy-only profile and AET-map validation is described in the deprecated
component reference, not as a new-site setup requirement.

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
5. Run `./install.sh <site>`. Step 1 still prompts, but with
   `installMode: existing` it no longer *builds* anything, so either answer is
   safe and `-y` is safe: `install.sh` passes `INSTALL_MODE` into
   `scripts/01-install-k0s.sh`, and that script's first branch prints
   `=== 01: Using existing Kubernetes cluster ===`, runs
   `kubectl get nodes -o wide` as a reachability check, warns if there is no
   default StorageClass, and `exit 0`s — long before
   `k0s install controller --single` is reached. Making
   `-y` safe is the whole point of passing the variable: a site file can declare
   "there is already a cluster here" without depending on an operator
   remembering to answer `s`.

   What to check instead of the prompt is the line step 1 actually printed. If
   it says `=== 01: Installing k0s management cluster ===`, the site file did
   not take `installMode: existing` — stop the run there rather than let it
   install k0s on a host that already runs Kubernetes.

Note that Orthanc uses `hostPort: 4242` and both volumes are `hostPath` PVs, so
the DICOM modalities must be able to reach the node's IP and the node must have
the configured paths available.

## XNAT Configuration

Before ingesting data, ensure:

1. **The XNAT project exists** — create it in the XNAT web UI first. Its ID must
   match the project selected by `ingest.assign.tagMapping.project` or
   `ingest.assign.constantProjectId`. Assignment does not create the project. Use IDs in
   `[A-Za-z0-9_-]` for unchanged labels. accessionflow normalises runs of other
   characters to `_`: `test.project` becomes `test_project`, while
   `test-project` keeps its hyphen. This is not a pseudonymisation step.
2. **The XNAT user is a local account** — not AAF/OIDC. Create via
   Administer → Users.
3. **The XNAT user has upload permissions.** The standard Member role can
   create, read and update project data; Collaborator is read-only. Check
   effective permissions on each intended project and validate a synthetic
   upload. See [XNAT roles](https://wiki.xnat.org/documentation/understanding-user-roles-and-permissions).

`accessionflow` authenticates via `POST /data/JSESSION` with username/password and
uses the session token for subsequent REST calls. Keep
`upload.direct.verifySsl: true`. For a private CA, provide a trusted certificate
chain in the uploader environment and verify it there. Setting this value to
false sends `--dont-verify-ssl` and disables verification; it does not repair
the trust chain.

## Tested Versions

Source pins below were reviewed on 2026-11-10. The OS row is a historical
test environment whose measurement date is not recorded. This table is not a
new compatibility run or vulnerability audit; current security status is not
verified (2026-11-10). Record deployed digests and verify a representative
synthetic workflow after any override.

| Component | Version | Notes |
|-----------|---------|-------|
| Ubuntu | 22.04.5 LTS | The single node |
| k0s | v1.35.2+k0s.0 | Single-node cluster (`k0s install controller --single`); pinned in `install.sh` via `K0S_VERSION` |
| local-path-provisioner | v0.0.36 | StorageClass `local-path`, used by the observability PVCs |
| Orthanc | 1.12.11 (plugins) | `jodogne/orthanc-plugins:1.12.11` — DICOM SCP on port 4242. Needs ≥ 1.12.0 for study-level labels |
| accessionflow | image tag `0.20.0` | `ghcr.io/australian-imaging-service/accessionflow:0.20.0`, the upstream image. Includes default deidentify, local upload and grouping snapshot support. The inspected package reports `0.20.0`; record the deployed digest too. The old fork reported `0.16.3.dev49+ais.20261021.r13.g3182cc6`, which is retained here only as migration history. |
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

Send a synthetic study from a machine on the modality network. Set its project,
subject and session tags to known approved test values, and create the project
in XNAT first. The called AET is `orthanc.aet` (default `AISEDGE`); it does not
select the project under ingest.

```bash
# Replace AISEDGE if the site changes orthanc.aet.
storescu -aec AISEDGE -aet TEST_MOD <nodeIP> 4242 study/*.dcm

# Receiver and backup activity
kubectl logs -n xnat-ingest -l component=dicom-receiver --tail=100
# Group input, assignment, recipe processing and upload
kubectl logs -n xnat-ingest -l component=group --tail=100
kubectl logs -n xnat-ingest -l component=assign --tail=100
kubectl logs -n xnat-ingest -l component=deidentify --tail=100
kubectl logs -n xnat-ingest -l component=upload --tail=100
```

Check more than the presence of an XNAT session. Verify the exact label values,
resource files and deidentified headers. Confirm that PatientID and the other
named removals are absent, and that the result markers are present. Review the
fields the recipe leaves in place, including private tags, PatientSex and
PatientAge. The markers do not prove that pixels or unknown fields are safe.

Confirm that the backup retains the original and that reid maps have the
expected encryption. The default map path is `/data/reid`; plaintext maps are
possible unless the encryption-key Secret reference is set. Do not publish the
map contents in test reports. Use counts, filenames and synthetic expectations
where possible.

Then test a synthetic input with an empty required label. Confirm that it is
held in `assigned/__invalid__`, that the assignment error is visible, and that
it does not appear as a successfully deidentified session. Keep the recovery
procedure available to operators. No unknown-AET quarantine is expected in this
mode, so a quarantine directory is not the place to diagnose missing labels.

## Health Checks

```bash
# All pods in the release namespace should be Running
kubectl get pods -n xnat-ingest

# Node should be Ready
kubectl get nodes

# The pipeline log tails
kubectl logs -n xnat-ingest -l component=dicom-receiver --tail=20  # Orthanc receive + backup
kubectl logs -n xnat-ingest -l component=group        --tail=20    # group-orthanc → /data/grouped
kubectl logs -n xnat-ingest -l component=assign       --tail=20    # assign -> /data/assigned
kubectl logs -n xnat-ingest -l component=deidentify   --tail=20    # recipe -> /data/deidentified
kubectl logs -n xnat-ingest -l component=upload       --tail=20    # upload → XNAT
kubectl logs -n xnat-ingest -l component=data-policy  --tail=20    # disk + reclaim decisions

# What the release thinks it deployed (engine, upload mode, data policy,
# the Secrets it expects to already exist)
helm get notes <site> -n xnat-ingest

# XNAT reachability
curl -fsS <XNAT_URL>            # reachability/TLS only; HTML is not upload proof

# Grafana (only if observability.stack.enabled)
#   http://<nodeIP>:30030
```

## Failure Scenarios

| Scenario | What happens | Recovery |
|----------|-------------|---------|
| Unapproved sender reaches the DICOM port | The shipped receiver accepts calling AETs. Ingest does not consult the legacy AET map or quarantine that sender; usable source labels can take the data into the pipeline | Restrict port 4242 at the network boundary and investigate received input under the site's data-handling procedure |
| Network drops mid-upload | The in-flight session upload fails | The upload loop retries the retained upload-source session on the next cycle |
| Node reboots | Local data normally persists and k0s restarts, but in-flight work can be interrupted | Check disks, pod readiness, retained input, logs and the exact remote inventory. Do not infer completeness from the reboot finishing. |
| Orthanc pod restarts | In-flight receive interrupted | Modality re-sends, or the study completes on the next stable cycle |
| XNAT is down | Uploads fail; sessions accumulate in `/data/deidentified` (or `/data/packaged`) | XNAT returns; the upload loop clears the backlog |
| DICOM missing AccessionNumber | `assign` logs `Could not resolve the labels of` at ERROR, the session goes to `/data/assigned/__invalid__/`, and `InvalidSessionAssigned` fires. Nothing removes that folder | Requeue the session with `sudo ais-requeue` on the node, as in [docs/recovering-invalid-sessions.md](docs/recovering-invalid-sessions.md). Check each modality; a field can be absent or empty |
| `/data` disk fills | Policy deletion is disabled by default, but successful copy stages can still retire source snapshots. Retained originals and unconfirmed output can fill the filesystem | Restore headroom and inspect every configured filesystem. Review dry-run decisions before arming cleanup; preserve originals and unresolved data. |
| `helm upgrade` refuses to render | One of the render-time guards fired (see Repository Structure) | The failure text names the values path and why it matters — fix the site file, do not bypass |
| DICOM missing `SeriesDescription` or `SeriesNumber` | `group-orthanc` stages the series with a fallback name and logs a WARNING with `event: series_metadata_fallback` and the Orthanc series ID. A missing description gives the scan type `Series_<scan-id>`. A missing number gives the `SeriesInstanceUID` with its dots changed to underscores, as XNAT's header importer does | Nothing. Correct the tag at the modality if the scan needs a readable name |
| One study that cannot be staged | `group-orthanc` logs the refusal, removes its temporary staging and continues other studies. It retains the source in Orthanc and retries later. Duplicate series-number conflicts are refused so data is not silently merged. Earlier releases could stop the whole pass; that is historical behavior | Read the reason and follow the component guide. Confirm retained input before any recovery; alert timing depends on thresholds and collected logs. |
| XNAT presents an untrusted certificate | TLS verification can fail before upload | Inspect the presented chain with `openssl s_client -connect <xnat>:443 -servername <xnat>`. Provide a trusted chain in the uploader environment and retain `upload.direct.verifySsl: true`; disabling verification is not a trust repair. |
| Existing XNAT resource has different checksums | The ERROR means missing, extra or changed content; the empty-digest false ERROR was fixed in 0.15.3. `XNATResourceIncompleteAndStuck` reports repeated conflicts | Compare staged and remote files. A later upload-success line does not prove that content matches. Preserve the source and resolve the conflict before deleting anything. |
| `compared by file name only` WARNING (xnat-ingest PR #227) | XNAT has no checksum for one or more files, so those bytes were not compared | Ask the XNAT administrator to configure and compute catalog checksums. A matching filename is not a content proof. The warning can recur on each upload attempt. |

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
- **The old parent storage/retention keys are not live subchart settings.**
  Set NodePort and retention in the blocks above. The current installer still
  reads `observability.stack.grafana.nodePort` only for its printed URL; that
  legacy display value does not configure the Service. If you change the real
  NodePort, read the Service or `helm get notes` for the correct address. This
  display mismatch remains open in the source reviewed on 2026-11-10.
- **`observability.stack.alerting.*` is wired.** The parent template loads
  `files/alertmanager-config.yaml`, substitutes the mail settings and references
  the mounted SMTP password file. `emailTo` and `smtpHost` cannot be empty when
  both Vector and the local stack are enabled: the render guard rejects that
  combination. A stack without Vector does not hit that guard, so still review
  its receivers. A successful render proves configuration, not mail delivery;
  test a synthetic alert through the relay and verify receipt and resolution.
- **Grafana reads `grafana-admin-credentials` by default.** The subchart's
  `grafana.admin.existingSecret` points to it, using `admin-user` and
  `admin-password`. It does not mint the operator login from a separate
  `<release>-grafana` Secret under this configuration. Check existence without
  printing the password:

  ```bash
  kubectl -n xnat-ingest get secret grafana-admin-credentials
  helm get notes <site> -n xnat-ingest
  ```

  Use the approved secret-edit process to rotate credentials, and verify the
  resulting login. Do not paste a decoded password into a shared terminal log.

For component-by-component reference see [`docs/`](docs/README.md).

## Orthanc REST API Authentication

The chart default is `orthanc.auth.enabled: true`; the example site overrides
it to `false`. Check the merged values. `ClusterIP` limits normal external
Service exposure but is not an authorization boundary. In-cluster clients and
users with port-forward access can still reach the API, including its delete
operations. Enable authentication and supply the matching Secret keys below.

Three keys, all required, because three different things read this Secret:

| Key | Read by | If it is wrong |
| --- | --- | --- |
| `users.json` | Orthanc itself. The chart mounts it at `/etc/orthanc/users.json`, a configuration fragment that Orthanc merges at start. There is no `RegisteredUsersFile` option | Orthanc answers 401 to every request. If the key is missing, the volume does not mount and Orthanc does not start |
| `orthanc-user` | `group-orthanc` and the data-policy engine, which call the REST API | Orthanc answers 401. Grouping cannot export studies and can retry or exit depending on where the error occurs; the policy adapter logs `backend_unavailable` and keeps the store |
| `orthanc-password` | `group-orthanc` and the data-policy engine | as above |

`orthanc-user` / `orthanc-password` **must match** the user and password inside
`users.json`. They are separate keys because Orthanc wants a file and
`group-orthanc` wants environment variables; nothing reconciles them for you.

**1. Generate a password and add the Secret.**

```bash
openssl rand -base64 24                       # use this as <password> below
scripts/site-secrets.sh edit <site>           # decrypts to $EDITOR, re-encrypts on save
```

Add this document (the template is already in your `secrets.enc.yaml`, commented
out — uncomment and fill it in):

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: orthanc-credentials
  namespace: xnat-ingest          # must match the site's `namespace:`
type: Opaque
stringData:
  users.json: '{"RegisteredUsers":{"admin":"<password>"}}'
  orthanc-user: admin
  orthanc-password: <password>
```

The password is **plaintext inside that JSON** — Orthanc has no hashed-password
format here. That is precisely why this file is SOPS-encrypted before it is
committed, and why `scripts/site-secrets.sh check` refuses a plaintext one.

**2. Turn it on in the site file.**

```yaml
orthanc:
  auth:
    enabled: true
    existingSecret: orthanc-credentials
```

The chart refuses to render if `enabled: true` and `existingSecret` is empty —
the deployment mounts that Secret non-optionally, so an empty name would fail
as a confusing volume error rather than an auth one.

**3. Apply, and restart what reads it.**

```bash
scripts/site-secrets.sh apply <site>
./install.sh <site>
kubectl -n xnat-ingest rollout restart deploy/<release>-orthanc
kubectl -n xnat-ingest rollout restart deploy/<release>-group-orthanc
kubectl -n xnat-ingest rollout restart ds/<release>-data-policy
```

Restart all three consumers when they are enabled. Orthanc loads its users
configuration at startup; grouping and data-policy read credentials from
environment variables. A Secret change alone does not replace those processes.

**4. Verify.**

```bash
# The Orthanc image has no curl, so reach the API through a port-forward.
# Run it in a second terminal, wait for "Forwarding from 127.0.0.1:8042",
# and stop it with Ctrl-C afterwards:
#   kubectl -n xnat-ingest port-forward deploy/<release>-orthanc 8042:8042
# should now be 401 without credentials
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8042/studies
# and 200 with them
curl -s -o /dev/null -w '%{http_code}\n' -u admin:<password> http://localhost:8042/studies
```

Then confirm that a synthetic study moves through grouping and assignment.
A `Found N studies` line alone does not prove an export succeeded. On a 401,
compare `orthanc-user` and `orthanc-password` with `users.json`, check that
each consumer was restarted, and inspect the receiver authentication config.

> **Do not expose port 8042 to the host or a NodePort just because auth is now
> on.** `orthanc.expose.http` stays `ClusterIP`. Authentication is a second
> layer here, not a replacement for keeping the API off the network.

## Uninstall

The release is a Helm release, so removing it is:

```bash
helm uninstall <site> -n xnat-ingest
```

A plain Helm uninstall is different from the repository reset script. The
pipeline PVs/PVCs carry retention settings, and operator-managed Secrets and
the namespace are not chart-created. Inspect the actual retained resources;
Helm retention is not a backup and does not stop other writers or host deletion.
Observability storage also needs its own retention review.

The complete site teardown is:

```bash
scripts/uninstall.sh <site>                  # workloads, storage and node reset
scripts/uninstall.sh --keep-cluster <site>   # retain k0s, still remove site data
```

**Both script modes delete configured patient-data directories, including the
facility backup.** They explicitly remove retained PVs/PVCs and the namespace.
Copy and verify required originals, reid maps and unresolved input before a
teardown. The script retains the age key, site configuration and k0s binary.
A manual `rm -rf` of grouped/assigned is not a general recovery procedure:
those directories can hold unprocessed or unresolved identifying input.

A standalone `k0s stop` / `k0s reset` removes the node's cluster installation;
it is not equivalent to a verified application-data cleanup. Check remaining
mounts, files and network state before reusing the machine.

## Network Ports

| From | To | Port | Purpose | Encrypted? |
|------|-----|------|---------|---|
| Modalities (LAN) | Node | **4242** | DICOM C-STORE (DIMSE, `AET=AISEDGE`) | No (local LAN; keep on a trusted modality VLAN) |
| Node | XNAT | **443** | XNAT REST API uploads (HTTPS) | TLS |
| Local admin (LAN) | Node | **30030** | Grafana UI (only if `observability.stack.enabled`) | No (local LAN) |

DICOM 4242 is the pipeline input. Grafana adds an administrative NodePort when
enabled. Installation needs approved download/registry access, SMTP needs its
configured relay, and DNS/time services need the site's normal paths. The chart
does not enforce an internet firewall; configure and verify network boundaries.

**Site IT firewall rule:** allow the modalities to reach the node on TCP 4242, and
allow the node to reach the XNAT server on TCP 443.
