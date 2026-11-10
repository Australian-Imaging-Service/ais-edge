# AIS Edge — medical imaging ingest from hospital to XNAT

The pipeline tool is accessionflow (called xnat-ingest before 0.18.0).

Receives DICOM inside a hospital, de-identifies it on the edge in that hospital, and
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
the ingest pipeline. Runtime management traffic uses outbound TLS. The default
SSH bootstrap and teardown need inbound SSH from management; `join: bundle`
provides a local bootstrap when that is unavailable. The Kubernetes control
plane runs on management, while the hospital operates its worker node.

The deidentify stage runs **on the edge before image upload**. It removes
only the fields selected by the recipe; labels and retained headers still need
review. When enabled, the facility backup stores the input before this stage.
It defaults to indefinite retention, but explicitly armed originals expiry and
uninstall can delete it. Derived directories can also contain identifiers.

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
own control plane**. These separate per-site upload loops and storage
identities. They still share management CPU, memory, disks, network services and
the configured XNAT credential. Failure or exhaustion of a shared dependency
can affect more than one site.

### Tier 1 — single site

One machine, no management node. Install `charts/edge` alone with
`upload.mode: direct`, and the edge talks to XNAT itself. This repo's management
chart is not needed.

---

## Architecture

| Component | Where | Role |
|---|---|---|
| **Orthanc** | edge | DICOM C-STORE receiver on :4242. Runs the Lua hook on every stored instance. Under the default `deid.engine: ingest` the hook only writes the facility backup and labels the study. |
| **deidentify-and-forward.lua** | edge | Writes the untouched original to the facility backup and labels a stable study. Under `ingest` it does not change the instance. Only the deprecated `deid.engine: orthanc` makes it rewrite identity tags per a profile. |
| **group-orthanc** | edge | Pulls each study that has been quiet for `waitPeriod` out of Orthanc into `/data/grouped`, then records `xnat-ingest-processed` and snapshot state. An unchanged exported study is skipped; changed input is checked again. Under the deprecated `orthanc` engine it pulls only the studies labelled `xnat-ingest-ready`. |
| **assign** | edge | Groups instances into XNAT sessions under `/data/assigned`, writing `__MANIFEST__.json` (per-resource, with MD5 checksums) and `__METADATA__.json`. |
| **deidentify** | edge | The default de-identification engine (`deid.engine: ingest`). Applies the site's pydicom `deid` recipe (`ingest.deidentify.specs`) to each session in `/data/assigned`, and writes the result to `/data/deidentified`, with a re-identification map in `/data/reid`. The uploader reads only its output. |
| **s3-uploader** | edge | `rclone copy` each settled session to `s3://ingest-<edge>/staged/`, inside the upload-tree writer lock. Copies only: it never deletes the local copy, and it copies a session again when the staged-reclaimer leaves a repair request for it. Emits a JSON event schema that the alert rules consume. |
| **Vector** | edge | Ships pod logs to Loki on the management node over TLS. |
| **SeaweedFS** | mgmt | S3 staging. One bucket per edge, one scoped identity per edge. |
| **mgmt-upload-\<edge\>** | mgmt | `accessionflow store xnat`; pulls staged sessions and writes them into XNAT. |
| **mgmt-reclaim-\<edge\>** | mgmt | Removes proven staged resources after XNAT lists each manifest file and HEAD reports the same size. This does not compare file content or prove metadata extraction. Each S3 object delete uses the listed ETag (`If-Match`). Unproven neighboring resources remain. Pipeline retirement and data-policy adapters are separate delete paths. |
| **staged-reclaimer** | edge | The same script as `mgmt-reclaim-<edge>`, run with `STORAGE=filesystem` against the terminal stage directory, in **both upload modes**. Under `upload.mode: s3` it deletes a local file only after the bucket holds it with the same size and an ETag equal to the MD5 of the bytes read from disk now (`PROOF=s3`); a file that fails gets one repair request, which the s3-uploader answers with a new copy. Under `upload.mode: direct` it deletes only what XNAT proves, file by file (`PROOF=xnat`). Without it nothing retires the tree: the uploader never deletes, so `onUploaded` would be unsatisfiable and the tree would grow unbounded. Also deletes patient data, one proved resource at a time, inside the upload-tree writer lock. |
| **cert-sync** | mgmt | Copies the CA bundle, each edge's Loki push **client certificate**, and that edge's **S3 key pair** into that edge's cluster, on a schedule, so CA rotation does not require visiting sites. |
| **k0smotron** | mgmt | Hosts a k0s control plane per edge. The edge runs only a worker. |
| **cert-manager** | mgmt | Issues the internal CA and every server certificate. |

### Why the control plane is hosted centrally

An edge is a box in a hospital basement that nobody logs into. Running its API
server on the management node means:

* the hospital does not operate etcd, certificates or control-plane upgrades;
* runtime management traffic uses connections opened by the worker, including
  konnectivity; DICOM and the optional SSH bootstrap still need their own
  inbound access rules;
* losing the edge machine loses a worker, not a cluster.

---

## Data flow, step by step

```
 1. modality ──C-STORE──▶ Orthanc :4242
                             │
 2.                          ├──▶ /data/facility-backup/<patient>/<study>/…   ORIGINAL
 3.                          │     written FIRST, before de-identification
                             │     governed by dataPolicy.originals (forever by default)
                             ▼
 4.              the instance stays in Orthanc, unchanged
                             │   (deid.engine: ingest strips a copy at step 8)
                             ▼
 5.              label study `xnat-ingest-ready` when stable (no stage waits for it)
                             │
 6.  group-orthanc ──────────┘   (waits waitPeriod; skips already-processed)
        │
        ▼
 7.  /data/grouped/<session>/
        │
 8.  assign, then deidentify   ids from ingest.assign.tagMapping, normalized;
        │                      the recipe strips the tags it names; UIDs kept;
        │                      re-identification map in /data/reid
        ▼
 9.  /data/deidentified/<project>.<subject>.<visit>/
        │   + __MANIFEST__.json  (filenames + MD5 per resource)
        │   + __METADATA__.json
        │   (assign writes /data/assigned first; deidentify removes each
        │    session there once its de-identified copy is complete)
        │
10.  s3-uploader   waits settleMinutes, fingerprints the tree, copies
        │          HTTPS, per-site credential, custom CA; never deletes
        ▼
11.  s3://ingest-<edge>/staged/<session>/
        │   staged-reclaimer (edge), after stagedReclaimer.minAge: proves
        │   each local file against the bucket (same size, ETag = MD5 of
        │   the bytes on disk) and only then deletes the edge copy; a file
        │   that fails leaves a repair request, and step 10 copies again
        │
12.  mgmt-upload-<edge>  ──▶ XNAT
        │
13.  mgmt-reclaim-<edge>  after s3Staged.minAge (the longer clock): re-queries
                          XNAT, proves each manifest file by its row in the
                          mapped resource AND a HEAD of the same size, and
                          only then deletes, object by object
```

**Retry and deletion checks differ by stage.** If the S3 endpoint is
unreachable, its uploader retains the local copy and retries. If XNAT is down,
staged data accumulates. The reclaimer retains resources it cannot prove.
Successful copy-stage retirement can remove its complete input snapshot,
including unrepresented files; it is not a per-file remote proof. Preserve
original backups and keep manual files outside pipeline inputs.

---

## Install

```bash
./install.sh <site>        # interactive, one prompt per step
./install.sh -y <site>     # non-interactive
```

**One file configures a deployment: `sites/<site>/values.yaml`.** `install.sh`
reads it *and* passes it to both Helm charts, so every fact is stated once.
The management and edge chart releases take their configuration from these
files. The separate cert-manager prerequisite uses `--set crds.enabled=true`.
Record site configuration in values and encrypted Secrets so another operator
can reproduce the intended release; do not rely on undocumented ad hoc flags.

### First-time setup

```bash
# 0. On the MANAGEMENT node: the two tools the secrets step needs. Nothing else
#    installs them, and step 2 is the first command that fails without them.
sudo apt-get install -y age
curl -fsSLO https://github.com/getsops/sops/releases/download/v3.13.3/sops_3.13.3_amd64.deb
sudo apt-get install -y ./sops_3.13.3_amd64.deb

# 1. Get the repo. `main` is this tier; tier-1 (a single node, no management
#    cluster) lives on the `tier-1-solution` branch and is not interchangeable.
git clone <repo-url> && cd ais-edge

# 2. Create your age key and register it as a SOPS recipient
scripts/site-secrets.sh init-key
scripts/site-secrets.sh add-recipient <your age1... public key>

# 3. Scaffold the MANAGEMENT site (copies sites/example-mgmt/)
scripts/site-secrets.sh new my-site mgmt

# 4. Add each EDGE. PREFER add-edge OVER `new <name> edge`: it does this step and
#    the S3 wiring in one go, GENERATING the key pair rather than making you type
#    the same one into two files.
scripts/site-secrets.sh add-edge my-site my-edge

#    `new my-edge edge` also works, and then the edge's name has to be made to
#    agree in FIVE places by hand. Renaming an edge means editing all of them:
#      sites/my-site/values.yaml       edges[].name
#      sites/my-site/values.yaml       edges[].s3SecretRef
#      sites/my-site/secrets.enc.yaml  that Secret's metadata.name
#      sites/my-edge/values.yaml       clusterLabel
#      the site directory name itself
#    Getting one wrong RENDERS CLEANLY: the management chart provisions a control
#    plane for an edge that never checks in, and the edge asks for one that was
#    never provisioned.

# 5. Edit them. The management file carries everything shared — domain,
#    hostnames, node IPs, the edges list, the fleet-wide data policy. Each edge
#    file carries only what is local to that site: its de-identification
#    recipe, the tags that give the XNAT labels, its disk paths.
$EDITOR sites/my-site/values.yaml sites/my-site/secrets.enc.yaml
$EDITOR sites/my-edge/values.yaml sites/my-edge/secrets.enc.yaml

# 6. Encrypt — do this before committing anything
scripts/site-secrets.sh encrypt my-site
scripts/site-secrets.sh encrypt my-edge

# 7. Install
./install.sh my-site

# 8. PROVE IT WORKS. Do not skip this — `helm install` succeeding only means the
#    objects were accepted, not that the fleet is actually working.
#    install.sh does not wait for edge pipeline pods. Wait until each expected
#    pod is Running and ready, then run the checks below.
make verify-live SITE=my-site
```

> **Back up the usable SOPS recipient keys.** Your age key can decrypt files
> encrypted to its recipient. A file can have several recipients; losing one
> key does not destroy access while another remains. Losing all usable keys
> does. Store approved recovery copies separately from the encrypted site files,
> and verify that a retained key can decrypt the files you must recover.

### Then verify, every time

```bash
make verify-live SITE=my-site        # or: scripts/verify-live.sh my-site
```

This is the difference between "Helm accepted the manifests" and "a study sent
to an edge will reach XNAT". It reads the SAME `sites/<site>/values.yaml` the
install used, so it checks *your* hostnames, namespaces and edge list — nothing
in it is hardcoded, and a deployment that keeps its data somewhere other than
`/data` is checked where it actually lives.

On this tier it walks the whole fleet: the management API server, node
readiness, pod health per namespace, the `ais-edge-ca` Certificate and every
Certificate derived from it, the SeaweedFS S3 Service, each edge's hosted
control plane, and XNAT reachability. Its normal exit code is 0 when no check failed, even if some were skipped,
and 1 when a check failed. Setup/usage errors can exit 2. Read `NOT CHECKED`
as well as the status code. The probes do not establish complete DICOM
delivery or content equality; send a synthetic study and inspect its destination.

Run it:

* after `install.sh`, always;
* after adding an edge — a `join: bundle` edge in particular, because nothing
  on the management side can tell you the operator actually ran the bundle;
* after rotating a Secret or the CA;
* after a reboot of the management node or any edge.

> The edges' DICOM receivers listen on a **`hostPort`**, which is invisible from
> inside the cluster, so verify-live cannot confirm them and does not pretend to.
> Prove that leg with a real C-STORE from a machine that will send studies.

### What each step does, and why it is not all Helm

| Step | Does | Why it cannot be a chart |
|---|---|---|
| **1** | k0s, kubectl, helm, local-path-provisioner | there is no cluster yet |
| **2** | cert-manager, then the k0smotron operator — both pinned | there are no CRDs yet, and cert-manager must exist **before** the chart |
| **3** | site Secrets, SOPS → cluster | must precede the workloads that mount them |
| **4** | `helm install` management chart | — |
| **5** | child kubeconfig + join token, per edge | a Helm-rendered token would be re-minted on every upgrade |
| **6** | join the edge worker — over SSH (`join: ssh`, the default), or by a self-contained bundle you carry to the site and run there (`join: bundle`, see **Edges** below) | the worker has to be joined from outside the cluster; with `join: bundle` the management node never touches it at all |
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
edge without its `ca-bundle`, its `loki-push-client-tls` and its
`s3-edge-credentials` for up to six hours — and none of the three is optional:
the s3-uploader mounts `ca-bundle` and reads its S3 key pair out of
`s3-edge-credentials` as environment variables, and Vector mounts `ca-bundle`
and `loki-push-client-tls`, so neither pod can start at all. Step 7 runs the
CronJob's own pod spec once via `kubectl create job --from=cronjob`, so it
cannot drift from what the schedule does later.

The S3 key pair is delivered rather than written on the edge for the same
reason the CA bundle is: it is one credential that would otherwise have to be
typed identically into two files — `<edge>-s3` here, which SeaweedFS builds the
edge's scoped identity from, and `s3-edge-credentials` there, which its uploader
authenticates with. A mismatch stalls the pipeline at upload with an S3 403 and
nothing says why, so the edge's own secrets file deliberately does not carry it.

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
    sshKey: ~/.ssh/id_ed25519       #   over ssh. OMIT BOTH for join: bundle.
    s3SecretRef: edge-dev-s3
    exposure: sni                   # sni | nodePort — use sni
    # joinTokenTTL: 2h              # how long this edge's join token stays valid.
    #                               # Default 2h. The ssh path spends it in
    #                               # seconds; raise it only for a `join: bundle`
    #                               # edge whose bundle has to travel further than
    #                               # that. It is a BEARER credential — anything
    #                               # holding it can join a node — so a longer
    #                               # window is a deliberate decision.
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

**Historical sizing sample (date not recorded; reviewed 2026-11-10):**
231Mi per uploader and a 15-site estimate on 16Gi came from an older workload.
They are not a current capacity limit. Budget for configured requests, limits,
archive buffers, hosted control planes and shared services. Measure concurrent
large-study loads with the pinned image before adding a site.

### Edge-local configuration

`sites/<edge>/values.yaml` carries only what is genuinely local: the
de-identification recipe, the tag mapping, and storage paths. Everything else is
**derived** from the management site file, which is passed to the edge release
as well:

| Derived | From |
|---|---|
| `upload.s3.endpoint` | `hostnames.seaweedfs` or `seaweedfs.<domain.internal>` |
| `upload.s3.bucket` | `<bucketPrefix>-<clusterLabel>` when `perSiteBuckets` |
| `observability.loki.endpoint` | `hostnames.loki` or `loki.<domain.internal>` |
| `hostAliases` | `domain.mgmtNodeIP` + the hostnames edge pods actually dial |

Historically these values were copied into both files and could drift. Wrong
endpoints can produce DNS, TLS or HTTP failures and retained local copies.
The uploader emits retry/failure logs; alerts depend on delivery of those logs
and their thresholds. A quiet dashboard alone does not prove delivery. The
derived defaults reduce duplication, but explicit overrides still need review.

### De-identification

```yaml
deid:
  engine: ingest                # the default, and the only engine for a new site
  policyReviewed: false         # no safe default: set it after you read the recipe

ingest:
  # deidentify.specs is THE RECIPE: a pydicom deid recipe per project. Copy
  # the COMPLETE recipe from sites/example-edge/values.yaml. A short fragment
  # is not a full policy.
  # deidentify.reidEncryptKeySecret: reid-key   # production: encrypt the maps
  assign:
    tagMapping:                 # these tag VALUES become the XNAT labels
      project: StudyID
      subject: PatientID
      session: AccessionNumber
    # constantProjectId: my_project    # or: file every session under one project
```

* **`deid.policyReviewed` has no safe default.** The chart refuses to render
  until a human asserts they have read the recipe for this site. It lives at
  the top level next to `deid.engine`, not under `orthanc:`, because it gates
  every engine.
* **Only the tags the recipe names change.** Every other tag reaches XNAT
  unchanged, so UIDs are retained and a study stays internally consistent
  across series. A recipe for a project replaces `__default__` for that
  project. Start from the complete recipe in `sites/example-edge/values.yaml`.
  It removes 17 tags and adds two de-identification markers. A short fragment
  at the same key replaces all of that, so a fragment is not a full policy.
* **XNAT labels come from source tag values with character normalization.** `assign` reads them before
  the recipe runs, so no recipe can change them. `assign` preserves letters, digits, underscores and hyphens; each run of
  other characters becomes `_`. This is normalization, not pseudonymisation. PatientID often holds a hospital
  medical record number. If it does, `subject: PatientID` puts that number
  into XNAT in the clear, so choose pseudonymous tags. An approved research
  identifier in PatientID is fine. There is no AE-title routing. A study with
  an empty tag goes to `/data/assigned/__invalid__`, still identifiable.
* **The re-identification maps are plain JSON without a key.** They are in
  `/data/reid` on the edge. Set `ingest.deidentify.reidEncryptKeySecret` at a
  production site. The Secret needs the key `XINGEST_REID_ENCRYPT_KEY`, a
  Fernet key.
* **`deid.engine: orthanc` is deprecated.** Do not use it. Its reference
  material is in `docs/components/deidentification.md`, "Deprecated: Orthanc
  Lua engine".

---

## Secrets

The charts never contain credentials. They reference Secrets by name, and those
Secrets are created separately from a SOPS-encrypted file.

```bash
scripts/site-secrets.sh add-recipient <age1...>      # add a key; then `sops updatekeys` each existing file
scripts/site-secrets.sh new <site> <mgmt|edge>       # scaffold; the ROLE is required
scripts/site-secrets.sh add-edge <mgmt-site> <edge>  # scaffold an edge AND mint its S3 key pair
scripts/site-secrets.sh encrypt <site>               # before committing; does nothing on an encrypted file
scripts/site-secrets.sh edit <site>                  # decrypt → $EDITOR → re-encrypt
scripts/site-secrets.sh view <site>                  # print decrypted (careful: terminal)
scripts/site-secrets.sh apply <site>                 # decrypt straight into the cluster
scripts/site-secrets.sh check                        # fail if any committed secret is plaintext
```

**`new` does not guess the role.** An edge scaffolded from the management
template renders perfectly — Helm ignores values a chart does not declare — and
then silently overrides the fleet's `dataPolicy` from the wrong file; a
management site scaffolded from the edge template is missing every hostname the
edges derive their endpoints from. Both fail much later and in the least obvious
way, so the argument is mandatory rather than defaulted.

**Use `add-edge` to onboard an edge**, not `new … edge`. It scaffolds
`sites/<edge>/`, mints the edge's S3 key pair once, and writes it into the
management secrets file as `<edge>-s3` — the one credential that still has to
exist in two places, and the last one a human could mismatch by hand. It
deliberately does **not** edit the management `values.yaml`: that file is the
most heavily annotated in the repo and a YAML round-trip would destroy every
caution comment in it, so it prints the `edges:` block for you to paste, along
with the steps it cannot do for you.

`apply` pipes plaintext directly into `kubectl` without writing a plaintext
manifest in the checkout. Editors, swap and the destination cluster are outside
that narrow guarantee. The command also creates namespaces named by the Secrets, which is what makes
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
  enabled: false      # disables policy deletes; pipeline source retirement is separate
  dryRun: true        # decisions are logged, never acted on

  originals:                                   # the archive of record
    allowExpiry: false  # the THIRD switch — while false the facility-backup
                        # volume is mounted read-only and no original is removed
    facilityBackup: {retain: forever, minFreeDiskPercent: 10}
    quarantine:     {retain: forever, alertAfter: 24h}   # only the deprecated orthanc engine writes here
    fileDrop:       {reclaim: never,  minAge: 30d}

  derived:                                     # reproducible from the originals
    orthancStorage: {reclaim: onGrouped,       minAge: 7d}
    grouped:        {reclaim: onAssigned}      # no minAge: assign unlinks at
                                               #   assign time, so only orphans
                                               #   reach the engine; setting it
                                               #   is rejected at render
    assigned:       {reclaim: auto,            minAge: 0}   # auto = onDeidentified under ingest
    s3Staged:       {reclaim: onXnatConfirmed, minAge: 36h,
                     verifyAgainstXnat: true, maxRemovals: 50,
                     schedule: "17 * * * *"}
    # The bucket clock above must stay longer than the edge clock below.
    # The edge reclaimer is the delete authority for the terminal tree in
    # both upload modes: assigned, deidentified, or packaged when enabled.
    # In direct mode it proves each file in XNAT. In S3 mode it proves the
    # current local files against the bucket, including their content.
    # The bucket reclaimer later proves its copy in XNAT at the longer clock.
    stagedReclaimer: {minAge: 1d, verifyAgainstXnat: true,
                      maxRemovals: 50, schedule: "17 * * * *",
                      deadlineSeconds: 3000}

  telemetry:
    # the kubelet rotates by size x count, not by time. 10Mi x 5 = 50Mi
    # of on-disk log per container.
    podLogFiles: {maxSize: 10Mi, maxFiles: 5}
```

**Loki and Prometheus retention are not set here.** Helm cannot template a
subchart's values from the parent, so keys under `telemetry` for them would read
exactly like policy and do nothing — an operator could edit them, see a clean
install, and keep the old retention indefinitely with nothing to say so. Setting
`telemetry.loki` or `telemetry.prometheus` is now **rejected at render time**.
Set retention where it is actually read, in the same `sites/<site>/values.yaml`:
`kube-prometheus-stack.prometheus.prometheusSpec.retention` for Prometheus and
`loki.loki.limits_config.retention_period` for Loki. `podLogFiles` is likewise
not a duration — the kubelet rotates container logs by size and count only, so a
window it could never honour was unimplementable rather than merely unwired. It
is applied as `--kubelet-extra-args` at **worker-join time**, on both join paths,
so changing it affects workers joined afterwards; an already-joined node needs its
k0s worker service reinstalled, and `make verify-live` fails on the mismatch
rather than letting the edit look applied.

Three properties worth understanding:

**Derived cleanup requires its configured proof and any supported age gate.**
Grouped retirement is the exception to a universal age rule: assign can unlink
its successful input snapshot without a grouped `minAge`, and the chart rejects
that key. Upload reclaimers require their own age and proof checks. An age by
itself is not evidence that XNAT received data; a failed proof keeps the input.

**`onXnatConfirmed` verifies each file, not existence.** XNAT creates the
experiment on the first resource POST, so "the experiment exists" is true even
for a partial upload. The reclaimer reads every `__MANIFEST__.json` for the
file names of a resource, finds each name's row in the one XNAT resource the
uploader maps that folder to (the same scan id, the label accessionflow derives
from the SOP class), and sends a HEAD for the file: only a 200 with a
Content-Length equal to the staged size counts. Per-resource totals are not
trusted. A historical 2026-08-10 test showed a nonzero total and an empty
listing. That response discrepancy did not establish whether physical bytes
were lost; it established that the summary was insufficient cleanup proof. Every
uncertainty (an unreadable manifest, a 500 from XNAT, an unmapped resource, an
object that changed after the listing) resolves to **keep** for that resource.
An upload batch folder, an entry the reclaimer does not recognise, and the
sidecars that still describe something are never touched; the resources proven
next to them are reclaimed one at a time, so a session empties as its resources
are proven.

**`maxRemovals` bounds a bug.** A run that decided "delete everything" is capped
per run, leaving the rest for somebody to notice. At the hourly schedule this
still drains ~1200 sessions/day.

**Policy expiry is disabled on a fresh install.** Run with `dryRun` and read
the decisions before arming it. This does not stop pipeline source retirement:
`--unlink-source all` can remove a successful input snapshot, including files
not represented in the output. The tool does not first verify a backup copy.

**Originals need a third switch.** `enabled` and `not dryRun` arm the *derived*
stages only. A duration on `originals.facilityBackup` or `originals.quarantine`
does nothing until `dataPolicy.originals.allowExpiry` is also true — the
`edge-data-policy` DaemonSet logs `expiry_skipped` instead, and the chart keeps
the facility-backup volume mounted read-only, so the kernel refuses the delete
through that mount. It does not protect against a different writer or host
administrator. Deleting the archive can destroy a retained original; other
identifiable copies can also exist in Orthanc, grouped, assigned and reid
storage. Review the retention obligation before arming any originals expiry.
Full truth table: `docs/TOUR.md` §5c.

---

## Security model

| Boundary | Mechanism |
|---|---|
| Hospital → management | Runtime management traffic uses outbound TLS. The default SSH bootstrap and teardown require inbound SSH; the bundle path performs bootstrap locally. DICOM reception has its own inbound port. |
| Between edge sites | **One S3 bucket per site.** SeaweedFS matches identity actions as `<action>:<bucket>` with **no prefix scoping**, so a shared bucket would let any edge key read and delete every other site's staged imaging. The bucket is the only boundary there is. |
| Edge → XNAT | The edge has **no XNAT credential**. Only the management uploader does. This is the main operational advantage of `upload.mode: s3`. |
| S3 ingestion | Per-edge **SigV4 key pair**, scoped to that site's bucket (the row above). Optionally a second factor: `seaweedfs.ingress.clientCerts` adds a per-edge **client certificate**, verified at the SeaweedFS Ingress with the same `auth-tls-*` annotations the Loki path uses ; the key pair is a bearer secret usable from anywhere, cert-manager creates the certificate and private key on management and cert-sync copies both to the edge. The default certificate lifetime is 90 days, with renewal before expiry; verify issuance and sync rather than assuming a successful rotation. **Ships off**, and turning it on is a four-step rollout (`issue` → confirm `s3-client-tls` landed → edge `requireClientCert` → `require`): flipping verification on before the certificates arrive breaks every upload with an error that names nothing ; measured, the handshake succeeds, nginx answers HTTP 400, and rclone reports it as an S3 XML parse failure, so it reads as a dead endpoint. See `docs/components/seaweedfs.md`. |
| Loki ingestion | Per-edge **client certificate (mTLS)**, verified at the Ingress (`auth-tls-verify-client: on`, with `auth-tls-match-cn` pinned to the names in `edges`). cert-manager issues one `<edge>-loki-client` certificate per site and cert-sync delivers it as `loki-push-client-tls`. Loki itself runs `auth_enabled: false`, so the Ingress is the only place it is checked. The CN pin admits every site on the one push hostname, so it bounds *which* certificates are accepted, not one edge writing under another's name. |
| TLS | Internal CA via cert-manager. An https S3 endpoint with no CA bundle is **refused at render time**. The uploader is rclone, and an empty `RCLONE_CA_CERT` falls back to the system store, which does not hold the internal CA, so every transfer would fail the handshake. (The older client, the AWS CLI, was worse: an empty `AWS_CA_BUNDLE` silently disabled verification.) |
| Credentials at rest | Keep plaintext credentials out of values and ConfigMaps. Commit only SOPS-encrypted site secrets. Kubernetes Secrets and their consumers still hold usable credentials; SOPS does not encrypt all runtime copies. |
| CA private key | cert-sync rejects configured copies of the CA private key to an edge. This is a chart guard, not a restriction on administrators who can read management Secrets. |

`install.sh` also **refuses to install** if `sites/<site>/secrets.enc.yaml` is
not SOPS-encrypted, or — when `sops` is on `PATH` — if any *value* in it is
still an unfilled `REPLACE_` placeholder. This preflight decrypts to a pipe without a plaintext manifest in the checkout,
and checks the values rather than the file text: the templates' own comments say
"fill in every REPLACE_", so grepping the whole file refused to install a
complete, correct site. Note the two limits of that check: `sops` is not in the initial
required-tools list, so on a node without it this preflight is skipped. The
subsequent secret-apply step still needs decryption. `check-site-secrets.py`
adds structural checks; this is not a general password-strength policy. Review
site credential requirements separately. The check exists because the template once shipped
working defaults annotated "change defaults", and the first deployment ran with
them unchanged — a comment is advice, and advice does not fail an install.

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
`upload_completed` and `upload_failed` are matched by three Loki ruler alert
rules — `XNATUploadFailingForAllSessions`, `S3UploaderRetryStorm` and
`SessionUploadStalled`, five event matchers between them in
`charts/mgmt/files/loki-ruler-rules.yaml` — and by eight Grafana dashboard
panels; renaming one disables the corresponding alert silently.

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
Makefile                       CI entrypoint (make ci-fast / make ci), and
                               make verify-live SITE=<site>, which is NOT CI
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
  verify-live.sh               read-only checks against a RUNNING deployment
  uninstall.sh                 full reset
  01,05,06,06b,06c             bootstrap steps Helm cannot do — 06 joins over
                               SSH, 06b builds the carry-over bundle for an edge
                               with no inbound path, 06c is the post-join work
                               both paths share
  files/edge-join.sh           the join itself; runs ON the edge, identical for
                               both paths
  adopt-existing.sh            take over a running imperative install
  rotate-ca.sh                 two-phase CA rotation across the fleet
  clear-staged-s3.sh           clear the S3 staging prefix; empty session
                               prefixes only, unless you pass --all
  check-alert-inputs.sh        ask live Prometheus whether alerts can fire
  ci/                          CI stages (render, negative, promtool, …), one
                               script per stage, invoked by the Makefile
tests/
  reclaimer/                   filesystem/S3 deletion proofs and the pinned-image
                               deidentify sidecar contract; read current case counts from the run
  loki-rules/                  the real Loki rule expressions, against fixture
                               logs, evaluated by the pinned Loki
  data-policy/                 the real engine under the real image, asserting
                               on what SURVIVED
config/k0s-controller.yaml     the management k0s controller config (scripts/01)
manifests/01-management/       the k0smotron Cluster template rendered by
                               scripts/05, one per edge
docs/                          component guides, CA ceremony, alerting design
```

---

## Continuous integration

```bash
make ci-fast     # no cluster; selected stages still use Docker
make ci          # adds the four docker-based stages: loki-rules, data-policy,
                 # s3-uploader-image, greenfield

make verify-live SITE=<site>   # NOT CI — read-only checks against a RUNNING
                               # deployment. See "Then verify, every time".
```

| Stage | Proves |
|---|---|
| `render` | both charts render across the combinations in `scripts/ci/render.sh`, including ingest, packaging and upload modes |
| `negative` | declared render-time guards reject their invalid configurations, with a census for guards lacking a case |
| `promtool` | Prometheus expressions are tested with `charts/mgmt/files/prometheus-rules/tests/` fixtures; Loki expressions have a separate harness |
| `shell-syntax` | every script parses; no `yes \|` pipeline under `pipefail` |
| `pvc-retention` | data-bearing manifests carry the expected Helm/PVC retention settings; this does not stop runtime reclaimers, uninstall or host deletion |
| `runtime-templates` | scripts survive Helm rendering |
| `duplicate-names` | no two objects collide |
| `reclaimer` | real filesystem and mocked HTTP/S3 cases assert which data survives and which objects are deleted. They cover file size and ETag proof, multipart ETags, writer locks, repair requests, stale-object 412 responses and conditional DELETE paths. The same target runs the pinned-image deidentify sidecar probe. Case counts come from the exact test revision |
| `reclaimer-fence` | 27 cases against a stub kubectl: the drain and resume around an upgrade of the edge's staged-reclaimer fail closed, a failed read is never "no Job runs" |
| `cleaner-activation` | 27 cases against a stub kubectl and a stub curl: the order of the steps that opt a bucket out of the SeaweedFS cleaner, and that a failed query (a pod listing, the multipart check, a scale) is never read as "nothing runs": a failure attests and resumes nothing beyond that point, what it changed stays marked on the object, and a rerun puts it back |
| `s3-uploader` | 9 cases against a stub rclone: the uploader copies only inside the upload-tree writer lock, skips a session while the lock is held, claims a repair request by rename and answers it with `--ignore-times`, returns it on a failed copy, requeues a claim left by a crash, and has no delete at all |
| `secret-contract` | every mounted Secret exists, in the right namespace, with the right keys |
| `values-consumers` | audited `dataPolicy` leaves have a reader or a tracked exception. `KNOWN_DEAD` is empty; `originals.fileDrop.minAge` remains declared but not enforced. This is not a census of every values key |
| `loki-rules` | the real Loki ruler expressions, evaluated against fixture logs by the pinned Loki — promtool covers only the Prometheus rules |
| `data-policy` | the edge retention engine runs under the chart-pinned curl image, with assertions on surviving files, Orthanc receipt checks and policy refusal cases |
| `s3-uploader-image` | the uploader loop inside the pinned shell image, with rclone lifted in as the initContainer does it: one real copy |
| `greenfield` | the charts install onto an empty cluster |

**Current suite (2026-11-10):** `FAST_STAGES` has 20 stages and
`ALL_STAGES` adds four. The old table recorded 40 render combinations, 114
negative checks, 47 Prometheus groups/85 assertions and 114 reclaimer cases.
Those are historical snapshots, not the current gate totals. Read the summary
from the exact commit tested. Additional fast stages include `verify-live-checks`,
`lua-syntax`, `fingerprint-contract`, `shared-files`, `cli-contract`, `notes`
and `log-phrases`; they check verifier semantics, Lua parsing, shared code,
rendered arguments, CLI/environment support, operator output and log consumers.

The last four need Docker, and some fast stages do too. They **skip loudly** without it, and the skip is
reported separately from a pass, so a docker-less run never reads as "the charts
are installable". `CI_REQUIRE_LOKI_TESTS`, `CI_REQUIRE_DATAPOLICY_TESTS`,
`CI_REQUIRE_UPLOADER_IMAGE` and `CI_REQUIRE_GREENFIELD` turn each skip into a
failure, which is what the GitHub workflow sets.

Two of these exist because of specific classes of silent failure:

**Reclaimers delete patient data**, so their tests assert the actual deletes.
Pipeline source retirement and the data-policy adapters also delete data under
their own controls and tests. These paths use different proof; no one test
suite establishes all retention behavior. A run that logs `reclaim_kept` and issues a
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

Start with `make verify-live SITE=<site>` — it reads the site file and checks
the whole fleet in one pass, so the one-liners below are for when it has told
you *where* to look, or when you want a number it does not report.

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
dcmsend <edge-node-ip> 4242 -aec AISEDGE synthetic-study.dcm
```

Then follow it: Orthanc logs (the `instance_archived` event, with its
`backupPath`) → `/data/facility-backup` → `/data/grouped` → `/data/assigned` →
`/data/deidentified` → `upload_completed` in the s3-uploader log →
`s3://ingest-<edge>/staged/` → the management uploader log.

Re-sending an unchanged instance with the same DICOM UIDs may produce no new
upload notification. Orthanc deduplicates stored instances; grouping checks
its export snapshot, and the uploader skips a session whose remote files are
complete. The processed label alone is not a permanent skip when new instances
arrive. Use a new synthetic StudyInstanceUID and known labels to test a fresh
write, then verify the remote inventory rather than counting notifications.

### Adding an edge

An `edges:` entry alone is not enough — the new site also needs its own
`sites/<edge>/` directory and an S3 key pair. Without them `install.sh` dies at
step 7/7 with `missing sites/<edge>/values.yaml`, *after* the hosted control
plane is up and the worker has joined, which is the expensive half.

```bash
# 1. scaffold sites/<edge>/ and generate its S3 key pair into the management
#    secrets file as <edge>-s3 (cert-sync delivers it to the edge as
#    s3-edge-credentials; do not write it on the edge side). Prints the
#    'edges:' block to paste.
scripts/site-secrets.sh add-edge <site> <edge>

# 2. the de-identification recipe, the tags that give the XNAT labels, and
#    the disk paths: facts only you have, so nothing generates them. Read the
#    recipe, then set deid.policyReviewed: true.
$EDITOR sites/<edge>/values.yaml

# 3. the salt Secret. The template ships AIS_DEID_HMAC_SALT:
#    REPLACE_64_HEX_CHARS. The Orthanc pod needs the Secret. Under
#    deid.engine: ingest nothing uses its value. Fill it in so that encrypt
#    does not warn. At a production site, also add the reid key Secret.
openssl rand -hex 32
$EDITOR sites/<edge>/secrets.enc.yaml

# 4. paste the printed block under 'edges:'. s3SecretRef must be <edge>-s3 —
#    cert-sync substitutes <edge> and nothing else, and the chart refuses to
#    render if the two disagree.
$EDITOR sites/<site>/values.yaml

# 5. encrypt the new edge before committing (add-edge already re-sealed the
#    management file if it was encrypted)
scripts/site-secrets.sh encrypt <edge>

# 6. install, then prove it
./install.sh <site>
make verify-live SITE=<site>
```

The installer also reconciles existing sites; changed shared values can roll
their workloads. The new site gets its own control plane, bucket, identity,
uploader and reclaimer. Review the merged values before applying them. Full walkthrough: `docs/TOUR.md` §5b.

### Removing an edge

Plan data retention and credential revocation before decommissioning. Entry
removal and `helm upgrade` remove rendered consumers, but the create-only bucket
hook preserves the staging bucket and its data. Retained Secrets, copied keys
and certificates need explicit handling. A worker reset and host-data removal
are separate destructive steps; verify retained copies before carrying them out.

### CA rotation

Two phases, weeks apart — see `docs/ca-ceremony.md`. cert-sync distributes the
new bundle to every edge on its schedule, so rotation does not require visiting
each site. `CertificateExpiringSoon` fires at 60 days.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Edge pods `CreateContainerConfigError` | A Secret is missing. Most often `ca-bundle`, `loki-push-client-tls` or `s3-edge-credentials`, all three delivered by cert-sync — run its job manually: `kubectl -n ais-mgmt create job x --from=cronjob/mgmt-cert-sync-<edge>` |
| `helm install` fails with `conversion webhook … connection refused` | The k0smotron operator is not ready. It needs cert-manager, which must be installed *before* the chart. |
| `invalid ownership metadata` on install | An object exists without Helm's ownership labels, usually from a previous non-Helm install. `scripts/uninstall.sh` clears these. |
| Worker join times out | For `join: bundle`, verify that the operator ran a fresh bundle. Otherwise inspect DNS or the managed `/etc/hosts` entries, API readiness, outbound reachability and token expiry. The current join scripts reconcile managed host entries; do not assume the old stale-marker defect still applies. |
| Uploader retries forever, no arrival on management | Inspect the edge uploader logs for DNS, TLS, HTTP and retry errors. Check the resolved endpoint and CA bundle. Local copies remain on failure; log transport and alert thresholds determine whether management receives a warning. |
| `XNATAuthFailure` while uploads succeed | Historical progress-bar false positives were fixed by requiring HTTP context and excluding `it/s`. A real authentication failure can still occur beside successful uploads. Inspect the matched log, credential validity and reconnect outcome; success does not dismiss the alert. |
| Loki logs `NoSuchBucket` at startup | The bucket hook runs after install/upgrade. Retry errors may clear when it succeeds. Persistent errors need checks of the hook Job, credentials and SeaweedFS readiness; recovery is not guaranteed by waiting. |

---

## Orthanc REST API Authentication

The chart default sets `orthanc.auth.enabled: true`; the `example-edge`
site overrides it to `false`. Check the merged site values. The REST Service
defaults to `ClusterIP`. This limits normal external exposure but is not an
authorization boundary: reachable clients, including in-cluster workloads or
users with port-forward access, may call it. The API can delete studies.
Enable authentication and supply the three matching Secret keys below.

Three keys, all required, because three different things read this Secret:

| Key | Read by | If it is wrong |
| --- | --- | --- |
| `users.json` | Orthanc itself. The chart mounts it at `/etc/orthanc/users.json`, a configuration fragment that Orthanc merges at start. There is no `RegisteredUsersFile` option | Orthanc answers 401 to every request. If the key is missing, the volume does not mount and Orthanc does not start |
| `orthanc-user` | `group-orthanc` and the data-policy engine, which call the REST API | Orthanc answers 401. Grouping cannot export studies and can retry or exit depending on where the error occurs; the policy adapter logs `backend_unavailable` and keeps the store |
| `orthanc-password` | `group-orthanc` and the data-policy engine | as above |

`orthanc-user` / `orthanc-password` **must match** the user and password inside
`users.json`. They are separate keys because Orthanc wants a configuration file,
and `group-orthanc` and the data-policy engine want environment variables.
Nothing reconciles them for you.

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
  namespace: xnat-ingest          # the EDGE site's namespace
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
./install.sh <mgmt-site>      # step 7 applies the edge's Secrets to the edge cluster, then upgrades the edge chart
KUBECONFIG=kubeconfig-<edge> kubectl -n xnat-ingest rollout restart deploy/<release>-orthanc
KUBECONFIG=kubeconfig-<edge> kubectl -n xnat-ingest rollout restart deploy/<release>-group-orthanc
KUBECONFIG=kubeconfig-<edge> kubectl -n xnat-ingest rollout restart ds/<release>-data-policy
```

`<release>` is `edge` when `install.sh` installed the chart. Do not run
`site-secrets.sh apply <edge>` while `KUBECONFIG` points at the management
cluster: it would create the edge's Secrets there. All three restarts are
needed: Kubernetes does not restart a pod when a Secret changes, and none of
these pods re-reads one at runtime.

**4. Verify.**

```bash
# The Orthanc image has no curl, so reach the API through a port-forward.
# Run it in a second terminal, wait for "Forwarding from 127.0.0.1:8042",
# and stop it with Ctrl-C afterwards:
#   KUBECONFIG=kubeconfig-<edge> kubectl -n xnat-ingest port-forward deploy/<release>-orthanc 8042:8042
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

```bash
scripts/uninstall.sh <site>                  # full reset, both nodes
scripts/uninstall.sh --keep-cluster <site>   # workloads only, keep k0s running
```

The default is a genuine clean slate: both Helm releases, the configured component namespaces,
CRDs and admission webhooks, cluster-scoped RBAC (including the Roles these
components leave in `kube-system`), every PersistentVolume **and its host
directory**, `/data` on every node, `/etc/hosts` entries **and their marker
comments**, the generated kubeconfigs and join tokens, and `k0s reset` on the
management node and each edge.

**One exception, and it is loud: a `join: bundle` edge.** The remote half of a
teardown runs over SSH, and a bundle site has no inbound path by definition. The
script detects that — `join: bundle`, or an empty `sshUser` — warns that **the
edge half is not done**, and prints the commands to run on the edge itself:
`k0s stop`, `k0s reset`, the `/data`, `/var/lib/k0s`, `/etc/k0s` and
`/var/lib/vector` wipe, the `/etc/hosts` line, and a reboot to clear CNI
interfaces and iptables state. That check exists because the old condition only
required `sshUser` to be non-empty — which a bundle site legitimately leaves out
— so it skipped in silence and "full reset" reported success with k0s still
running and `/data` intact on the machine.

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
| accessionflow | `0.19.0`: upstream `ghcr.io/australian-imaging-service/accessionflow`, in both charts. Replaces the former xnat-ingest 0.16.2.post1 fork; deployed object names, paths and Orthanc receipt labels stay the same |

These are **source pins reviewed on 2026-11-10**, not a new live compatibility
or vulnerability certification. Vector has separate versions: management chart
0.57.0 and edge image 0.49.0. The old live observations are historical; their
measurement dates were not recorded here. The installer previously used moving
`/latest/` and `/stable/` URLs. Check the lock files, image tags, release notes
and validation results before a deliberate upgrade.

### Requirements

* Ubuntu 22.04 on the management node and each edge
* Key-based SSH from the management node to each edge — **only for `join: ssh`,
  the default**. A site with no inbound path uses `join: bundle` and needs no
  SSH at all (see **Edges** above, and `docs/TOUR.md` §4.1). Teardown of a
  `join: bundle` site then has to be finished by hand on the edge.
* `sops` and `age` on the management node
* Ports: **443** inbound on the management node; **4242** (DICOM) on each edge
  from its modalities; **22** inbound on each edge from the management node
  **for `join: ssh` only**. In steady state — and always under `join: bundle` —
  the edge only dials *out*, to the management node on 443, under either
  `exposure` mode.
* Size management RAM for measured concurrent load. The historical 16Gi /
  15-site estimate is not verified for the pinned image (2026-11-10); include
  per-edge control planes, uploader limits, archive buffers and shared services.
