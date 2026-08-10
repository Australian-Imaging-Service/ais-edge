# AIS Edge — medical imaging ingest from hospital to XNAT

Receives DICOM inside a hospital, de-identifies it at the point of capture, and
delivers it to XNAT — without the hospital network ever needing an inbound
route, and without XNAT credentials ever leaving the management node.

---

> **New here?** Read [docs/TOUR.md](docs/TOUR.md) first — a guided walkthrough
> of what you configure, what runs, what can go wrong, and where the data goes.

## Contents

- [What this is](#what-this-is)
- [Deployment topology](#deployment-topology)
- [Architecture](#architecture)
- [Data flow, step by step](#data-flow-step-by-step)
- [Install](#install)
- [Configuration reference](#configuration-reference)
- [Secrets](#secrets)
- [Data policy — what is kept and for how long](#data-policy--what-is-kept-and-for-how-long)
- [Security model](#security-model)
- [Observability and alerting](#observability-and-alerting)
- [Repository structure](#repository-structure)
- [Continuous integration](#continuous-integration)
- [Operating](#operating)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Pinned versions](#pinned-versions)

---

## What this is

A **management node** runs the central services: S3 staging, the XNAT uploader,
the observability stack, the internal certificate authority, and one k0smotron
*hosted control plane* per edge site.

An **edge** is a single machine inside a hospital network running Orthanc and
the ingest pipeline. It has no inbound route from the internet. It reaches the
management node outbound over TLS, and its Kubernetes control plane physically
runs on the management node — so the hospital operates a Kubernetes node without
operating a Kubernetes cluster.

The de-identification happens **on the edge, before anything leaves the site**.
The original is written to a facility backup that is never automatically
deleted; everything downstream is derived data.

---

## Deployment topology

### Tier 2 — fleet (this repo's primary mode)

Many hospitals, one management node, one XNAT credential for the whole fleet.

```
   Hospital A                Hospital B                Hospital C
   ┌──────────┐              ┌──────────┐              ┌──────────┐
   │ edge-a   │              │ edge-b   │              │ edge-c   │
   │ Orthanc  │              │ Orthanc  │              │ Orthanc  │
   └────┬─────┘              └────┬─────┘              └────┬─────┘
        │  outbound HTTPS only    │                         │
        └────────────┬────────────┴─────────────────────────┘
                     ▼
        ┌────────────────────────────────────┐
        │      MANAGEMENT NODE               │
        │  SeaweedFS   s3://ingest-<edge>/   │
        │  uploader    per edge → XNAT       │
        │  reclaimer   per edge              │
        │  k0smotron   a control plane each  │
        │  Prometheus · Loki · Grafana       │
        │  cert-manager (internal CA)        │
        └───────────────┬────────────────────┘
                        ▼
                      XNAT
```

Each edge gets its **own S3 bucket, own identity, own uploader, own reclaimer,
own control plane**. One site's stuck session, expired credential or poison
study cannot stop delivery for any other site.

### Tier 1 — single site

One machine, no management node. Install `charts/edge` alone with
`upload.mode: direct`, and the edge talks to XNAT itself. This repo's management
chart is not needed.

---

## Architecture

| Component | Where | Role |
|---|---|---|
| **Orthanc** | edge | DICOM C-STORE receiver on :4242. Runs the de-identification Lua hook on every stored instance. |
| **deidentify-and-forward.lua** | edge | Writes the untouched original to the facility backup, then rewrites identity tags per the site's profile, then labels the study for pickup. |
| **group-orthanc** | edge | Pulls studies labelled `xnat-ingest-ready` out of Orthanc into `/data/grouped`, then labels them `xnat-ingest-processed` so they are not pulled twice. |
| **assign** | edge | Groups instances into XNAT sessions under `/data/assigned`, writing `__MANIFEST__.json` (per-resource, with MD5 checksums) and `__METADATA__.json`. |
| **s3-uploader** | edge | `aws s3 sync` each settled session to `s3://ingest-<edge>/staged/`. Emits a JSON event schema that the alert rules consume. |
| **Vector** | edge | Ships pod logs to Loki on the management node over TLS. |
| **SeaweedFS** | mgmt | S3 staging. One bucket per edge, one scoped identity per edge. |
| **mgmt-upload-\<edge\>** | mgmt | `xnat-ingest upload` — pulls staged sessions and writes them into XNAT. |
| **mgmt-reclaim-\<edge\>** | mgmt | Removes staged sessions **only after XNAT confirms it holds every file**. The only component that deletes patient data. |
| **cert-sync** | mgmt | Copies the CA bundle and each edge's Loki push credential into that edge's cluster, on a schedule, so CA rotation does not require visiting sites. |
| **k0smotron** | mgmt | Hosts a k0s control plane per edge. The edge runs only a worker. |
| **cert-manager** | mgmt | Issues the internal CA and every server certificate. |

### Why the control plane is hosted centrally

An edge is a box in a hospital basement that nobody logs into. Running its API
server on the management node means:

* the hospital does not operate etcd, certificates or control-plane upgrades;
* the edge needs no inbound firewall rule — the worker dials out through
  konnectivity;
* losing the edge machine loses a worker, not a cluster.

---

## Data flow, step by step

```
 1. modality ──C-STORE──▶ Orthanc :4242
                             │
 2.                          ├──▶ /data/facility-backup/<study>/…    ORIGINAL
 3.                          │     written FIRST, before de-identification
                             │     governed by dataPolicy.originals (forever)
                             ▼
 4.              de-identify in place (Lua, OnStoredInstance)
                             │   identity tags replaced per site profile
                             │   UIDs retained so a study stays coherent
                             ▼
 5.              label study `xnat-ingest-ready`
                             │
 6.  group-orthanc ──────────┘   (waits for IsStable; skips already-processed)
        │
        ▼
 7.  /data/grouped/<session>/
        │
 8.  assign
        ▼
 9.  /data/assigned/<project>.<subject>.<visit>/
        │   + __MANIFEST__.json  (filenames + MD5 per resource)
        │   + __METADATA__.json
        │
10.  s3-uploader   waits settleMinutes, fingerprints the tree, uploads
        │          HTTPS, per-site credential, custom CA
        ▼
11.  s3://ingest-<edge>/staged/<session>/
        │
12.  mgmt-upload-<edge>  ──▶ XNAT
        │
13.  mgmt-reclaim-<edge>  re-queries XNAT, compares filenames AND checksums
                          against the manifest, and only then deletes
```

**Every hop is idempotent and fails safe.** If the S3 endpoint is unreachable,
the uploader keeps the local copy and retries. If XNAT is down, staged data
accumulates rather than being lost. If the reclaimer cannot prove XNAT holds a
session, it keeps it.

---

## Install

```bash
./install.sh <site>        # interactive, one prompt per step
./install.sh -y <site>     # non-interactive
```

**One file configures a deployment: `sites/<site>/values.yaml`.** `install.sh`
reads it *and* passes it to both Helm charts, so every fact is stated once.
There is no `--set` anywhere in the installer — a flag needed to make an install
work is a value that belongs in the site file, and an install you cannot
reproduce from that file alone is not reproducible.

### First-time setup

```bash
# 1. Create your age key and register it as a SOPS recipient
scripts/site-secrets.sh init-key
scripts/site-secrets.sh add-recipient <your age1... public key>

# 2. Scaffold the MANAGEMENT site (copies sites/example-mgmt/)
scripts/site-secrets.sh new my-site mgmt

# 3. Scaffold each EDGE (copies sites/example-edge/) — one per facility node
scripts/site-secrets.sh new my-edge edge

# 4. Edit them. The management file carries everything shared — domain,
#    hostnames, node IPs, the edges list, the fleet-wide data policy. Each edge
#    file carries only what is local to that site: its AE-title to XNAT-project
#    map, its de-identification profile, its disk paths.
$EDITOR sites/my-site/values.yaml        $EDITOR sites/my-site/secrets.enc.yaml
$EDITOR sites/my-edge/values.yaml        $EDITOR sites/my-edge/secrets.enc.yaml

# 5. Encrypt — do this before committing anything
scripts/site-secrets.sh encrypt my-site
scripts/site-secrets.sh encrypt my-edge

# 5. Install
./install.sh my-site
```

> **Back up `~/.config/sops/age/keys.txt`.** It is the only key that can decrypt
> `sites/*/secrets.enc.yaml`, nothing can regenerate it, and losing it makes
> every encrypted site file permanently unreadable. Put it in the team password
> manager.

### What each step does, and why it is not all Helm

| Step | Does | Why it cannot be a chart |
|---|---|---|
| **1** | k0s, kubectl, helm, local-path-provisioner | there is no cluster yet |
| **2** | cert-manager, then the k0smotron operator — both pinned | there are no CRDs yet, and cert-manager must exist **before** the chart |
| **3** | site Secrets, SOPS → cluster | must precede the workloads that mount them |
| **4** | `helm install` management chart | — |
| **5** | child kubeconfig + join token, per edge | a Helm-rendered token would be re-minted on every upgrade |
| **6** | join the edge worker over SSH | there is no API server on the edge until this runs |
| **7** | `helm install` edge chart, then seed cert-sync | — |

#### Why cert-manager is a prerequisite, not a subchart

The dependency is circular, and the loop is not obvious:

```
management chart renders `Cluster` (k0smotron.io) objects
  └─▶ that CRD declares a CONVERSION WEBHOOK
       └─▶ served by the k0smotron operator
            └─▶ which will not start until cert-manager issues its serving cert
                 └─▶ and cert-manager would be installed by the same chart
```

Setting `certManager.enabled: true` therefore fails on the first `Cluster`
object with `conversion webhook … dial tcp …:443: connect: connection refused`,
which reads as a networking fault rather than an ordering one. Keep it `false`;
step 2 satisfies it.

#### Why the installer seeds cert-sync immediately

cert-sync is a CronJob (`23 */6 * * *`). On a fresh install that would leave the
edge without its `ca-bundle` and its `loki-push-client-tls` for up to six hours
— and neither is optional: the s3-uploader mounts the first and Vector mounts
the second, so neither pod can start at all. Step 7 runs the CronJob's own pod
spec once via `kubectl create job --from=cronjob`, so it cannot drift from what
the schedule does later.

---

## Configuration reference

Everything below lives in `sites/<site>/values.yaml`.

### Identity and addressing

```yaml
clusterLabel: mgmt              # label on this plane's own logs/metrics
installMode: fresh              # fresh | existing (adopting a running k0s)
topology: onprem                # onprem | cloud

domain:
  internal: aisedge.local       # internal DNS suffix; needs no real zone
  mgmtNodeIP: "203.0.113.10"    # what the edges dial

hostnames:                      # published on :443, routed by SNI
  seaweedfs: seaweedfs.aisedge.local
  grafana:   grafana.aisedge.local
  loki:      loki.aisedge.local
```

The **child-cluster hostnames are deliberately absent here.** They used to be
fleet-wide, which gave every edge the same `apiHost`, so a second site's Ingress
claimed a hostname the first already owned and the fleet could not exceed one
site. They are per-edge now, and the chart refuses to render if the old
fleet-wide keys reappear.

### Edges

One entry per site. Each produces a hosted control plane, an S3 bucket, a scoped
identity, an uploader and a reclaimer.

```yaml
edges:
  - name: edge-dev
    nodeIP: "203.0.113.20"
    join: ssh                       # ssh (default) | bundle — see below
    sshUser: ubuntu                 # join: ssh only — install.sh pushes the join
    sshKey: ~/.ssh/id_ed25519       #   (no API server on the edge until then)
    s3SecretRef: edge-dev-s3
    exposure: sni                   # sni | nodePort — use sni
    # joinTokenTTL: 2h              # bearer credential — keep it short
    # apiHost / konnectivityHost default to <prefix>-<name>.<domain>
```

**`join: bundle` — for an edge this node cannot reach.** A hospital behind a
whitelisted-IP allowlist, a VPN or GlobalProtect has no inbound path, so the
default push-over-SSH join cannot run. With `join: bundle`, `install.sh` writes
a single self-contained `<edge>-join.sh` instead; you carry it to the site by
whatever route you have and run `sudo bash <edge>-join.sh` there, and the
installer waits for the node to appear. `sshUser`/`sshKey` are then unused.

Only the one-time bootstrap differs — once joined, both modes are identical,
because the edge dials *out* and nothing ever connects into the site. It is
**not** an offline mode: the edge still needs permanent outbound reachability to
this node on 443. Full walkthrough, guards and teardown caveat: `docs/TOUR.md`
§4.1.

**Use `exposure: sni`.** The control plane becomes a ClusterIP Service reached
through the ssl-passthrough Ingress on :443 — which is already how the worker
connects. Its ports are *Service* ports, which are per-Service, so **two sites
can never collide and you allocate nothing**. Adding a site needs no port
assignment at all.

`nodePort` additionally reserves those numbers cluster-wide, which is the only
reason a unique pair per site would be needed. Verified here: the worker dials
`<mgmtNodeIP>:443` and the ingress routes to the Service ClusterIP — nothing
dialled the node port from outside.

If you do use `nodePort`, the numbers are explicit on purpose: deriving them from
list position means inserting a site renumbers every site after it, and the
Service carries `resource-policy: keep`, so the change would silently fail to
apply.

> Migrating an existing site `nodePort` → `sni` works, with one manual step:
> k0smotron creates a new ClusterIP Service and leaves the old NodePort one
> behind holding the ports. Once the new Service has endpoints, delete it:
> `kubectl -n <edge> delete svc kmc-<edge>-nodeport`.

**Measured cost:** ~231Mi per uploader. On a 16Gi management node that is a
practical ceiling around **15 sites**.

### Edge-local configuration

`sites/<edge>/values.yaml` carries only what is genuinely local — the AE-title
map, the de-identification profile, and storage paths. Everything else is
**derived** from the management site file, which is passed to the edge release
as well:

| Derived | From |
|---|---|
| `upload.s3.endpoint` | `hostnames.seaweedfs` or `seaweedfs.<domain.internal>` |
| `upload.s3.bucket` | `<bucketPrefix>-<clusterLabel>` when `perSiteBuckets` |
| `observability.loki.endpoint` | `hostnames.loki` or `loki.<domain.internal>` |
| `hostAliases` | `domain.mgmtNodeIP` + the hostnames edge pods actually dial |

Each of those used to be typed a second time, and **every mismatch in that group
fails silently** — the uploader retries an endpoint that will never answer,
correctly preserves its local copy, and the management side, which watches for
arrivals rather than absences, reports nothing wrong.

### De-identification

```yaml
orthanc:
  aet: AISEDGE
  deid:
    enabled: true
    policyReviewed: false        # NO SAFE DEFAULT — you must assert this
    existingSaltSecret: orthanc-deid-salt
    aetMap:
      AISEDGE: {project: my_project}
    profile:
      DeidMode: modify
      RemovePrivateTags: false
      Keep: [StudyInstanceUID, SeriesInstanceUID, SOPInstanceUID, FrameOfReferenceUID]
      Replace:
        PatientIdentityRemoved: 'YES'
        PatientName: ANONYMOUS
        PatientID: ${ProjectCode}-${SubjectHash}
```

* **`policyReviewed` has no default.** The chart refuses to render until a human
  asserts they have read the profile and the AE-title map for this site.
* **UIDs are retained** so a study stays internally consistent across series.
* **An unmapped AE title is quarantined, not dropped** — see
  `dataPolicy.originals.quarantine`.
* **The HMAC salt must survive reinstalls.** The same patient hashed with a
  different salt becomes a different pseudonym, so rotating it splits one
  subject into two in XNAT.

---

## Secrets

The charts never contain credentials. They reference Secrets by name, and those
Secrets are created separately from a SOPS-encrypted file.

```bash
scripts/site-secrets.sh new <site>       # scaffold
scripts/site-secrets.sh encrypt <site>   # before committing
scripts/site-secrets.sh edit <site>      # decrypt → $EDITOR → re-encrypt
scripts/site-secrets.sh apply <site>     # decrypt straight into the cluster
scripts/site-secrets.sh check            # fail if any committed secret is plaintext
```

`apply` pipes the plaintext directly into `kubectl` — it never touches disk. It
also creates any namespace its Secrets name, which is what makes
**secrets-before-workloads** possible on a bare cluster.

Only `data` and `stringData` are encrypted. Names, namespaces and keys stay
readable, so `git diff` shows *which* credential changed without showing it, and
tooling can read structure without decrypting.

### Namespaces are part of the contract

A Secret is only readable from its own namespace, and for this chart nearly
everything — SeaweedFS, Loki, Grafana, Alertmanager — runs in the **release**
namespace. Only the uploader/reclaimer run in `xnat-upload`. Getting this wrong
installs cleanly and leaves pods in `CreateContainerConfigError` with nothing in
the chart to tell you why, so `make secret-contract` checks it.

---

## Data policy — what is kept and for how long

One block governs every store, and it is passed to **both** charts so a site has
exactly one answer.

```yaml
dataPolicy:
  enabled: false      # nothing expires until you turn this on
  dryRun: true        # decisions are logged, never acted on

  originals:                                   # the archive of record
    facilityBackup: {retain: forever, minFreeDiskPercent: 10}
    quarantine:     {retain: forever, alertAfter: 24h}
    fileDrop:       {reclaim: never,  minAge: 30d}

  derived:                                     # reproducible from the originals
    orthancStorage: {reclaim: onGrouped,       minAge: 7d}
    grouped:        {reclaim: onAssigned,      minAge: 0}
    assigned:       {reclaim: onUploaded,      minAge: 0}
    s3Staged:       {reclaim: onXnatConfirmed, minAge: 1d,
                     verifyAgainstXnat: true, maxRemovals: 50,
                     schedule: "17 * * * *"}

  telemetry:
    podLogFiles: {retain: 14d}
    loki:        {retain: 30d}
    prometheus:  {retain: 15d}
```

Three properties worth understanding:

**Every derived rule is `(condition AND minAge)` — both must hold.** A pure age
rule would expire a session that never reached XNAT because a credential was
wrong. A pure condition rule frees nothing once the signal breaks.

**`onXnatConfirmed` verifies content, not existence.** XNAT creates the
experiment on the first resource POST, so "the experiment exists" is true even
for a partial upload. The reclaimer sums every `__MANIFEST__.json` into a set of
`filename → MD5`, lists what XNAT actually holds, and deletes only when
`missing == 0 AND mismatched == 0`. Every uncertainty — an unreadable manifest,
a 500 from XNAT, an unparseable listing — resolves to **keep**.

**`maxRemovals` bounds a bug.** A run that decided "delete everything" is capped
per run, leaving the rest for somebody to notice. At the hourly schedule this
still drains ~1200 sessions/day.

**A fresh install expires nothing.** Run with `dryRun` for a week and read the
decisions it logs before enabling it.

---

## Security model

| Boundary | Mechanism |
|---|---|
| Hospital → management | Outbound TLS only. No inbound route to the edge. |
| Between edge sites | **One S3 bucket per site.** SeaweedFS matches identity actions as `<action>:<bucket>` with **no prefix scoping**, so a shared bucket would let any edge key read and delete every other site's staged imaging. The bucket is the only boundary there is. |
| Edge → XNAT | The edge has **no XNAT credential**. Only the management uploader does. This is the main operational advantage of `upload.mode: s3`. |
| Loki ingestion | Per-edge credential, Basic auth at the Ingress. Loki itself runs `auth_enabled: false`, so the Ingress is the only place it is checked. |
| TLS | Internal CA via cert-manager. An https S3 endpoint with no CA bundle is **refused at render time** — an empty `AWS_CA_BUNDLE` silently disables verification rather than falling back to the system store. |
| Credentials at rest | SOPS + age. Never in a values file, never in a ConfigMap, never in git. |
| CA private key | `tls.key` can never be copied to an edge — cert-sync refuses to render it. |

`install.sh` also **refuses to install** with a placeholder credential or a
secret shorter than 16 characters. That check exists because the template once
shipped working defaults annotated "change defaults", and the first deployment
ran with them unchanged — a comment is advice, and advice does not fail an
install.

---

## Observability and alerting

Prometheus scrapes the management plane. Loki receives logs from every edge via
Vector. Alerts come from **two** sources:

* **Prometheus rules** — resource and certificate conditions.
* **Loki ruler rules** — pipeline conditions, derived from the JSON log events
  the pipeline emits. These live in the ruler rather than Prometheus because the
  management Prometheus cannot scrape edge pods across the one-way konnectivity
  tunnel, and because the source of truth is the log event, not a derived metric.

The uploader's log schema is a **public interface**. `upload_started`,
`upload_completed` and `upload_failed` are matched by five alert rules; renaming
one disables the corresponding alert silently.

```bash
# Does every alert actually have the metrics it depends on?
scripts/check-alert-inputs.sh
```

That script asks the **live** Prometheus whether each alert's inputs have any
series at all. It is how three alerts were found that had never been able to
fire — including certificate expiry, on a fleet where every edge validates
against a CA that must be rotated in two phases weeks apart.

---

## Repository structure

```
install.sh                     the only entrypoint
sites/
  example-mgmt/                template for THE management node (one per deployment)
  example-edge/                template for ONE edge node (one per facility)
  <site>/values.yaml           SINGLE SOURCE OF TRUTH for a deployment. The
                               management file is passed to BOTH charts, so
                               anything shared is written here exactly once;
                               each edge file is passed after it and carries
                               only what is local to that site.
  <site>/secrets.enc.yaml      SOPS-encrypted; charts reference these by name
charts/
  mgmt/                        management chart
    templates/                 seaweedfs, xnat-upload, observability,
                               cert-issuers, cert-sync, edge-clusters
    files/                     reclaim-staged.sh, cert-sync.sh, ruler rules
  edge/                        edge chart
    templates/                 orthanc, ingest-pipeline, upload, vector, storage
    files/                     s3-uploader.sh, deidentify-and-forward.lua,
                               vector.yaml
scripts/
  site-secrets.sh              create / encrypt / apply site secrets
  uninstall.sh                 full reset
  01,05,06                     bootstrap steps Helm cannot do
  adopt-existing.sh            take over a running imperative install
  rotate-ca.sh                 two-phase CA rotation across the fleet
  check-alert-inputs.sh        ask live Prometheus whether alerts can fire
  ci-*.sh                      CI stages
tests/reclaimer/               28 cases asserting on what was DELETED
docs/                          component guides, CA ceremony, alerting design
```

---

## Continuous integration

```bash
make ci-fast     # no cluster required
make ci          # adds a kind-based greenfield install
```

| Stage | Proves |
|---|---|
| `render` | both charts render across 40 value combinations |
| `negative` | 57 render-time guards each fire on the condition they claim to detect, plus a census that fails if a guard is added without a case |
| `promtool` | 16 alert-rule unit tests — each rule fires on the condition it describes |
| `shell-syntax` | every script parses; no `yes \|` pipeline under `pipefail` |
| `pvc-retention` | nothing holding data can be auto-deleted |
| `runtime-templates` | scripts survive Helm rendering |
| `duplicate-names` | no two objects collide |
| `reclaimer` | 28 cases, asserting on **what was deleted**, not on log text |
| `secret-contract` | every mounted Secret exists, in the right namespace, with the right keys |
| `greenfield` | the charts install onto an empty cluster |

Two of these exist because of specific classes of silent failure:

**The reclaimer is the only component that deletes patient data**, so it is
tested by asserting on the deletes. A run that logs `reclaim_kept` and issues a
DELETE anyway would pass a log-only test and fail this one. Its `aws` and `curl`
are stubbed and **fail by default** for anything a case does not configure — a
stub that invented a plausible success would test the opposite of the property
that matters.

**`secret-contract`** renders both charts and fails if any mounted Secret is
absent, in the wrong namespace, or missing a key. A wrong namespace and a
missing key fail identically and silently at runtime: helm reports success and
the pod sits in `CreateContainerConfigError`.

---

## Operating

### Health

```bash
helm list -A
kubectl get pods -A
kubectl --kubeconfig kubeconfig-<edge> get pods -A

# S3 buckets and sizes
kubectl -n ais-mgmt exec deploy/mgmt-seaweedfs -c seaweedfs -- \
  sh -c 'echo "s3.bucket.list" | weed shell -master=localhost:9333'

# certificates
kubectl get clusterissuer
kubectl -n cert-manager get certificate
```

### Send a test study

```bash
dcmsend <orthanc-pod-ip> 4242 -aec AISEDGE study.dcm
```

Then follow it: Orthanc logs (`Lua says: {"backupPath": …}`) →
`/data/facility-backup` → study labelled `xnat-ingest-ready` → `/data/grouped` →
`/data/assigned` → `upload_completed` in the s3-uploader log →
`s3://ingest-<edge>/staged/` → the management uploader log.

Note that **re-sending the same file produces no upload notification**. DICOM
UIDs are deterministic, so Orthanc deduplicates it into a study already labelled
`xnat-ingest-processed`, and the uploader reports
`Skipping upload … as all the resources already exist on XNAT`. That is correct
idempotence, not a failure. Use a different study to test a fresh write.

### Adding an edge

Add an entry to `edges:` and re-run `./install.sh <site>`. Existing sites are
untouched; the new one gets its own control plane, bucket, identity, uploader
and reclaimer.

### Removing an edge

Remove its entry from `edges:`, then `helm upgrade`. Reset the worker with
`k0s reset` on the edge machine. The staged data and the SeaweedFS identity are
removed with the entry.

### CA rotation

Two phases, weeks apart — see `docs/ca-ceremony.md`. cert-sync distributes the
new bundle to every edge on its schedule, so rotation does not require visiting
each site. `CertificateExpiringSoon` fires at 60 days.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Edge pods `CreateContainerConfigError` | A Secret is missing. Most often `ca-bundle` or `loki-push-client-tls`, both delivered by cert-sync — run its job manually: `kubectl -n ais-mgmt create job x --from=cronjob/mgmt-cert-sync-<edge>` |
| `helm install` fails with `conversion webhook … connection refused` | The k0smotron operator is not ready. It needs cert-manager, which must be installed *before* the chart. |
| `invalid ownership metadata` on install | An object exists without Helm's ownership labels, usually from a previous non-Helm install. `scripts/uninstall.sh` clears these. |
| Worker join times out | The management node cannot resolve its own child-cluster API. Check `/etc/hosts` has the `aisedge` entries — a partial teardown that removed the entries but left the marker comment causes the installer to skip re-adding them. |
| Uploader retries forever, no error on the management side | The edge cannot reach the S3 endpoint. Check `hostAliases` resolve and the CA bundle is present. The edge correctly preserves its local copy, so the only symptom is an absence. |
| `XNATAuthFailure` while uploads succeed | Was a false positive from `xnat-ingest` progress-bar output matching bare `401`/`403`. Fixed; the rule now requires HTTP context and drops `it/s` lines. |
| Loki logs `NoSuchBucket` at startup | Non-fatal. The bucket-creation hook is `post-install`, so Loki retries its chunk store until the bucket appears. It converges without restarting. |

---

## Uninstall

```bash
scripts/uninstall.sh <site>                  # full reset, both nodes
scripts/uninstall.sh --keep-cluster <site>   # workloads only, keep k0s running
```

The default is a genuine clean slate: both Helm releases, all namespaces, the
CRDs and admission webhooks, cluster-scoped RBAC (including the Roles these
components leave in `kube-system`), every PersistentVolume **and its host
directory**, `/data` on every node, `/etc/hosts` entries **and their marker
comments**, the generated kubeconfigs and join tokens, and `k0s reset` on the
management node and each edge.

It requires you to type the site name, because it deletes `/data` — which holds
the facility backup, the archive of record.

**It never deletes your age key or your site files.**

A partial teardown is worse than none. A CRD without its operator, a namespace
Helm cannot adopt, cert-manager RBAC from a release that no longer exists, or a
stale `/etc/hosts` entry each make the *next* install fail in a way that looks
like a bug in the charts.

---

## Pinned versions

| Component | Version |
|---|---|
| k0s / k0smotron | `v1.35.2+k0s.0` / `v2.0.3` |
| cert-manager | `v1.20.3` |
| kube-prometheus-stack | `87.19.2` |
| Loki | `7.1.0` (app 3.6.8) |
| Vector | `0.57.0` |
| ingress-nginx | `4.15.1` |
| Orthanc | `1.12.11` |
| xnat-ingest | `0.12.3` |

Every one is what is **verified working**, read out of a live deployment rather
than chosen from a changelog. The previous installer used `/latest/` and
`/stable/` URLs, so a rebuild months apart got whatever upstream had published
that morning. Upgrade them deliberately, one at a time.

### Requirements

* Ubuntu 22.04 on the management node and each edge
* Key-based SSH from the management node to each edge
* `sops` and `age` on the management node
* Ports: **443** on the management node, **4242** (DICOM) on each edge
* ~16Gi RAM on the management node supports roughly 15 edge sites
