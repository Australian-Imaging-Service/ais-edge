# accessionflow

The pipeline tool is accessionflow (called xnat-ingest before 0.18.0).

## Overview

**Verified scope (2026-11-10):** descriptions below follow this branch
and accessionflow 0.20.0. Orthanc is the receiver; the default `ingest` engine
de-identifies downstream. The Orthanc/Lua de-identification engine was
deprecated on 2026-11-02 and appears only for existing-site diagnosis or history.
Recipe output and source retention must be checked separately: a stage name,
processed label, or successful upload is not proof of a complete privacy policy.

[accessionflow](https://github.com/Australian-Imaging-Service/accessionflow)
is the AIS-maintained Python tool that groups, labels, and de-identifies DICOMs into
XNAT-ready sessions and uploads them. The pinned version is **0.20.0**,
from the upstream accessionflow image. It replaces the AIS fork build
0.16.2.post1 (`ingest.image` in `charts/edge/values.yaml`). The old single `sort` command
was split into these stages:
1. **`group-orthanc`** (`accessionflow collate orthanc`): queries Orthanc study
   metadata over REST and hardlinks its stored DICOM files into per-session directories
2. **`assign`** (`accessionflow label xnat`): extracts the XNAT project/subject/session/scan IDs from
   the grouped DICOMs and stages them as a structured directory
3. **`deidentify`**: applies the site's de-identification recipe to each
   assigned session. It is the default de-identification engine
   (`deid.engine: ingest`)
4. **`upload`** (`accessionflow store xnat`): pushes staged sessions to an XNAT server via REST

We run these as accessionflow pods, plus one non-accessionflow
uploader that carries the sessions between the edge and the management
node:
- **`accessionflow collate orthanc`**, **`accessionflow label xnat`** and
  **`accessionflow deidentify`** on each edge VM
- **`s3-uploader`** on each edge VM — an `rclone copy` loop, not
  accessionflow at all (see "Where it runs"). It was `aws s3 sync` until the
  rclone port; `rclone copy` is deliberate, because `rclone sync` deletes at
  the destination and `aws s3 sync` does not
- **`accessionflow store xnat`** on the management node, rendered **once per
  edge site** rather than once for the fleet
- **`accessionflow package`** runs on each edge VM. It is optional and off by default
  (`ingest.package.enabled`, under `deid.engine: ingest` only). Reads
  `/data/deidentified` and writes `/data/packaged`: each DICOM series becomes
  one `DICOM-zip` resource (`archive.zip`) plus one DICOM sample. The
  `s3-uploader` then reads `/data/packaged`, and the management uploader needs
  the vendor datatype package (`xnatUpload.extraPipPackages`). See
  [package-stage.md](../package-stage.md).

> **De-identification is done in accessionflow by default** (`deid.engine:
> ingest`). The `deidentify` stage runs between `assign` and the upload. It
> expects the studies to carry their project/subject/session identifiers in
> tags, and it writes sensitive re-identification metadata for fields it
> transforms. Those maps are not a complete original DICOM archive. The Orthanc Lua
> hook engine (`deid.engine: orthanc`) is deprecated. See
> [deidentification.md](deidentification.md) and
> [choosing-a-deid-engine.md](../choosing-a-deid-engine.md).

The group initializer tries Orthanc `/system` up to 18 times, with a five-second curl timeout and five-second pauses after failed attempts (up to about 180 seconds).
This checks HTTP availability, not response JSON; redirects and failed transfers do not count as ready.

## Role in this stack

The DICOM ingest engine. On each edge worker Orthanc receives studies and
writes a facility backup for DICOM-protocol arrivals when that callback
succeeds (see [orthanc.md](orthanc.md)). REST arrivals bypass that backup.
The Lua script also
labels each stable study `xnat-ingest-ready`, under `ingest` too. That label
does not show that the study is de-identified. `group-orthanc`
queries Orthanc over REST for each study that has been quiet for its wait period (under the
deprecated `orthanc` engine, only the studies labelled `xnat-ingest-ready`)
and hardlinks its stored DICOMs into `/data/grouped/<session>/`. Then `assign`
produces the `/data/assigned/<project>.<subject>.<visit>/` hierarchy:
`accessionflow label xnat /data/grouped /data/assigned`
(`charts/edge/templates/ingest-pipeline.yaml`), declared as
`dataPolicy.derived.assigned.location` in `charts/edge/values.yaml`. Then
`deidentify` writes the de-identified copy to
`/data/deidentified/<project>.<subject>.<visit>/`, which the edge uploader
reads.
There is **no `staging/` directory on the edge**: "staged" is the
*S3-side* word for those same sessions once the s3-uploader has synced
them under `s3://<bucket>/staged/`. The management upload pod pulls
from SeaweedFS (an `s3://` source) and pushes to XNAT.

## What accessionflow has access to

### group-orthanc + assign pods (edge)
- **The pipeline PVC, mounted at `/data`** — one hostPath-backed claim
  (`storage.pipeline.hostPath: /data/xnat-ingest`) that *every* stage
  mounts at the same path. Orthanc collation calls `os.link()` directly:
  its source and staging directories must share a filesystem. It cannot
  fall back to copying across filesystems. Other stages can use their
  configured copy mode; do not infer that fallback for group-orthanc. It
  reads `orthanc-storage/` and writes `grouped/`; assign reads
  `grouped/` and writes `assigned/`; deidentify reads `assigned/` and
  writes `deidentified/` and `reid/`
- **In-cluster HTTP to Orthanc**: group-orthanc queries study and attachment
  metadata and updates labels through
  `edge-orthanc.xnat-ingest.svc.cluster.local:8042` (release-prefixed;
  see [orthanc.md](orthanc.md)). It reads DICOM bytes from the shared local
  store. The assign stage uses the local filesystem.
- **Orthanc REST credentials** — group-orthanc reads `orthanc-user` and
  `orthanc-password` from the `orthanc-credentials` Secret, because
  Orthanc's API is authenticated (`orthanc.auth.enabled: true` by
  default). If they disagree with the user in that Secret's
  `users.json`, Orthanc answers 401 and the pipeline stalls silently
- **No XNAT credentials** — neither edge stage talks to XNAT
- **The upload-tree writer lock, `/data/.locks/<tree>.lock`**: the
  stage that writes the tree the uploader reads (`assign` under the
  Orthanc engine or none, `deidentify` under the ingest engine, `package`
  when the optional package stage is on) runs one
  pass at a time, and holds this lock for each pass (`edge.lockedStage`
  in `charts/edge/templates/_helpers.tpl`). With the package stage on,
  `deidentify` keeps holding its own `/data/.locks/deidentified.lock` for each
  pass, one pass per turn and without `--loop`, and `package` takes that lock
  and then `packaged.lock` for each of its passes, so a pass of one never runs
  beside a pass of the other, also during the upgrade that turns the stage on
  or off (see [package-stage.md](../package-stage.md)). Under `upload.mode: direct`
  the staged-reclaimer takes the same lock around each delete, and deletes
  only while the writer holds `/data/.locks/<tree>.alive`, a shared lock
  the writer keeps for its whole life. This does not change how a stage
  removes its own input (`--unlink-source`). The chart runs each pass from a shell loop, then sleeps for the full
  configured interval. That stage has no `--loop` argument. The upload
  command uses different timing; see the 0.20.0 loop note below. A pass that
  fails stops the container, as an exception out of `--loop` did. A stop
  (SIGTERM) ends the loop at once in the sleep. In a pass, it ends the loop
  when the pass ends: the pass is not stopped during a write, and no pass
  starts from the sleep after the SIGTERM. A stop that comes while the stage
  waits for its lock (for example while the uploader copies a session) runs
  that one pass first. A pass that is longer than the grace period (30 s)
  still gets SIGKILL.

### s3-uploader pod (edge)
- **The same pipeline PVC**: reads the terminal tree (`deidentified/` under
  the default `deid.engine: ingest`, `packaged/` when the package stage is
  on, `assigned/` under the deprecated `orthanc` engine) and copies each settled
  session, inside the upload-tree writer lock. It never removes a session:
  the staged-reclaimer CronJob does that, after it has proved each file in
  the bucket (see "S3 mode: prove, then delete" below). Its state
  (fingerprints, repair requests) lives under `/data/LOGS/s3-uploader-state/`
- **Outbound HTTPS to SeaweedFS** — the `https://seaweedfs.<domain>`
  Ingress on the management node, not the in-cluster Service; it
  therefore needs the CA bundle (`ca-bundle` Secret, key `ca.crt`,
  delivered by the cert-sync CronJob) as `RCLONE_CA_CERT`
- **One Secret** — `s3-edge-credentials` (`upload.s3.existingSecret`),
  keys `access-key` / `secret-key`, scoped to this site's own bucket

### upload pod (mgmt)
- **In-cluster S3** —
  `http://mgmt-seaweedfs.ais-mgmt.svc.cluster.local:8333` via `boto3`
  honouring the `AWS_ENDPOINT_URL` env var. The address is **derived
  from the release name**, not hardcoded (`mgmt.s3InternalEndpoint` in
  `charts/mgmt/templates/_helpers.tpl`) — the imperative manifest's
  literal `seaweedfs.seaweedfs` broke the moment the release was not
  named `seaweedfs`. Plain http on purpose: the default single-node management topology keeps it local. A future
  multi-node placement can carry this HTTP traffic across nodes. ClusterIP
  DNS does not encrypt traffic or enforce a network boundary
- **Outbound HTTPS** to the configured XNAT server
- **Two Secrets:**
  - `xnat-credentials` (`xnatUpload.xnatSecretRef`) — server URL,
    username, password
  - `seaweedfs-upload` (`xnatUpload.s3SecretRef`, overridable per site
    with `edges[].uploadSecretRef`) — S3 access key/secret. **Not the
    admin identity:** the matching `upload-<edge>` S3 identity is scoped
    to `Read`/`List`/`Write`/`Tagging` on that one edge's bucket
    (`charts/mgmt/templates/seaweedfs.yaml`), so a leaked uploader key
    cannot reach another site's bucket through that identity. The separate
    management reclaimer uses the same scoped identity for deletion after
    XNAT proof; the upload command itself does not delete S3 staging.
    SeaweedFS includes object DELETE in `Write`

The management chart passes S3 credentials with `ACFLOW_STORE_CREDENTIALS`.
The CLI also accepts the two values after `--store-credentials`; these are
alternative inputs to the same store-credentials option. XNAT credentials use
`ACFLOW_HOST`, `ACFLOW_USER` and `ACFLOW_PASS`. S3 endpoint configuration remains
`AWS_ENDPOINT_URL`. Keep credentials in the existing Secrets, not in commands
recorded in a shell history.

## Where it runs

| Pod | Cluster | Namespace | Image |
|---|---|---|---|
| `edge-group-orthanc` | edge | `xnat-ingest` | `ghcr.io/australian-imaging-service/accessionflow:0.20.0` |
| `edge-assign` | edge | `xnat-ingest` | `ghcr.io/australian-imaging-service/accessionflow:0.20.0` |
| `edge-deidentify` | edge | `xnat-ingest` | `ghcr.io/australian-imaging-service/accessionflow:0.20.0` |
| `edge-s3-uploader` | edge | `xnat-ingest` | `ubuntu:noble-20260917` (`upload.s3.shell.image`, NOT accessionflow), with rclone lifted from `rclone/rclone:1.75.0` by an initContainer |
| `mgmt-upload-<edge>` | mgmt | `xnat-upload` | `ghcr.io/australian-imaging-service/accessionflow:0.20.0` |

Every name is **release-prefixed** by the chart's `fullname` helper, and
`install.sh` installs the edge chart as release `edge` and the management
chart as release `mgmt` — so the objects are `edge-assign` and
`mgmt-upload-<edge>`, not the bare `xnat-ingest-*` names the imperative
installer used. A site installed under a different release name shifts
them all.

The management uploader is **one Deployment per edge site**, not one for
the fleet. Correctness first: with one staging bucket per site, a single
uploader cannot serve them all, because `accessionflow store xnat` takes
exactly one `s3://bucket/prefix`. Reliability second: a fleet-wide
uploader means one site's poison session, stuck multipart or expired
credential stops delivery for *every* site, and the failures are
indistinguishable because they share one log stream. Per-site uploaders
give per-site isolation, per-site alerting via the `edge` label, and let
one site be paused without touching the others. Measured cost of a
single uploader in a historical run was 231Mi resident and 4m CPU
(measurement date not verified, reviewed 2026-11-10). The old estimate of
around 15 sites on a 16Gi node was not a tested ceiling. Measure concurrent
0.20.0 uploads, temporary storage, Orthanc load, and observability before
setting a site count or memory limit.

A site can also skip S3 entirely with `upload.mode: direct`, which
renders `edge-upload` (`accessionflow store xnat` straight from the edge to
XNAT) instead of `edge-s3-uploader` and needs no management plane, no S3
and no management-to-edge certificate plumbing. HTTPS to XNAT still needs
valid server trust; direct mode does not remove TLS verification requirements. The two modes are mutually exclusive and the chart
refuses to render both — enabling both would push every session into
XNAT twice.

The previous `0.16.2.post1` tag was a **fork build**, pulled from
`ghcr.io/akshitbeniwal/xnat-ingest`: upstream 0.16.2 plus the AIS changes
tracked in xnat-ingest PRs #210-#231. The charts now use the upstream
`ghcr.io/australian-imaging-service/accessionflow:0.20.0` image. The package
name and environment-variable prefix changed at 0.18.0, along with the
collate and label command names. Version 0.19.0 renamed upload to store.
The namespace, stage labels, storage paths and receipt labels did not change. The earlier AIS-Edge patch set (including the
`AIS_LOG_FORMAT=json` structured-log output and the `upload --loop` reconnect
fix) is upstream. There is no image-import step. Both charts set `imagePullPolicy: IfNotPresent`
(`ingest.image.pullPolicy` in `charts/edge/values.yaml`,
`xnatUpload.image.pullPolicy` in `charts/mgmt/values.yaml`), so each node
pulls the tag from ghcr.io the first time a pod lands on it and reuses
the cached layers afterwards. Nothing in `install.sh` or `scripts/`
side-loads the image into the container runtime. Override the tag via
`xnatUpload.image.tag` in `charts/mgmt/values.yaml` (mgmt side) or
`ingest.image.tag` in `charts/edge/values.yaml` (edge side).

## Configuration

Version 0.20.0 uses source subcommands: `collate orthanc` and
`collate folder`. The Orthanc command takes
`URL STORE_DIR OUTPUT_DIR USER PASSWORD`, the same five positional arguments as 0.19.0.
The file-drop options are `--accession-uid` and `--acquisition-id`,
with `ACFLOW_ACCESSION_UID` and `ACFLOW_ACQUISITION_ID`. For `label xnat`, the XNAT names `--session` and `--scan` remain unchanged.
The third deidentify argument is `RECIPE_DIR`. It accepts
`ACFLOW_RECIPE_DIR`; `ACFLOW_SPEC_DIR` remains a compatible alias.
The old `check-upload` command is now `check-store xnat`.

The Python model uses `Accession.acquisitions`, `Acquisition.accession`
and `Resource.acquisition`. XNAT still calls these sessions and scans.
The staging folders, namespace, receipt labels and chart stage names
keep their existing names. See the upstream
[migration guide](https://github.com/Australian-Imaging-Service/accessionflow/blob/b496af05/MIGRATING.md)
when adapting custom commands or Python scripts.

The chart keeps
its stage and Kubernetes names. `group-orthanc` runs `accessionflow
collate orthanc`; `group-fs` runs `accessionflow collate folder`; `assign` runs
`accessionflow label xnat`; `upload` runs `accessionflow store xnat`. The
legacy associate template would require `accessionflow attach`, but enabling
`ingest.associate.enabled` is rejected: the chart does not supply the required
inputs, matching rule, or output contract. The command change
does not rename any namespace, Orthanc label or storage folder.

| File | Purpose |
|---|---|
| `charts/mgmt/templates/xnat-upload.yaml` | one upload Deployment per `edges[]` entry, env vars, AIS_LOG_FORMAT=json |
| `charts/edge/templates/ingest-pipeline.yaml` | group-orthanc, assign, deidentify and package Deployments, hostAliases |
| `charts/edge/templates/upload.yaml` | the edge uploader — `edge-s3-uploader` (mode `s3`) or `edge-upload` (mode `direct`); exactly one renders |
| `charts/edge/files/s3-uploader.sh` | the `rclone copy` loop itself (copy only, under the writer lock, with the repair-request claim), plus the `jlog()` event schema below. A real file, not inline YAML, so `bash -n` can lint it in CI |
| `install.sh` | installs both charts; cert-sync (CronJob) pushes the CA bundle into each edge |
| `sites/<site>/secrets.enc.yaml` (`xnat-credentials`) | server URL, username, password — SOPS-encrypted |
| `sites/<edge>/values.yaml` (`ingest:`) | per-edge loop intervals, the de-identification recipe (`ingest.deidentify.specs`) and the tags that give the XNAT labels (`ingest.assign.tagMapping`) |

Important env vars on each pod:
- `AIS_LOG_FORMAT=json` — enable JSON structured log output (now
  upstream; drops to text format if unset)
- `AWS_ENDPOINT_URL` (upload pod only) — points boto3 at SeaweedFS
- `ACFLOW_HOST/USER/PASS`; XNAT REST credentials

### Ingest stage CPU and memory

Each ingest stage has default Kubernetes `resources` in `charts/edge/values.yaml`.
Change them in the site's values file. The keys are independent, including the
two group inputs:

| Values key | Container | Default requests | Default memory limit |
|---|---|---|---|
| `ingest.orthancGroup.resources` | `group` in the group-orthanc Deployment | CPU `100m`, memory `256Mi` | `2Gi` |
| `ingest.fileDrop.resources` | `group-fs` in the optional file-drop Deployment | CPU `100m`, memory `256Mi` | `2Gi` |
| `ingest.assign.resources` | `assign` | CPU `100m`, memory `256Mi` | `2Gi` |
| `ingest.deidentify.resources` | `deidentify`, when `deid.engine=ingest` | CPU `100m`, memory `512Mi` | none, on purpose (see "What the memory use grows with") |

No default sets a CPU limit. A CPU limit throttles a stage and slows the
pipeline. The CPU request is the share of the CPU that the stage gets when the
node is busy. The requests also take the stages out of the `BestEffort` QoS
class. The kubelet evicts `BestEffort` pods first, and the kernel stops them
first when the node runs out of memory: their `oom_score_adj` is 1000, and
Orthanc's is about 936 (measured on the test edge, 2026-11-10).

#### A site setting and the defaults

Helm merges these maps with the defaults. A key that the site sets replaces
only that key, and the other defaults stay. `null` on a key removes that
default. `resources: null` removes all the defaults of the stage. A namespace
LimitRange can still apply its own defaults to a container that has no
resources.

```yaml
ingest:
  assign:
    resources:
      limits:
        memory: 4Gi        # replaces only the default memory limit
  deidentify:
    resources:
      limits:
        memory: 6Gi        # adds a limit; size it as in "What the memory use grows with"
  orthancGroup:
    resources:
      limits:
        memory: null       # removes the default memory limit; the requests stay
```

Use the other keys to size the other stages separately. Keep uploader settings
under `upload.direct.resources` or, on main in S3 mode, `upload.s3.resources`.
Orthanc remains the DICOM receiver, with its own `orthanc.resources`. Size the
`deidentify` stage for the accessionflow recipes used at the site.

#### How the defaults were sized

Measured on 2026-11-10 with accessionflow 0.19.0 on the tier-2 test edge (4
vCPU, 8 GiB). Version 0.20.0 ships the same deid 0.4.13. One synthetic MR study
went through the real stages: 12,098 instances, 0.92 GB, in four series (10,000
slices of 128 x 128, 2,000 of 256 x 256, 95 of 1280 x 1280, and 3 localizers).
The memory of each container cgroup was read once a second. `anon` is the memory
that the kernel cannot drop; the working set adds the page cache that is in use.
The file-drop stage is off on the test edge, so it ran on the same files in a
container with 4 CPUs.

| Stage | Peak anon | Peak working set | Time for the study | CPU while busy |
|---|---|---|---|---|
| group-orthanc | 201 MiB | 454 MiB | 2 min | 0.9 core (peak 2.2) |
| file-drop group | 340 MiB | 368 MiB | 10 min | 1.0 core |
| assign | 310 MiB | 344 MiB | 12 min | 0.9 core (peak 2.5) |
| deidentify | 1,596 MiB | 2,558 MiB | 16 min | 1.0 core (peak 2.6) |

Each pass of a stage starts a new process. A pass with no work uses about
100 MiB. Orthanc's cgroup memory reached its `2Gi` limit with page cache; its
working set was 1,315 MiB and its anon memory 528 MiB. The s3-uploader stayed
under 100 MiB and sent the session (915 MB, 12,111 files) in 126 seconds.

A large study holds a stage for minutes. assign and the file-drop group read
every header, on one core. Other sessions wait for the end of that pass.

#### What the memory use grows with

- `group-orthanc`: the instances of a study. It hard-links the files from
  Orthanc's storage and does not read them.
- File-drop `group`: all the files of one pass. It reads every header before it
  groups them. One session of 3,000 files: 200 MiB. Four sessions of 3,000 files
  in one pass: 319 MiB.
- `assign`: the instances of the largest session. It does not keep the earlier
  sessions of a pass. One session of 3,000 instances: 192 MiB. Four in one pass:
  215 MiB.
- `deidentify`: the bytes of the sessions in one pass. deid 0.4.13, which
  accessionflow 0.19.0 and 0.20.0 use, keeps every file that it parses in memory until the
  process ends: an unbounded cache in `deid/dicom/fields.py`
  ([pydicom/deid#301](https://github.com/pydicom/deid/issues/301)). The memory is
  about 200 MiB + 1.0 to 1.6 times the size of the files; small files cost more
  per byte. One session of 95 files of 3.1 MB (295 MB): 482 MiB. One of 380 such
  files (1.25 GB): 1,386 MiB. Four sessions of 95 files in one pass: about
  1,390 MiB. The number of CPUs changes little: 12 threads instead of 5 added
  24 MiB. A fix is on deid's main branch
  ([pydicom/deid#307](https://github.com/pydicom/deid/pull/307)), not in a release
  (checked 2026-11-10).

So the default memory limits of the group and assign stages are 6 to 10 times
the measured peaks. deidentify has no default limit: a fixed limit stops every
session that needs more, on every pass. Without a limit, the kubelet and the
kernel still stop `deidentify` before Orthanc when the node runs out of memory,
because it uses the most memory above its request. If the node runs other work
and you want a limit, set `limits.memory` to at least 200 MiB + 1.6 times the
size of the largest session that you expect. A pass that runs out of memory
keeps the sessions that it finished (see the next section), so the limit must
cover the largest session, not the whole backlog.

#### When a stage reaches its memory limit

The kernel stops the whole container (`OOMKilled`, the container cgroup has
`memory.oom.group` 1), and Kubernetes starts it again. When the stops repeat,
the pod goes to `CrashLoopBackOff`. What we saw when we replayed it on
2026-11-10, with the chart's arguments and limits that were too low on purpose:

- A stage builds each session in `__build__` and moves it out only when it is
  complete. A stopped pass leaves at most a part in `__build__`, and no
  half-written session reaches the next stage. The next pass does that session
  again and leaves no part behind (checked for the file-drop group and for
  deidentify).
- The sessions that a pass finished before it stopped stay done. A backlog of
  three sessions under a deidentify limit that was too low finished in three
  passes, with every file once.
- A session that needs more than the limit stops the stage on every pass and
  stays in its input folder (`assigned/` for deidentify). Nothing moves until the
  limit is raised. The next pass then finishes it.

How to see it:

```bash
kubectl -n xnat-ingest get pods                  # RESTARTS goes up on the stage pod
kubectl -n xnat-ingest describe pod <stage-pod>  # Last State: Terminated, Reason: OOMKilled
```

On tier-2, no alert names a restart or an OOM kill of an edge stage: the
management Prometheus cannot read edge pods (see
[alerting-architecture.md](../alerting-architecture.md)). The session waits, and
`StageBacklogAgeing` fires when the oldest entry of the stage is older than
`dataPolicy.stageAgeAlertAfter` in the management chart (`7d` by default). After an unusually
large study, check the stage pods.

To recover, raise `limits.memory` for that stage in the site file and upgrade
the release. The next pass takes the waiting session.

Before setting a production profile, measure CPU and memory with the largest
supported studies, the site's recipes, and concurrent stages. Allow memory
headroom above observed peaks and check the total requests against node
allocatable capacity, including Orthanc and the other services. Short synthetic
runs and idle snapshots do not establish a safe upper bound. Verify throughput,
restarts, and recovery on the test deployment before applying a site profile.

### s3-uploader event schema

Every state change in the upload loop emits one JSON line via the
`jlog()` shell helper in `charts/edge/files/s3-uploader.sh`. The
shape is fixed and is what every Grafana panel + Loki ruler alert reads:

```jsonc
{
  "ts":         "2026-05-14T07:16:50+00:00",
  "component":  "s3-uploader",
  "edge":       "edge-dev",            // EDGE_NAME from clusterLabel; Vector sets its own stream cluster label
  "event":      "upload_completed",    // one of fourteen; full list below
  "session":    "test-project.subject01.visit01",  // PROJECT.SUBJECT.VISIT
  "message":    "",                    // free-form; empty for the routine events
  "bytes":       538740,               // total session size on disk (du -sb)
  "files":       2,                    // every object uploaded: DICOMs + __MANIFEST__.json + __METADATA__.json
  "dicoms":      1,                    // subset of `files` matching *.dcm / *.DCM
  "duration_s":  0                     // `rclone copy` wall time, present on upload_completed and upload_failed
}
```

The fourteen event names, and what each one means:

| Event | Emitted when |
|---|---|
| `dependency_missing` | before anything else: a tool the loop needs is not in the image, or is a busybox variant without the options the loop uses (`find -xtype`, `stat -c`, `du -sb`, `flock -w -E`; each is checked by use, not by name). Names the tool, carries "refusing to start upload loop", and exits 1 |
| `startup` | the loop starts; records endpoint, bucket, prefix, part size and client-certificate state, and says that it copies only |
| `endpoint_ready` | `rclone lsd sw:<bucket>` succeeded with this site's credentials |
| `endpoint_retrying` | probe failed; retrying up to 12 attempts, with 5s sleeps between failures; request duration adds to elapsed time |
| `endpoint_failed` | probe failed 12 times — refuses to enter the upload loop. Message also reports whether a client certificate is configured and readable: with mTLS on the S3 path this probe is what a bad or missing one breaks first, and (measured) the rejection arrives as an HTTP 400/403 that rclone reports as an S3 XML parse failure |
| `upload_started` | a settled session, changed since its last copy or named by a repair request, is about to be copied |
| `upload_completed` | `rclone copy` exited zero; the state file records the fingerprint, and a claimed repair request is removed (`recopy_done` follows) |
| `upload_failed` | `rclone copy` exited non-zero; retried next cycle (a claimed repair request goes back to pending) |
| `upload_skipped` | dangling symlinks, the endpoint went away mid-loop, or the upload-tree writer lock was not free within `upload.s3.lockWait` seconds (a timeout, `flock -E 3`) — the local copy is deliberately preserved rather than uploaded incomplete |
| `lock_failed` | the writer lock could not be opened, or `flock` failed with an exit that is not the timeout (127 with no `flock` in the image, a bad descriptor): never read as contention. A claimed repair request goes back to pending and the loop exits 1, so the pod restarts |
| `recopy_requeued` | at startup, a repair request claimed by a previous container (`.claimed`) is returned to pending, so a crash mid-copy loses no request |
| `recopy_claimed` | a repair request for this session was claimed (renamed to `.claimed`) and the copy runs with `--ignore-times`, so files that look unchanged are sent again; a request whose copy never completes is claimed again on every pass |
| `recopy_done` | the copy that answered a repair request exited zero; the request is gone. `RecopyLoop` counts these: more than three for one session in 24 hours is the two clocks crossing |
| `marker_retired` | a state file whose session no longer exists in any stage directory was dropped, so a later session of the same name cannot inherit its fingerprint |

`reclaim_skipped` no longer exists: the uploader has no delete to skip. A
dashboard or alert that selected it sees an empty series, not an error.

Only **`upload_started`, `upload_completed`, `upload_failed`, `recopy_done`,
`dependency_missing` and `lock_failed`** are matched by Loki ruler alerts
(`SessionUploadStalled`, `XNATUploadFailingForAllSessions`,
`S3UploaderRetryStorm`, `RecopyLoop`, `S3UploaderRestartedRecently`; the last
also matches the phrase "refusing to start upload loop" in `endpoint_failed`
and `dependency_missing`). Renaming one of those disables
its alert *silently* — no error, just a rule that never fires again.
The three `endpoint_*` events are operator diagnostics; they were called
`alias_configured` / `alias_retrying` / `alias_failed` under the old
`minio/mc` implementation, and were renamed because "alias" is an `mc`
concept of that historical client. The replacement was AWS CLI and is now
rclone (migration history, October 2026). Nothing
matched the old names, which is what made that rename safe.

An already-uploaded, unchanged session emits **nothing at all**. The
uploader fingerprints each session directory and compares it against a
state file under `/data/LOGS/s3-uploader-state/`. This fingerprint hashes
relative filenames, sizes, and integer mtimes, not content bytes. Historical
per-cycle events caused duplicate mail (incident date not verified, reviewed
2026-11-10); unchanged sessions now remain quiet unless recopy is requested.

The `dicoms` vs `files` split exists because accessionflow label xnat
auto-generates a `__MANIFEST__.json` per RESOURCE (not per session) and the s3-uploader writes
it to S3 alongside the DICOMs. Dashboards / alerts that want a true
DICOM count must read `dicoms`; ones that want "local file count considered for upload" use `files` ; which counts DICOMs **plus**
`__MANIFEST__.json` **plus** `__METADATA__.json`, not just DICOMs and a
manifest. `files` is not an actual PUT count: rclone can skip unchanged
objects, and multipart uploads make multiple requests. Both are computed in
`charts/edge/files/s3-uploader.sh`:

```bash
files=$(find -L "$session_dir" -type f | wc -l)
dicoms=$(find -L "$session_dir" -type f \( -iname '*.dcm' \) | wc -l)
```

`-L` because the session tree is hardlinks and symlinks into
`orthanc-storage/`, and `-iname` because scanners emit both `.dcm` and
`.DCM`. The `du -a | case`-pattern trick that used to be documented here
was a workaround for `minio/mc`, whose busybox base had no
`find`/`awk`/`grep`/`sed` at all; it went away with the client, since the
shell image the loop runs in (`upload.s3.shell.image`, a pinned Ubuntu) ships
full findutils, GNU coreutils and util-linux `flock`. The loop checks each of
them by use at startup and stops the pod with the tool named
(`dependency_missing`): `amazon/aws-cli`, the image it ran in before, had
every GNU tool and no `flock`, and every copy was skipped as lock contention
for five hours before anyone saw it (2026-10-14).

## Operations

```bash
# Edge staging logs (JSON if AIS_LOG_FORMAT=json is set)
KUBECONFIG=kubeconfig-edge-dev kubectl logs -n xnat-ingest \
  -l component=group -f | jq    # group-orthanc
KUBECONFIG=kubeconfig-edge-dev kubectl logs -n xnat-ingest \
  -l component=assign -f | jq   # assign

# Edge S3 uploader (rclone, not accessionflow; one JSON line per event)
KUBECONFIG=kubeconfig-edge-dev kubectl logs -n xnat-ingest \
  -l component=s3-uploader -f | jq

# Upload logs. There is one uploader PER EDGE, so narrow by the `edge`
# label unless you actually want every site interleaved.
kubectl logs -n xnat-upload -l component=upload,edge=edge-dev -f | jq

# Drop a test DICOM on edge (the optional `group (fs)` source watches
# /data/incoming; the normal path is a C-STORE into Orthanc)
ssh ubuntu@<edge-ip> "cp /home/ubuntu/MRBRAIN.DCM /data/xnat-ingest/incoming/"

# Promote an invalid session: follow the guarded steps in "Recovering an
# invalid session" below. On the host these live under the pipeline
# volume's hostPath, /data/xnat-ingest, which the pods see as /data, so
# /data/assigned is /data/xnat-ingest/assigned. A plain mv into an
# existing folder nests the session instead of promoting it.
```

`__invalid__` is one of the reserved directory names the s3-uploader
skips (alongside `__build__` and `__metadata__`), so a session sitting
there is never uploaded — that is what makes the rename a promotion.

### Holding folders

Two folders on the edge node hold data that a stage could not pass on. No
stage, reclaimer or data policy removes either of them.

| Folder | What puts data there | What to do |
|---|---|---|
| `/facility-backup/__unmapped_aet__/<AET>/`, the quarantine | Only the deprecated Lua engine (`deid.engine: orthanc`), for a study sent to an AE title that `aetMap` does not map. Under `ingest` nothing writes here | Add the AE title to `aetMap` |
| `/data/assigned/__invalid__/`, the invalid sessions | `assign`, when it cannot resolve the project, subject or session ID | Follow [Recovering an invalid session](../recovering-invalid-sessions.md) |

### A study that group-orthanc refuses

`group-orthanc` stages each study on its own. When it cannot stage a study, it
logs this line at ERROR, removes the study's scratch folders, and stages the
other studies:

```
Skipping Orthanc study '<orthanc-study-id>': <reason>
```

`IngestStageError` fires. The study stays in Orthanc without the processed
label, and the stage tries it again on every pass. The data policy does not
remove a study without the processed label, so the study waits in Orthanc.

Read the reason first. The stage refuses a study when two of its series would
share one scan:

- `SeriesNumber '<n>' is used by series with different descriptions`
- `series '<id>' maps to '<scan>/<resource>' like another series of the study`

The scan ID comes from the SeriesNumber, so the stage cannot keep both series
in one session. It refuses the study, so that no series is merged or dropped.
To clear it, from the management host:

1. List the series of the study with their number, description and count of
   instances. The Orthanc container has no `curl`, so use a port-forward in a
   second terminal. Wait for `Forwarding from 127.0.0.1:8042`, and stop it with
   Ctrl-C when you are done. Leave out `-u` if Orthanc authentication is off.

   ```bash
   # second terminal
   KUBECONFIG=kubeconfig-<edge> kubectl -n xnat-ingest port-forward deploy/<release>-orthanc 8042:8042
   ```

   ```bash
   curl -sf -u <orthanc-user>:<password> \
       "http://localhost:8042/studies/<orthanc-study-id>/series?expand" \
     | jq -r '.[] | [.ID, .MainDicomTags.SeriesNumber,
                     .MainDicomTags.SeriesDescription, (.Instances | length)] | @tsv'
   ```

2. With the site's imaging team, decide which series to keep.
3. If one series is not necessary, save a copy of it and check the copy:

   ```bash
   curl -sf -u <orthanc-user>:<password> -o <orthanc-series-id>.zip \
       http://localhost:8042/series/<orthanc-series-id>/archive
   unzip -tq <orthanc-series-id>.zip                  # must report no errors
   unzip -Z1 <orthanc-series-id>.zip | grep -vc '/$'  # must equal the count in step 1
   ```

   Do not go on unless the download, the test and the count are all correct.
   Do not rely on the facility backup instead: some sites turn it off, and the
   configuration does not prove that it holds this series.
4. Delete only that series. The next pass stages the study.

   ```bash
   curl -sf -u <orthanc-user>:<password> -X DELETE \
       http://localhost:8042/series/<orthanc-series-id>
   ```

   The deleted series does not go to XNAT. Keep its ZIP file as the site's
   retention rules say.

5. If both series are necessary, keep the study in Orthanc and report it to the
   AIS team. The stage cannot stage two different series under one scan number.

Do not delete the whole study from Orthanc. That removes every series of the
study and, on a site without the facility backup, the only copy.

Other reasons name their cause, for example a file that cannot be read or a
conversion that failed. Correct the cause. The stage tries the study again on
the next pass.

### Recovering an invalid session

`assign` puts a session in `/data/assigned/__invalid__/` on the edge when it
cannot resolve the project, subject or session ID from the tags. It logs this
line at ERROR:

```
Could not resolve the labels of '<name>', due to missing metadata fields [...]. Saved to '/data/assigned/__invalid__/<folder>' for manual review instead
```

`InvalidSessionAssigned` fires when assign reports such a line. It counts
reports per cluster, not sessions, and it clears when the line leaves its
10-minute window, which does not mean that the session was recovered. The line
is logged before the session is saved, so check that the folder exists.

The folder name shows which IDs are missing. Each one is
`INVALID_MISSING_<FIELD>_<suffix>`, for example
`<project>.<subject>.INVALID_MISSING_ACCESSIONNUMBER_<suffix>`.

What happens to the copies:

- `assign` removes its input from `/data/grouped/` after it saves the session
  in `__invalid__/` (`dataPolicy.derived.grouped.reclaim: onAssigned`).
- Nothing removes `__invalid__/`: not the stages, not the reclaimers, not the
  data policy. The s3-uploader skips it, so the session does not reach the
  bucket.
- The study stays in Orthanc with the processed label. When the data policy is
  armed, it can delete that Orthanc copy after
  `dataPolicy.derived.orthancStorage.minAge`. If the facility backup is on, it
  also keeps the original of each instance that came in by DICOM. It does not
  keep an instance that came in another way, and a write can fail (the Orthanc
  log then says `ABORT: facility backup write failed`). **Keep the facility
  backup on.** Even with it, the folder in `__invalid__/` can be the only copy.
- If the same study is staged again (for example, a late series), `assign`
  skips it and logs `already saved as invalid` at WARNING, until the folder
  leaves `__invalid__/`. The skipped copy stays in `/data/grouped/`: `assign`
  does not remove it, so it does not clear by itself. Do not remove it. See
  [More data for the same study](../recovering-invalid-sessions.md#more-data-for-the-same-study).

To recover the session, follow
[Recovering an invalid session](../recovering-invalid-sessions.md). In short:
the operator runs `sudo ais-requeue list` and `sudo ais-requeue show <folder>`
on the edge node. A person with the hospital's records finds the missing value.
The operator runs `sudo ais-requeue requeue <folder> --session <value>`. That
page also gives the methods without full sudo (a sudo rule for this command
only, kubectl from the management node), the repository script, the manual
fallback, what the tool refuses, and its exit codes.

The chart ships the tool into the label (`assign`) pod: the ConfigMap
`<release>-requeue-tool`, from `charts/edge/files/requeue-invalid.py`, mounted
read-only at `/opt/ais-edge`. The accessionflow image does not change.

Do not send the study again to correct it. Orthanc keeps the instances that it
already has, and it ignores a copy with the same SOPInstanceUID.

### S3 mode: prove, then delete

Under `upload.mode: s3` the edge keeps its copy of a session until the
staged-reclaimer has proved the bucket's copy against it. The staged-reclaimer does not use rclone's exit code as deletion proof.
The data-policy engine has separate marker-based decisions; do not generalize
this proof to every retained copy. Historically, the delete that cleared `/data/assigned` after a
zero exit, which is what the uploader did before, removed the only copy on
the strength of that code.

**The uploader copies only.** `s3-uploader.sh` takes the upload-tree writer
lock (`/data/.locks/<tree>.lock`, the one `assign` or `deidentify` holds for
each pass) for each `rclone copy`, with `--s3-chunk-size upload.s3.chunkSize`
and `--s3-use-multipart-etag=true`, and releases it when the copy ends. It
waits `upload.s3.lockWait` seconds for the lock and then skips the session for
that pass (`upload_skipped`). Only a timeout is contention: `flock -E 3` names
it, and any other failure to open or take the lock stops the loop
(`lock_failed`, exit 1), so a pod that cannot lock restarts and
`S3UploaderRestartedRecently` names it, instead of skipping every session for
ever. The loop also checks each tool it needs by use before its first session
(`dependency_missing`, see "Where it runs"). It has no `RECLAIM` or `DRY_RUN`
variable any more.

**The CronJob proves each file against the bucket** (`PROOF=s3`). It lists
`staged/<session>/` once, then for each local file reads the file, computes
the MD5 of the bytes and the multipart forms of it for `upload.s3.chunkSize`
and for rclone's 5 MiB default, and compares size and ETag with the listing.
It records the file's identity (inode, size, mtime, ctime) before and after
the hash, so a file that changes during the check is kept. A proved resource
is removed inside the writer lock, one resource at a time; the session's own
sidecars go last. The parent sidecars (the session's `__METADATA__.json` and
each scan folder's) are proven in the bucket like any file, and their
identities, taken at the snapshot, are required again inside the lock before
any data goes and before each is unlinked: a sidecar rewritten or added after
the proof keeps the session (`changed_during_check`). The one folder tidied
without that bind is a session that held no data file at all at the start of
the run, whose leftover sidecars describe nothing. The age has two clocks on
the edge: the newest local file (its ctime) and the newest object of the
session in the bucket (its `LastModified`) must both be older than
`stagedReclaimer.minAge`, so a backlog of old files copied today still waits
its window (`reclaim_skipped` names which clock). XNAT is never asked.

**A failed proof leaves a repair request.** A file that is not in the bucket,
or is there with another size or ETag, keeps its session and writes
`<uploader state dir>/recopy/<session>` (once per run, never in a dry run).
The uploader claims the request by renaming it to `.claimed`, copies the
session with `--ignore-times`, and removes the claim when the copy exits zero
(`recopy_claimed`, `recopy_done`); a failed copy returns the request to
pending, and a container that starts with a `.claimed` left by its
predecessor requeues it (`recopy_requeued`). An ETag in a multipart layout the
proof cannot compute (`unknown_layout`) keeps the session without a request:
copying again would not change it, and an operator has to look.

**The two clocks.** The management reclaimer removes the bucket copy after
XNAT holds every file and `dataPolicy.derived.s3Staged.minAge`; the edge
removes its copy after `dataPolicy.derived.stagedReclaimer.minAge`. The first
must be the longer, by more than the edge's run interval, its proof time, its
lock wait and any edge downtime. If the bucket copy went first, the edge's
proof would fail and request a copy, the uploader would copy, management
would remove again, and so on: nothing is lost while that loops (both copies
are kept until proved, and XNAT already holds the session), but the edge
never retires its copy. `RecopyLoop` fires on more than three completed
re-copies (`recopy_done`) of one session in 24 hours; claimed requests are
not counted, because an uploader that cannot copy claims the same request on
every pass (measured on 2026-10-14: 21 sessions, five hours, nothing copied),
and that failure has its own alerts. Neither chart can read the other's value, so the
defaults are 36 hours against a day. The longer clock has a ceiling too: the
management reclaimer proves a session in XNAT only after `s3Staged.minAge`,
and `SessionStagedNotConfirmedInXNAT` counts a session unconfirmed 48 hours
after the reclaimer first logged it, so a minAge of two days or more would
page for every healthy session; the management chart refuses more than 36h.

What the reclaimer logs, per session: `reclaim_confirmed` ("the bucket holds
each of the N file(s) ... (ETag) and its size"), `reclaim_resource_removed`,
`reclaim_removed`, or `reclaim_kept` with a reason (`not_in_s3`,
`s3_mismatch`, `changed_during_check`, `unknown_layout`, `listing_failed`) and
`recopy_requested` when it wrote a request. Every line carries `proof` (`s3`
here, `xnat` on the management side and under `direct`), and the CronJob's
pods carry `component: s3-reclaimer`, so the lines reach Loki under that
label: `SessionStagedNotConfirmedInXNAT` counts only an XNAT proof as
delivery, and `ReclaimerRunUnavailable` judges the edge's reclaimer apart
from the management one.

### Stopping stage loops

The chart runs group, group-orthanc and assign through the same pass wrapper
as the other producers. Each pass holds the lock of its output tree. Group and
group-orthanc share `grouped.lock`; assign holds `assigned.lock`. These locks
stop two writers of the same tree. They do not make the full pipeline a
transaction.

TERM and INT stop an idle wrapper at once. A busy wrapper lets the current
pass finish, releases its lock, and starts no further pass. A pass that lasts
longer than the pod termination grace period can still be killed.

During a `helm upgrade`, the `Recreate` strategy stops the old pod before the
new pod starts. A pod deletion or an eviction does not wait: the replacement
can start while the old pod still stops. The lock covers that case. On the
first upgrade to this chart the old pod has no lock, but `Recreate` stops it
first, so the upgrade itself is safe. An old pod that ignores TERM is killed
after the grace period, possibly during a pass, as before this change.

Each pass starts a new `accessionflow` process. A historical fork measurement recorded about 1.6 s of
CPU per pass (measurement date not verified, reviewed 2026-11-10). Startup
cost for the current 0.20.0 image and each site workload was not benchmarked
in this review; do not use that old number as a capacity guarantee. A new process for each pass also returns its memory after the pass.

The data-policy loop also stops from idle sleep and after a current foreground
command. An external child that does not finish within the grace period can
still be killed.

The S3 uploader uses the same sleep handling. Its current copy can finish
before the shell exits. If a repair claim remains when it exits between
commands, the existing startup recovery returns that claim to the queue.

### Upgrade or roll back while the cleanup can delete

This applies to both upload modes: the staged-reclaimer deletes from the
edge's upload tree under `direct` (proof: XNAT) and under `s3` (proof: the
bucket). Under `s3` the first upgrade to the release that adds the CronJob
needs no drain: the deleter before it was the s3-uploader itself, a
Deployment that Recreate stops before the new one starts, and there is no
earlier cleanup Job to wait for. The rollback rule below applies in both
modes.

The staged-reclaimer deletes only inside the upload-tree writer lock, and only
while a writer that takes the lock is running (it holds `<tree>.alive`). That
check is safe for an upgrade, because Recreate stops the old writer before the
new one starts. Two moves need a drain first, on a site where
`dataPolicy.enabled: true` and `dataPolicy.dryRun: false`:

- the FIRST upgrade to a release in which the staged-reclaimer takes the lock.
  Before it, the cleanup ran `rm -rf` without the lock, and a Job that has
  started keeps its old behaviour after its CronJob changes. That includes the
  release that added only the writer lock: its deleter does not take the lock;
- a rollback to a release in which the writer or the deleter does not take the
  lock. This rollback is not supported without the drain, and the cleanup then
  stays suspended.

`suspend` does not stop a Job that has started. `scripts/reclaimer-fence.sh`
waits for it, and fails on any API error instead of reading it as "nothing
runs". Give it the upgrade or rollback command:

```bash
scripts/reclaimer-fence.sh around <release> -- \
    helm upgrade <release> charts/edge -n xnat-ingest -f sites/<site>/values.yaml
```

It suspends the CronJob and waits until no cleanup Job or pod is active (also a
pod whose Job is already deleted), runs the command, and resumes only if the
command succeeded and the checks below pass. At the first failure it stops,
exits non-zero, and the CronJob stays suspended. Do not run the steps as
separate shell lines: a failed step does not stop the next one. (`drain` and
`resume` exist on their own for an operator who checks each exit status.)

The resume step refuses, and leaves the CronJob suspended, when the CronJob's
deleter has no `WRITER_LOCK`/`WRITER_ALIVE`, when the writer's rollout is not
complete, or when any writer pod (`assign`, `deidentify` or `package`, from the
lock path: `packaged.lock` means the `package` writer) lacks the wrapper or is
still terminating. An upgrade or a rollback between two releases in which BOTH
the writer and the staged-reclaimer take the lock needs no drain. Turning the
package stage on or off moves the writer lock between `deidentified.lock` and
`packaged.lock`; the stages themselves order that move (both hold
`deidentified.lock` for each pass, see the writer lock above), and the fence
follows the lock path for the reclaimer.

### Reidentification maps at production sites

The container reads `ACFLOW_REID_ENCRYPT_KEY`. The existing Secret still uses
the key `XINGEST_REID_ENCRYPT_KEY`; the chart maps that key to the new variable.
The old `XINGEST_*` environment-variable names are not supported aliases
in 0.20.0. This does not rename the compatible key inside the Secret.

The ingest deidentification engine writes maps under the pipeline `reid`
directory, normally `/data/xnat-ingest/reid` on the host. Without
`ingest.deidentify.reidEncryptKeySecret`, these maps are plaintext JSON.
Production sites that use this engine must set this Secret reference and
manage the key separately from the data. Restrict access to both the maps
and the key. The Secret must contain `XINGEST_REID_ENCRYPT_KEY`, a valid
Fernet key for the ingest command. Do not place the key in a values file.

Enabling encryption affects new writes. It does not encrypt or remove
existing `.json` maps. A later pass can leave both a plaintext map and an
encrypted `.json.enc` map. Inventory existing maps and arrange a verified
migration before claiming that the stored maps are encrypted. Routing labels
can still contain original identifiers; select approved pseudonymous tags
for the assign stage as described in the chart values.

There is no retention rule for this directory. A proposed rule would retain
each map until its delivery and retention obligations are met, then remove
it after a site-selected interval. The site must decide that interval, the
required restore window, backup handling, legal holds and key retention.
Use a dry-run inventory first. Do not enable automatic deletion until the
site approves those decisions and verifies that the required maps remain
recoverable. This proposal changes no retention behavior.

### Reclaimer connections and fresh evidence

The staged reclaimer starts one Python worker for its data pass. The worker
handles session names in sequence and keeps only the current session's file
listing and proof in memory. Startup probes remain separate from that pass.
It reuses connections, not response data. Each session gets a fresh listing
when it is examined; the run-start discovery contains names only.

For XNAT proof, the worker uses direct HTTP requests rather than xnatpy
object caches. It uses HTTP or HTTPS according to the configured server URL,
and sends `Cache-Control: no-cache`.
It queries the experiment endpoint before reading its file catalog and keeps
the per-file HEAD checks. A missing experiment, missing file, failed request,
invalid response or failed login keeps the affected data. If a login expires,
one bounded login retry precedes the request retry. The worker closes any
login it opens; the shell closes the initial login that it lends the worker.
The connection can stay open across sessions without retaining their listings.
On TERM, the shell forwards the signal to the worker and waits for its cleanup.
The worker closes a renewed login through a fresh connection, even if the
signal interrupted an HTTP response.

For S3 storage, the worker uses one client and lists each session prefix again
at its decision. Every object delete still uses the ETag from that fresh
listing as an `If-Match` condition. It does not delete a key that appeared
later. Discovery uses a recursive object listing and deduplicates session names
on disk. It examines only sessions containing objects; retained empty folders
and folder-marker keys add no per-session work. Folders stay in place because a
filer folder removal could race with a new upload. All discovery pages must
validate before any session is examined; discovery keys are never deletion proof.

The `empty` summary field remains for compatibility. In S3 mode it normally stays
zero; it counts only sessions that become empty between discovery and the fresh
per-session listing. Alert rules do not use that field.

These checks do not make XNAT and the source store one transaction. They
preserve the existing per-file evidence, local writer locks and conditional
deletes. A dry run makes the same checks and removes no data.

## Benefits

- **DICOM parsing already handles our edge cases** — (missing
  AccessionNumber, multi-frame, multi-series) that we don't want to
  re-implement
- **Idempotent**: a complete session is skipped with an explicit skip line
  in 0.20.0. The success line is gated on the upload verdict. See the
  historical measurements under "Known upstream defects" before comparing
  old alert behavior with a current deployment.
- **Loop mode with label tracking** — group-orthanc marks each pulled
  study `xnat-ingest-processed` and records a source snapshot. An unchanged
  study can be skipped; later instances or changed source state can cause
  regrouping. The label alone is not an exactly-once delivery guarantee
- **Connection-resilience patch** (merged upstream) — handles
  transient network errors that previously killed the upload loop

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| DICOM missing AccessionNumber | If the site maps that missing tag to a required label, `assign` saves the session in `/data/assigned/__invalid__/` | Use the procedure in "Recovering an invalid session" and verify the missing labels against the source records. `InvalidSessionAssigned` matches the pinned missing-ID diagnostic in a 10-minute window, with a one-minute pending period. The older `DICOMValidationFailureSpike` counts more than 10 lines matching `invalid` or `validation.*fail` in one hour, held for five minutes; the missing-ID error matches through `__invalid__` in its saved path, but other invalid warnings also count, so this is neither an exact missing-ID error count nor a distinct-session count. Both require a running Loki ruler and collected assign logs. |
| XNAT login fails | upload pod crashes immediately | check `xnat-credentials` Secret; Use an XNAT credential accepted by the password-based REST client; a browser-only AAF/OIDC login is not sufficient |
| XNAT down or uploader just slow | uploads queue in SeaweedFS; backlog grows | No dedicated backlog-rate alert today — see "Known upstream defects" below. `SessionStagedNotConfirmedInXNAT` (docs/alerting-architecture.md) still catches a session that never lands, just later (minAge + offset) |
| S3 endpoint unreachable from upload pod | uploads fail | Check Service endpoints, DNS, network policy, credentials, and SeaweedFS health. An in-cluster URL can fail even while the SeaweedFS pod is running |
| group/assign pod restarts | in-flight stage interrupted; resumes on next loop | The quiet-period check reduces incomplete input; snapshots detect changed studies. Late series and a process killed mid-pass still need retry and output validation |
| A writer pass stops or its pod is killed | the pass stops; its lock goes with it | The kernel releases a `flock` when the last process that holds it stops, so the next pass can take it. A child process that a pass leaves keeps the lock until that child stops |
| Node cannot reach ghcr.io (registry outage, air-gapped site) | New or rescheduled pods sit in `ImagePullBackOff`; already-running pods are unaffected | Both charts use `imagePullPolicy: IfNotPresent`, so a node that has already pulled `0.20.0` keeps starting pods with no registry at all. There is no image-import step in `install.sh`. An air-gapped site must seed the tag into each node's container runtime itself |
| Orthanc REST credentials drift from `users.json` | group-orthanc gets 401 on every poll; studies pile up in Orthanc with nothing failing downstream | All three keys live in one Secret (`orthanc-credentials`) so they are rotated together; the edge chart refuses to render with `orthanc.auth.enabled` and no Secret named |

## Known upstream defects (candidate reports)

**Historical record (measurement dates not verified; reviewed 2026-11-10):**
the measurements in this section describe older
xnat-ingest releases. The status notes below distinguish them from the
pinned accessionflow 0.20.0 behavior. Keep the measurements for incident
comparison; do not apply their old restart or alert advice without the status
notes.

The following three reports came from older test deployments. They describe
observed logging and cache behavior, not a guarantee that stale evidence was
harmless. Current fixes and remaining checksum limitations are stated next to
each record. Re-run an appropriate synthetic check before using an old
measurement to interpret a deployed site.



### 1. The success line is logged on the SKIP path

**Current status: fixed in the pinned image.** In 0.20.0,
`stores/xnat/api/store_api.py:272-277` logs
`Skipping upload of ... as all the resources already exist on XNAT` and
continues before the success line. The success line at line 682 is gated by
`msg is None`; it can also follow a successful repair. The following record
explains the older alert design, not current repeated skip behavior.

`Successfully uploaded all files in '<session>'` is emitted on **every** `--loop`
pass, including the passes where the uploader checks XNAT, finds the session
already present, and correctly skips the transfer.

Measured over 30 minutes on a single already-uploaded session:

```
30  "Successfully uploaded all files in 'test_project.65DDEFA8D833.8607324A38C9'"
14  "already exists"
14  "Skipping"
```

Emission gaps: `1, 61, 1, 62, 1, 61, ...` — two lines per loop, one loop every
~62s, continuing for as long as the session remains in S3 staging. With
retention disabled that is forever.

So the line is a **level, not an event**: it means "this session is in XNAT",
re-asserted indefinitely, not "this session was just uploaded".

**What it cost us.** An alert keyed on that string with a `[1m]` range against a
~62s emission period had its series go empty between passes, so it resolved and
re-fired every minute — one notification per loop, forever. Diagnosing it took
three wrong attempts. Our fix was to widen the range past the loop period
(`charts/mgmt/files/loki-ruler-rules.yaml`), which works but is a workaround for
a message that should not be there.

**Historical proposed fix (implemented by the current pin).** Emit a distinct message on the skip path ; e.g.
`Session '<session>' already in XNAT, skipping` — or drop the success line to
debug when nothing was transferred. Either makes the successful-upload line an
event again, which is what every consumer assumes it is.

**Historical backlog-alert consequence; old rule remains removed.** `XNATBacklogGrowing` tried to measure
"arriving in S3 faster than being pushed to XNAT" by subtracting a count of
this string from a count of edge `upload_completed` events. Because the
string is a level, its count grows with however many sessions are sitting in
static backlog, not with new arrivals in the window — so a genuine backlog
makes the subtraction more negative, not more positive, and the alert could
never fire in the direction it was meant to. Removed rather than shipped as
false coverage; a real version needs the fix above, or a distinct
"session confirmed in XNAT" event with no level-persistence problem.

### 2. The XNAT listing is cached for the lifetime of a `--loop` run

**Current status: fixed in the pinned image.** The 0.20.0 upload path clears
xnatpy caches before object operations (`stores/xnat/api/store_api.py:281`)
and uses fresh evidence for completion checks. The following account and
restart advice describe the old failure. A restart is not required merely
to make a current completion check see a deleted XNAT file.

The older `xnat-ingest upload --loop` opened one XNAT connection and xnatpy cached the
project/experiment listing on it. A connection opened while a session does not
yet exist keeps returning that stale view for the life of the process, so the
uploader cannot see its own writes.

It is a **state** bug, not a logic bug: restarting the pod clears it, and with a
fresh connection the deduplication is correct.

**Historical workaround, superseded in 0.19.0:** the old uploader needed a
restart after an administrator changed XNAT so it would discard cached state.
Do not delete XNAT data or restart a current uploader just to follow this old
workaround. The current path refreshes object evidence; investigate current
errors and identity conflicts before taking a corrective action.

**Historical proposed fix (implemented by the current pin).** Refresh the listing once per loop iteration, or
expose the cache TTL as a flag.

### 3. A benign checksum mismatch logs at ERROR, every loop, until XNAT catches up

**Status on 2026-10-20: fixed in 0.15.3.** Since 0.15.3, the upload compares a
file by name only when XNAT lists it without a digest. So the ERROR `... already
exists on XNAT with different checksums` now means a real difference. XNAT holds
a file that staging does not, or a file with other content.
`XNATResourceIncompleteAndStuck` alerts on it. In 0.16.2, and in the
then-pinned fork build 0.16.2.post1, the upload logged this ERROR and continued.
In 0.20.0 a failed session verdict suppresses the success line. A success line
still does not establish byte equality when XNAT supplies no checksums. The record below is the 0.15.0 measurement. Its statement
that no alert rule matches the phrase is out of date.

The opposite gap remains. When XNAT lists no digests (site checksums off, as on
the AIS test XNAT, or digests not computed yet), the upload compares file names
only. Upstream 0.16.2 logs this at DEBUG only. xnat-ingest PR #227 logs one
WARNING per resource and upload attempt. Upstream merged it on 2026-10-27, and
both the previous fork build 0.16.2.post1 and current 0.20.0 contain it. Content comparison needs
computed XNAT digests. A site administrator must configure checksums and
populate the catalogs. Do not treat a name-only check as proof of unchanged
bytes.

Measured with a synthetic drop (`scripts/site-secrets.sh` §"synthetic DICOM
drop" in `docs/TOUR.md`): for several minutes right after a session first
lands in XNAT, every `--loop` pass re-logs

```
ERROR "'DICOM' resource in '<session>' already exists on XNAT with different
checksums. Please delete on XNAT to overwrite: {'<file>.dcm': ('', '<md5>')}"
```

immediately followed by `INFO "Skipping ... resource as it is already
uploaded"` and `INFO "Successfully uploaded all files"` — so the pass still
ends in success. The left side of that tuple, `''`, is XNAT's own catalog
entry for the file's checksum; it is empty because XNAT has not finished
computing it yet, not because the bytes actually differ. A session running
for hours (`test_project.65DDEFA8D833.8607324A38C9`) shows zero occurrences
of this line — it stops once XNAT's own checksum catches up — but a
freshly-arrived session repeats it on every ~60s pass in the meantime.

**Historical monitoring gap, no longer current:** at the time no rule matched
log text or level for the
`xnat-upload` namespace (checked — `grep -i "checksum\|already exists"
charts/mgmt/files/loki-ruler-rules.yaml` returns nothing), so this currently
produces noise in `kubectl logs` and nothing else. It is the same trap as
defect 1 above, one severity level worse: an ERROR-labelled line that means
nothing is wrong, re-emitted every loop for as long as the session is
freshly staged. **If anyone ever adds a rule that alerts on `level="ERROR"`
in this namespace without reading the message first, this line will fire it
on every normal upload** — the exact failure mode that made
`OrthancStorageGrowing` and `XNATBacklogGrowing` (removed during that historical review, see
`docs/TOUR.md` §9.9) look like coverage while measuring nothing.

**Historical proposed fix (implemented by the current pin).** Either skip the checksum comparison (and this
log line) when XNAT's stored checksum is empty/unset — that state means "not
computed yet", not "computed and different" — or log it at INFO/DEBUG, since
the pass's own outcome is already success.

## Replacements / future

- **Orthanc C-STORE reception is already implemented and is the default.**
  The file-drop source is optional. This former proposal is retained as
  history; it is not an outstanding replacement task (reviewed 2026-11-10)
- **DICOMweb (STOW-RS)** receiver — modern alternative to C-STORE;
  HTTPS-native, plays well with our TLS architecture
- **Custom Python service**; only worth doing if we outgrow accessionflow;
  AIS keeps adding features upstream so generally a bad bet

## Future enhancements (NOT YET implemented, candidate upstream PRs)

These are the "nice-to-haves" we considered for the fork but
deliberately scoped out of the current change set:

- **Native `prometheus_client` metrics** at `:9090/metrics`:
  counters like `xnat_ingest_files_received_total`,
  `xnat_ingest_sessions_staged_total`, histograms for upload duration.
  Today there are no pipeline *metrics* at all. Vector's `log_to_metric`
  transform and its `:9598` Prometheus exporter were removed — the edge
  Vector renders no Service (`charts/edge/templates/vector.yaml`) and the
  mgmt one sets `service: {enabled: false}` — so everything below is
  derived from **log lines** instead: Vector ships the JSON events to
  Loki, and Loki's own ruler counts them
  (`charts/mgmt/files/loki-ruler-rules.yaml`). Line counts measure observed emissions and can be affected by dropped
  logs, retries, and grouping. They are not exact session counts. LogQL can
  unwrap numeric durations for percentiles; native Prometheus histogram
  buckets are a separate unimplemented interface.
- **Custom pipeline-event names** in log lines — e.g. an `event` field
  with values `session_staged`, `xnat_upload_completed`, etc.
  The 0.20.0 uploader has structured events for selected paths, including
  `xnat_identity_adoption` and `xnat_repair_completed`. Other messages remain
  free-form. More event names could make Loki queries easier to maintain.
- **Structured DICOM SHA256** in the staging-event log — for
  end-to-end integrity verification against XNAT.

These would be small, additive PRs upstream — none of them require
touching the core group-orthanc / assign / upload logic.

## Source retirement and metadata in 0.19.0

**Current status (2026-11-10):** these 0.19.0 migration cautions also apply
to the 0.20.0 image source. The dated 0.19.0 test results are historical
evidence. They do not establish a 0.20.0 end-to-end result.

With `--unlink-source all`, a successful label or deidentify pass removes the
session input paths captured before it loaded the session. This includes files
that the stage did not process. The behavior is present from 0.18.0. Keep
`/data/grouped` and `/data/assigned` session folders managed by the pipeline;
do not put files into them by hand. Use the incoming path for supported file
drops. A facility-backup copy exists only if the DICOM-protocol callback wrote it
successfully and the retention policy has kept it. REST uploads and file-drop
input bypass that backup write. The stage does not verify any backup before
it unlinks an input. Unlinking can remove the last local path if other copies
are absent, even when the data-policy deletion switch is off.
New paths created after the snapshot are left for a later pass. Replacing a
path that was already in the snapshot is not protected. Other unlink modes
have different scope; this warning concerns `all`.

The deidentify metadata allowlist defaults to `__uid__`. Reserved `__uid__`,
`__labels__` and `__store_type__` survive where present. The chart also requests
`SOPClassUID` with `--metadata-allowlist __uid__,SOPClassUID`, because reclaimers
need it to map DICOM resources to XNAT labels. A resource sidecar can otherwise
be empty. Missing header-backed metadata can be read from the DICOM files.
The optional package stage writes fuller sidecars; the deidentify allowlist
is not a metadata restriction on every later stage.

In 0.20.0, `Accession.new_empty()` also copies the accession's custom
`fields`. These are separate from metadata sidecars. `save()` writes
them without the metadata allowlist, and `store xnat` sends them as
XNAT custom fields. The chart does not run `select-fields`; if a custom
step populates these fields, review their contents separately.

## XNAT grouping identity after the migration

The XNAT custom field `xnat_ingest_uid` records the exact saved grouping UID
from `__uid__`. In the default DICOM pipeline, IDSpec escapes StudyInstanceUID
before saving it, so periods become underscores, for example `1_2_826_...`.
The store does not convert the value. Compare the remote field with the exact
saved value, not with an independently reformatted DICOM header.

Legacy local sessions without `__uid__` receive only the subject check. When
an incoming UID is present but an older XNAT session has no identity field,
the upload path can adopt it after the subject check and log the WARNING
`Adopting the incoming identity` with event `xnat_identity_adoption`. Adoption
does not prove the identity of files already stored there. A mismatched UID
or subject is refused. Keep this distinction when validating in-flight data.

The 0.20.0 upload loop waits for the remainder of its interval. A historical tier-2 test with 0.19.0 on 2026-11-10 recorded `Upload took 10.8 seconds, waiting another 49.2 seconds before
running again (loop every 60 seconds)`. The chart's separate writer shell loops
still sleep for their configured full interval after a pass.
