# xnat-ingest

## Overview

[xnat-ingest](https://github.com/Australian-Imaging-Service/xnat-ingest)
is the AIS-maintained Python tool that:
1. **Groups** DICOM instances into studies by REST-pulling them from Orthanc
   (`group-orthanc`)
2. **Assigns** each study an XNAT project/subject/session identity and stages it
   as a structured directory (`assign`)
3. **Uploads** staged sessions to an XNAT server via REST (`upload`)

An optional fourth stage, `deidentify`, can sit between 2 and 3 for sites whose
studies arrive already identified.

Upstream ≥ 0.12 split the old single `sort` command into these discrete stages.
We run them as three Deployments on the single node, all rendered by
`charts/edge`:
- **`xnat-ingest group-orthanc`** (`<release>-group-orthanc`, `component=group`)
  — REST-pulls de-identified studies from Orthanc and hardlinks them into
  `/data/grouped`
- **`xnat-ingest assign`** (`<release>-assign`, `component=assign`) — reads
  `/data/grouped`, assigns project/subject/session IDs, and collates into
  `/data/assigned`
- **`xnat-ingest deidentify`** (`<release>-deidentify`, `component=deidentify`) —
  OPTIONAL and off by default (`ingest.deidentify.enabled`). Reads
  `/data/assigned`, writes de-identified sessions to `/data/deidentified` and a
  re-identification mapping to `/data/reid`. Only for pipelines where studies
  arrive already carrying their `ClinicalTrial*` identifiers — see
  [choosing-a-deid-engine.md](../choosing-a-deid-engine.md). When enabled,
  `upload` follows it to `/data/deidentified`.
- **`xnat-ingest package`** (`<release>-package`, `component=package`)
  is optional and off by default (`ingest.package.enabled`); runs after
  deidentify, under `deid.engine: ingest` only. Reads `/data/deidentified` and
  writes `/data/packaged`. Each `medimage/dicom-series` scan resource is
  replaced by a `DICOM-zip` resource, holding the whole series as an
  uncompressed zip, and one DICOM sample that XNAT can read headers from.
  A session with no `dicom-series` scan resource passes through unchanged only
  with xnat-ingest PR #217 (open on 2026-10-20). Without it, the stage logs
  `Skipping '<session>' because it has no <datatype> scan resources` at INFO
  on every pass. The session stays in `/data/deidentified` and does not reach
  XNAT. Each
  session is removed from `/data/deidentified` once it has been packaged
  (`dataPolicy.derived.deidentified.reclaim: onPackaged`). An empty input is
  normal while waiting for work. The stage runs the pipeline image
  (`ingest.image.tag`), which needs fileformats 0.22.1 or later; 0.16.2 does
  not have it. See [package-stage.md](../package-stage.md) for the versions,
  the vendor package and how a site turns the stage on.
- **`xnat-ingest upload`** (`<release>-upload`, `component=upload`) — reads
  `/data/assigned`, `/data/deidentified` when the deidentify stage is on, or
  `/data/packaged` when the package stage is on, and uploads sessions to XNAT

All three run in ONE namespace — `namespace:` in `sites/<site>/values.yaml`,
`xnat-ingest`. Tier-2 splits ingest (edge cluster) from upload (management
cluster) because they are different machines; on one node there is nothing to
split.

Two further stages exist in the chart and are off by default: `group-fs`
(`ingest.fileDrop.enabled` — a watched directory instead of a modality) and
`associate` (`ingest.associate.enabled` — Siemens twix/rda/puls side files).

There is **no S3 hop**: `upload.mode: direct`, and the chart and `install.sh`
both refuse anything else, because `s3` needs the tier-2 management plane
(SeaweedFS, a staging bucket, a management-side reclaimer) that does not exist
here. The chart no longer contains the S3 uploader. Every stage reads
and writes directories on one shared volume; upload reads the same
`/data/assigned` that `assign` wrote.

The group initializer tries Orthanc `/system` up to 18 times, with a five-second curl timeout and five-second pauses after failed attempts (up to about 180 seconds).
This checks HTTP availability, not response JSON; redirects and failed transfers do not count as ready.

## Role in this stack

The DICOM ingest engine downstream of Orthanc.

- **group-orthanc** polls Orthanc's REST API on the node
  (`http://<release>-orthanc.<namespace>.svc.cluster.local:8042`), selects
  studies labelled `xnat-ingest-ready` (and not yet `xnat-ingest-processed`), and
  hardlinks the deid'd instances from Orthanc's storage tree
  (`/data/orthanc-storage`) into grouped studies under `/data/grouped`. Same
  filesystem ⇒ hardlink, not copy. It then labels the study
  `xnat-ingest-processed` so later cycles skip it.
- **assign** reads `/data/grouped`, derives the XNAT project/subject/session IDs
  from the DICOM clinical-trial tags the Orthanc deid hook writes, and collates
  each study into `/data/assigned/<project>.<subject>.<session>/`. Project comes
  from `ClinicalTrialProtocolID` (= the `orthanc.deid.aetMap.<AET>.project` entry
  for the sending AET), subject from `ClinicalTrialSubjectID`, session from
  `ClinicalTrialTimePointID` — no hardcoded project constant.
- **upload** reads that same `/data/assigned` directory (every stage mounts the
  one `<release>-pipeline` PVC at `/data`, backed by hostPath
  `storage.pipeline.hostPath` = `/data/xnat-ingest`) and pushes each session to
  XNAT over HTTPS.

## What xnat-ingest has access to

### group pod (`component=group`)
- **PVC `<release>-pipeline`** mounted at `/data` — reads `/data/orthanc-storage`,
  writes `/data/grouped`
- **Orthanc REST API** in-cluster at
  `http://<release>-orthanc.<namespace>.svc.cluster.local:8042` (to list labelled
  studies and pull instances). Credentials come from the `orthanc-credentials`
  Secret when `orthanc.auth.enabled` is true; with auth off the chart still
  passes the literal `orthanc`/`orthanc`, because `group-orthanc` requires the
  positional user/password arguments either way.
- **No XNAT credentials** — group-orthanc doesn't talk to XNAT

### assign pod (`component=assign`)
- **PVC `<release>-pipeline`** mounted at `/data` — reads `/data/grouped`,
  writes `/data/assigned`
- **No Orthanc or XNAT access** — it only reshapes local directories
- **The upload-tree writer lock, `/data/.locks/assigned.lock`**: `assign`
  writes the tree the uploader reads (deid.engine orthanc or none), so it runs
  one pass at a time and holds this lock for each pass (`edge.lockedStage` in
  `charts/edge/templates/_helpers.tpl`). The staged-reclaimer takes the same
  lock around each delete, and deletes only while the writer holds
  `/data/.locks/assigned.alive`, a shared lock the writer keeps for its whole
  life. This does not change how a stage removes its own input
  (`--unlink-source`). Under deid.engine
  ingest, `deidentify` writes the upload tree and takes
  `/data/.locks/deidentified.lock` instead. With the package stage on
  (`ingest.package.enabled`), `package` writes the upload tree and takes
  `/data/.locks/packaged.lock`; `deidentify` then takes turns on that same
  lock, one pass per turn and without `--loop`: `deidentify` keeps holding
  `/data/.locks/deidentified.lock` for each pass, and `package` takes that lock
  and then `packaged.lock` for each of its passes, so a pass of one never runs
  beside a pass of the other, also during the upgrade that turns the stage on
  or off (see [package-stage.md](../package-stage.md))

### upload pod (`component=upload`)
- **PVC `<release>-pipeline`** mounted at `/data` — reads `/data/assigned`, the
  SAME claim `assign` writes to. One claim for every stage is what makes that
  guaranteed rather than a convention; split them and upload sees an empty dir.
- **Outbound HTTPS** to the configured XNAT server
- **One Secret** `xnat-credentials` (keys `server`, `username`, `password`) —
  `upload.direct.existingSecret`. Tier-1 is the tier that holds an XNAT
  credential at all: a tier-2 edge writes to a bucket-scoped S3 key and never
  reaches XNAT. Scope this account to the projects in this site's `aetMap` and
  nothing else.

## Where it runs

| Deployment | Namespace | Image |
|---|---|---|
| `<release>-group-orthanc` | `xnat-ingest` | `ingest.image.repository:ingest.image.tag` (default `ghcr.io/australian-imaging-service/xnat-ingest:0.16.2`) |
| `<release>-assign` | `xnat-ingest` | same image |
| `<release>-upload` | `xnat-ingest` | same image |

`<release>` is the Helm release name, which `install.sh` sets to the site name.

The image is the **upstream** one on `ghcr.io` — all the AIS-Edge changes (JSON
log output via `AIS_LOG_FORMAT=json`, the `group-orthanc` Orthanc REST-pull, the
`assign` ID-assignment stage, and a local-filesystem upload source where the
first positional arg to `upload` is a local path, not an `s3://` URL) are now
merged upstream. Pin or bump it with `ingest.image.tag` in
`sites/<site>/values.yaml`. `charts/edge/Chart.yaml`'s `appVersion` records the
version the pipeline arguments are written against — not cosmetic, because the
CLI changed shape at 0.12.

## Configuration

Everything non-secret is in **one file**, `sites/<site>/values.yaml` (scaffold it
with `scripts/site-secrets.sh new <name> single`). You never edit
`charts/edge/values.yaml`: that holds the defaults and the reasoning behind them.

| Where | What |
|---|---|
| `ingest.image.{repository,tag}` | which xnat-ingest build every stage runs |
| `ingest.logFormat` | `json` — parsed by the alert rules and dashboards, so functional, not cosmetic |
| `ingest.orthancGroup.{interval,waitPeriod,copyMode,toProcessLabel,processedLabel}` | group-orthanc |
| `ingest.assign.{interval,copyMode,tagMapping.*}` | assign |
| `upload.direct.{loop,waitPeriod,alwaysInclude,requireManifest,verifySsl,tempDir,existingSecret}` | upload |
| `orthanc.deid.aetMap.<AET>.project` | the AE title → XNAT project map `assign` ultimately reads, via `ClinicalTrialProtocolID` |
| Secret `xnat-credentials` (namespace `xnat-ingest`) | `server`, `username`, `password` — SOPS-encrypted in `sites/<site>/secrets.enc.yaml`, applied by `scripts/site-secrets.sh apply <site>` before the chart |
| `charts/edge/templates/ingest-pipeline.yaml` | the group + assign Deployments (and the optional `group-fs` / `associate` stages) |
| `charts/edge/templates/upload.yaml` | the upload Deployment (the `direct` branch) |

### Ingest stage CPU and memory

Set each stage's Kubernetes `resources` in the site's values file. The keys
are independent, including the two group inputs:

| Values key | Container |
|---|---|
| `ingest.orthancGroup.resources` | `group` in the group-orthanc Deployment |
| `ingest.fileDrop.resources` | `group-fs` in the optional file-drop Deployment |
| `ingest.assign.resources` | `assign` |
| `ingest.deidentify.resources` | `deidentify`, when `deid.engine=ingest` |

Each key accepts Kubernetes `requests` and `limits` for CPU and memory.
An omitted key, `{}`, or `null` adds no resources to that container. These
empty defaults preserve the existing behavior: the chart does not reserve CPU
or memory for these stages and does not cap their use. A namespace LimitRange
can still apply defaults. Installing this chart change alone does not establish
a memory limit or a tested production capacity.

This example shows the format for one stage. The numbers are illustrative;
they are not a tested site profile or recommended production limits:

```yaml
ingest:
  assign:
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: "1"
        memory: 2Gi
```

Use the other keys to size the other stages separately. Keep uploader settings
under `upload.direct.resources` or, on main in S3 mode, `upload.s3.resources`.
Orthanc remains the DICOM receiver; size the `deidentify` stage for the
xnat-ingest recipes used at the site.

Before setting a production profile, measure CPU and memory with the largest
supported studies, the site's recipes, and concurrent stages. Allow memory
headroom above observed peaks and check the total requests against node
allocatable capacity, including Orthanc and the other services. Short synthetic
runs and idle snapshots do not establish a safe upper bound. A memory limit
that is too low can stop a stage with OOMKilled; CPU limits can slow the
pipeline. Verify throughput, restarts, and recovery on the test deployment
before applying a site profile.

### group-orthanc arguments

```
xnat-ingest group-orthanc \
  http://<release>-orthanc.xnat-ingest.svc.cluster.local:8042  # Orthanc REST URL
  /data/orthanc-storage                    # Orthanc storage dir (as mounted)
  /data/grouped                            # output: grouped studies
  $(ORTHANC_USER) $(ORTHANC_PASSWORD)      # orthanc-credentials, or literal orthanc/orthanc when auth is off
  --to-process-label   xnat-ingest-ready         # ingest.orthancGroup.toProcessLabel (fixed string — see below)
  --processed-label    xnat-ingest-processed     # ingest.orthancGroup.processedLabel
  --copy-mode          hardlink_or_copy          # ingest.orthancGroup.copyMode
  --wait-period        60                        # ingest.orthancGroup.waitPeriod
  --loop               60                        # ingest.orthancGroup.interval
```

`--to-process-label` is the gate that stops identifiable data leaving Orthanc:
the Lua hook applies it in `OnStableStudy`, *after* the original has been backed
up and the instance de-identified. Clearing it while deid is on would pull
everything; leaving it set while deid is **off** means nothing applies the label
and the pipeline stalls with data sitting in Orthanc and no error anywhere —
which the chart refuses to render.

**It is a two-state switch, not a free-text value.** Only the CONSUMER reads the
key: `charts/edge/templates/ingest-pipeline.yaml` renders
`--to-process-label <ingest.orthancGroup.toProcessLabel>` into the group-orthanc
args. The PRODUCER does not — the Lua hook PUTs the literal string
(`RestApiPut("/studies/" .. studyId .. "/labels/xnat-ingest-ready", "")` in
`charts/edge/files/deidentify-and-forward.lua`), with no env var and no
`routing.json` key behind it. Set `toProcessLabel` to any other string and you
get exactly the silent stall described above — Orthanc keeps labelling studies
`xnat-ingest-ready` while group-orthanc filters for something else, so every
pod is healthy and nothing moves — except that this time the render-time guard
in `charts/edge/templates/_helpers.tpl` does **not** catch it: it only tests
empty-vs-non-empty against `orthanc.deid.enabled`, never the value. The two
supported values are therefore `xnat-ingest-ready` (deid on, the chart default)
and `""` (deid off — `scripts/ci/values.sh` clears it for the no-deid CI case).
Changing the string means editing the Lua hook in the same commit.

`processedLabel` carries no such constraint, and the difference is worth knowing
before you assume symmetry: group-orthanc applies that one itself via
`--processed-label`, and `charts/edge/templates/data-policy.yaml` hands the same
value to the reclaimer as `ORTHANC_PROCESSED_LABEL`, so both ends of that
handshake read the one values key and stay in step by construction.

### assign arguments

```
xnat-ingest assign \
  /data/grouped                          # input: group-orthanc output
  /data/assigned                         # output: upload reads this
  --project  ClinicalTrialProtocolID     # ingest.assign.tagMapping.project
  --subject  ClinicalTrialSubjectID      # ingest.assign.tagMapping.subject
  --session  ClinicalTrialTimePointID    # ingest.assign.tagMapping.session
  --copy-mode      hardlink_or_copy      # ingest.assign.copyMode
  --unlink-source  all                   # only when dataPolicy.derived.grouped.reclaim = onAssigned
```

The chart runs these arguments one pass at a time inside the upload-tree writer
lock, with no `--loop`:

```
sh -c 'trap exit TERM INT; mkdir -p /data/.locks && exec 9>>/data/.locks/assigned.alive && flock -s 9 && while :; do flock /data/.locks/assigned.lock "$0" "$@" || exit; sleep 60 & wait $!; done' \
  xnat-ingest assign <the arguments above>   # sleep: ingest.assign.interval
```

The sleep after each pass is the same full interval that `--loop` sleeps. A
pass that fails stops the container, as an exception out of `--loop` did.
fd 9 holds the shared lock on `assigned.alive` for the life of the container.
The shell is PID 1, and PID 1 has no default action for a signal, so the
`trap` is necessary. A stop (SIGTERM or SIGINT) ends the loop at once in the
sleep: the sleep runs in the background, and `wait` returns on the signal. In
a pass, it ends the loop when the pass ends: the pass is not stopped during a
write, and no pass starts from the sleep after the signal. A stop that comes
while the stage waits for its lock runs that one pass first. A pass that is
longer than the grace period (30 s) still gets SIGKILL. Under
deid.engine ingest, `assign` does not write the upload tree, so it keeps
`--loop 60` and `deidentify` runs inside the lock. With the package stage on,
`package` runs inside `deidentified.lock` and then `packaged.lock` for each
pass, and `deidentify` keeps its own `deidentified.lock` per pass with the same
loop, without the `.alive` handle and without `--loop`.

`--unlink-source all` drops each grouped session once it has been assigned, and
it is not an optimisation. `assign` rebuilds its work list from a live
listing of `/data/grouped` every pass, so without it the same sessions are
re-assigned forever: `/data/assigned` is repopulated, the uploader re-stages, and
the upload-success alert re-fires (that produced two days of duplicate mail). It
deletes HARDLINKS, not data — the bytes remain in Orthanc storage and in the
facility backup.

The `ClinicalTrial*` tags are written by the Orthanc deid hook
(`ClinicalTrialProtocolID` = project, `ClinicalTrialSubjectID` = SubjectHash,
`ClinicalTrialTimePointID` = SessionHash), so `assign` reads them directly — the
project comes from `orthanc.deid.aetMap`, not a config constant. IDs are
normalised to `[A-Za-z0-9_]`, so keep XNAT project IDs in that set (a hyphen
becomes `_`).

### upload arguments

```
xnat-ingest upload /data/assigned $(XINGEST_HOST)   # LOCAL source dir (no s3://)
  --always-include        all       # upload.direct.alwaysInclude
  --loop                  60        # upload.direct.loop
  --wait-period           60        # upload.direct.waitPeriod
  --require-manifest                # upload.direct.requireManifest = true (default):
                                    #   a half-written resource waits for the next pass
  --dont-require-manifest           # instead, when upload.direct.requireManifest = false
  --dont-verify-ssl                 # rendered when upload.direct.verifySsl = false
                                    #   (only for an XNAT with a private/self-signed cert)
```

Important env vars:
- `AIS_LOG_FORMAT=json` (`ingest.logFormat`) — enable JSON log output (one object
  per line) so Vector indexes `ts/level/logger/message/event` without regex
  parsing. Drops to text if unset, so the image still works without it.
- `XINGEST_HOST/USER/PASS` (upload pod only) — XNAT REST credentials, sourced from
  the `xnat-credentials` Secret (`server`/`username`/`password`).
- `XINGEST_TEMPDIR=/data/tmp` (`upload.direct.tempDir`) — on the pipeline volume,
  so a large session is assembled on the same filesystem it was read from.

## Operations

```bash
# All three stages are in the one release namespace (JSON when AIS_LOG_FORMAT=json)
kubectl logs -n xnat-ingest -l component=group  -f | jq
kubectl logs -n xnat-ingest -l component=assign -f | jq
kubectl logs -n xnat-ingest -l component=upload -f | jq

# Inspect the assigned sessions on the node (storage.pipeline.hostPath)
sudo ls -R /data/xnat-ingest/assigned/

# Manually promote an invalid session to test upload
sudo mv /data/xnat-ingest/assigned/__invalid__/<dir> \
        /data/xnat-ingest/assigned/<project>.<subject>.<session>

# Re-render what the release will run, without installing
helm template <release> charts/edge -n xnat-ingest -f sites/<site>/values.yaml
```

### Upgrade or roll back while the cleanup can delete

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

For XNAT proof, the worker uses plain HTTP and sends `Cache-Control: no-cache`.
It queries the experiment endpoint before reading its file catalog and keeps
the per-file HEAD checks. A missing experiment, missing file, failed request,
invalid response or failed login keeps the affected data. If a login expires,
one bounded login retry precedes the request retry. The worker closes any
login it opens; the shell closes the initial login that it lends the worker.
The connection can stay open across sessions without retaining their listings.
On TERM, the shell forwards the signal to the worker and waits for its cleanup.
The worker closes a renewed login through a fresh connection, even if the
signal interrupted an HTTP response.

These checks do not make XNAT and the source store one transaction. They
preserve the existing per-file evidence, local writer locks and conditional
deletes. A dry run makes the same checks and removes no data.

## Benefits

- **Battle-tested DICOM parsing** — handles edge cases (missing
  AccessionNumber, multi-frame, multi-series) we don't want to re-implement
- **Idempotent** — re-running upload skips sessions already in XNAT
- **Loop mode** — every stage runs continuously; new studies are grouped, staged,
  and uploaded as they arrive
- **Connection-resilience** — transient network errors don't kill the upload loop

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| DICOM missing AccessionNumber | `assign` routes the session to `/data/assigned/__invalid__/` | Manual rename + move (see Operations). `DICOMValidationFailureSpike` in `charts/edge/files/loki-ruler-rules.yaml` covers the >10/h case — it selects `component="assign"`, so it is one of the rules that works unchanged on a single node, and it needs `observability.stack.enabled` for the Loki ruler to evaluate it |
| Secret missing at install | pod sits in `CreateContainerConfigError` with nothing saying why | `install.sh` applies `sites/<site>/secrets.enc.yaml` *before* the chart, deliberately in that order |
| XNAT login fails | upload pod crashes / errors | check the `xnat-credentials` Secret; XNAT user must be a local account, not AAF/OIDC |
| XNAT down | uploads fail; assigned sessions accumulate in `/data/assigned` | the upload loop clears the backlog when XNAT returns. CAUTION: no shipped rule watches this on tier-1 — the backlog and stall rules in `loki-ruler-rules.yaml` (`SessionUploadStalled`, `SessionStagedNotConfirmedInXNAT`) all select `component="s3-uploader"`, which does not exist in `direct` mode. Watch the `component=upload` logs and free disk |
| stages given different volumes | a stage reads an empty dir | every stage mounts the ONE `<release>-pipeline` claim at `/data`; that is a chart invariant, not a per-pod setting to keep in step |
| cross-filesystem hardlink | `group-orthanc` fails with `EXDEV`, or `hardlink_or_copy` silently degrades to a full byte copy of every study | keep `/data/orthanc-storage`, `/data/grouped` and `/data/assigned` on the one volume — which is why they are subdirectories of a single claim |
| group/assign pod restarts | in-flight stage interrupted; resumes on next loop | `--wait-period` avoids grouping half-written studies |
| A writer pass stops or its pod is killed | the pass stops; its lock goes with it | The kernel releases a `flock` when the last process that holds it stops, so the next pass can take it. A child process that a pass leaves keeps the lock until that child stops |
| `ingest.orthancGroup.toProcessLabel` set to a custom string | group-orthanc matches no study; data accumulates in Orthanc with every pod Running and no alert. The chart renders and installs cleanly | the Lua hook hardcodes `xnat-ingest-ready`, and the `_helpers.tpl` guard only checks empty-vs-set — treat the key as `xnat-ingest-ready` or `""` only, and edit `charts/edge/files/deidentify-and-forward.lua` too if a different string is genuinely needed |
| `dataPolicy.derived.assigned.reclaim: onUploaded` with `upload.mode: direct` | `/data/assigned` is never reclaimed; disk grows silently even with the data policy fully enabled | the `onUploaded` condition looks for a per-session fingerprint under `/data/LOGS/s3-uploader-state`, which only the **s3** uploader writes — `xnat-ingest upload` has no equivalent. Watch free disk yourself: the only disk warning in the system is `dataPolicy.originals.facilityBackup.minFreeDiskPercent`, which measures the facility-backup location and warns rather than deletes |

## Replacements / future

- **DICOMweb (STOW-RS)** receiver — modern alternative to C-STORE; HTTPS-native.
- **Custom Python service** — only worth doing if we outgrow xnat-ingest; AIS
  keeps adding features upstream, so generally a bad bet.

## Future enhancements (NOT YET implemented, candidate upstream PRs)

- **Native `prometheus_client` metrics** at `:9090/metrics`: counters like
  `xnat_ingest_files_received_total`, `xnat_ingest_sessions_staged_total`, and
  upload-duration histograms. Today we derive these from log-line counts via
  Vector, which is good enough but loses histogram precision.
- **Custom pipeline-event names** in log lines (an `event` field with values like
  `session_staged`, `xnat_upload_completed`) so Loki queries are cleaner.
- **Structured DICOM SHA256** in the staging-event log for end-to-end integrity
  verification against XNAT.
