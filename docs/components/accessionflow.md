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
is the AIS-maintained Python tool that:
1. **Groups** DICOM instances into studies by REST-pulling them from Orthanc
   (`group-orthanc`, running `accessionflow collate orthanc`)
2. **Assigns** each study an XNAT project/subject/session identity and stages it
   as a structured directory (`assign`, running `accessionflow label xnat`)
3. **De-identifies** assigned sessions with the site recipe (`deidentify`).
4. **Uploads** the result to XNAT over HTTPS (`upload`, running
   `accessionflow store xnat`).

The default `deid.engine: ingest` renders the deidentify stage. Use it for new
sites. Review the selected source labels before the recipe runs.

Historical releases split the old `sort` command into stages; the exact first
release for every split is not verified (2026-11-10). The 0.20.0 command names
and chart wrappers below are the current operational contract.
We run the default stages as four Deployments on the single node, all rendered by
`charts/edge`:
- **`accessionflow collate orthanc`** (`<release>-group-orthanc`, `component=group`)
  REST-pulls original studies from Orthanc and hardlinks them into
  `/data/grouped`
- **`accessionflow label xnat`** (`<release>-assign`, `component=assign`); reads
  `/data/grouped`, assigns project/subject/session IDs, and collates into
  `/data/assigned`
- **`accessionflow deidentify`** (`<release>-deidentify`, `component=deidentify`):
  enabled by the default `deid.engine: ingest`. Reads `/data/assigned`, writes
  `/data/deidentified`, and writes sensitive mappings under `/data/reid`.
  The obsolete `ingest.deidentify.enabled` key is rejected. Supply the site's
  recipes and configure mapping encryption before receiving patient data.
  See [deidentification.md](deidentification.md) for label and recipe checks.

- **`accessionflow package`** (`<release>-package`, `component=package`)
  is optional and off by default (`ingest.package.enabled`); runs after
  deidentify, under `deid.engine: ingest` only. Reads `/data/deidentified` and
  writes `/data/packaged`. Each `medimage/dicom-series` scan resource is
  replaced by a `DICOM-zip` resource, holding the whole series as an
  uncompressed zip, and one DICOM sample that XNAT can read headers from.
  A session with no `dicom-series` scan resource passes through unchanged
  in 0.20.0. This behavior came from xnat-ingest PR #217. The earlier
  implementation logged `Skipping '<session>' because it has no <datatype>
  scan resources` and left that input in `/data/deidentified`. That old
  limitation does not apply to the current pin. Each
  session is removed from `/data/deidentified` once it has been packaged
  (`dataPolicy.derived.deidentified.reclaim: onPackaged`). An empty input is
  normal while waiting for work. The stage runs the pipeline image
  (`ingest.image.tag`), which includes fileformats 0.22.5. The old 0.16.2
  image did not meet the 0.22.1 minimum. See [package-stage.md](../package-stage.md) for the versions,
  the vendor package and how a site turns the stage on.
- **`accessionflow store xnat`** (`<release>-upload`, `component=upload`); reads
  `/data/assigned`, `/data/deidentified` when the deidentify stage is on, or
  `/data/packaged` when the package stage is on, and uploads sessions to XNAT

All stages run in one namespace; `namespace:` in `sites/<site>/values.yaml`,
`xnat-ingest`. Tier-2 splits ingest (edge cluster) from upload (management
cluster) because they are different machines; on one node there is nothing to
split.

The optional `group-fs` input (`ingest.fileDrop.enabled`) watches a directory.
A legacy associate template remains in the chart, but the render guard rejects
`ingest.associate.enabled`: attach support lacks the required inputs and output
contract. Do not enable it for Siemens side files on this chart.

There is **no S3 hop**: `upload.mode: direct`, and the chart and `install.sh`
both refuse anything else, because `s3` needs the tier-2 management plane
(SeaweedFS, a staging bucket, a management-side reclaimer) that does not exist
here. The chart no longer contains the S3 uploader. Every stage reads
and writes directories on one shared volume; upload reads the same
`/data/deidentified` that deidentify wrote, or `/data/packaged` when packaging
is enabled. Assignment output remains an intermediate tree under ingest.

The group initializer tries Orthanc `/system` up to 18 times, with a five-second curl timeout and five-second pauses after failed attempts (up to about 180 seconds).
This checks HTTP availability, not response JSON; redirects and failed transfers do not count as ready.

## Role in this stack

The DICOM ingest engine downstream of Orthanc.

- **group-orthanc** polls the receiver's REST API and waits for stable input.
  Under ingest the chart clears the Lua ready-label filter. It hardlinks
  original instances from `/data/orthanc-storage` into `/data/grouped`, then
  records processed and snapshot labels. Changed input can be staged again.
- **assign** reads the configured tags and writes
  `/data/assigned/<project>.<subject>.<session>/`. The derived ingest mapping
  is StudyID, PatientID and AccessionNumber. A project constant can replace
  the project source. A raw clinical identifier becomes an XNAT label if the
  site selects it; later recipe processing cannot change that assigned label.
- **deidentify** reads the assigned sessions and the project or fallback recipe.
  It writes `/data/deidentified` and the requested re-identification map.
  Private tags, sex and age remain in the example policy. Review the actual
  modality output and encrypt the maps for production input.
- **upload** reads `/data/deidentified`, or `/data/packaged` when the optional
  package stage is on. It uses the same pipeline PVC mounted at `/data` and
  sends the result over HTTPS with the local XNAT credentials.

File-drop input can join this chain without Orthanc. It does not receive a
facility-backup copy from the Lua callback. Keep those originals and verify
that their format and label metadata are handled by the same approved recipe.
No AET routing or unknown-AET quarantine applies to either ingest input path.

## What accessionflow has access to

### group pod (`component=group`)
- **PVC `<release>-pipeline`** mounted at `/data` — reads `/data/orthanc-storage`,
  writes `/data/grouped`
- **Orthanc REST API** in-cluster at
  `http://<release>-orthanc.<namespace>.svc.cluster.local:8042` (to list stable
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
  `/data/.locks/packaged.lock`; `deidentify` takes turns on its own input/output
  lock, one pass per turn and without `--loop`: `deidentify` keeps holding
  `/data/.locks/deidentified.lock` for each pass, and `package` takes that lock
  and then `packaged.lock` for each of its passes, so a pass of one never runs
  beside a pass of the other, also during the upgrade that turns the stage on
  or off (see [package-stage.md](../package-stage.md))

### upload pod (`component=upload`)
- **PVC `<release>-pipeline`** mounted at `/data`: reads `/data/deidentified`,
  or `/data/packaged` when packaging is enabled. It is the same claim that
  the producing stage writes to. One claim for every stage is what makes that
  guaranteed rather than a convention; split them and upload sees an empty dir.
- **Outbound HTTPS** to the configured XNAT server
- **One Secret** `xnat-credentials` (keys `server`, `username`, `password`) —
  `upload.direct.existingSecret`. Tier-1 keeps XNAT credentials on its node. A tier-2 edge in the normal
  S3 mode uses a bucket-scoped S3 identity instead; main also supports direct
  mode, which needs an XNAT credential on that edge. Scope this account to the projects selected by the site's tag mapping or project constant and
  nothing else.

## Where it runs

| Deployment | Namespace | Image |
|---|---|---|
| `<release>-group-orthanc` | `xnat-ingest` | `ingest.image.repository:ingest.image.tag` (default `ghcr.io/australian-imaging-service/accessionflow:0.20.0`) |
| `<release>-assign` | `xnat-ingest` | same image |
| `<release>-deidentify` | `xnat-ingest` | same image |
| `<release>-upload` | `xnat-ingest` | same image |

`<release>` is the Helm release name, which `install.sh` sets to the site name.

The chart pins the upstream 0.20.0 image shown above. The inspected package
reports `0.20.0`. The previous fork reported
`0.16.3.dev49+ais.20261021.r13.g3182cc6`; that version is migration history. Record the deployed digest and chart values when comparing a site to a
source review. A tag name alone is not a receipt for a running deployment.

The image includes JSON log output, REST grouping, assignment, de-identification
and a local upload source. Pin or change it with `ingest.image.repository` and
`ingest.image.tag` in the site file. Check all rendered CLI arguments and the
synthetic end-to-end result after a change. An upstream release can differ from
the fork even when its version number is higher. The deprecated-engine reference
is in [deidentification.md](deidentification.md#deprecated-orthanc-lua-engine).

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

Version 0.18.0 renamed the tool, collate/label commands and environment
variables. Version 0.19.0 renamed upload to store. The chart keeps
its stage and Kubernetes names. `group-orthanc` runs `accessionflow
collate orthanc`; `group-fs` runs `accessionflow collate folder`; `assign` runs
`accessionflow label xnat`; `upload` runs `accessionflow store xnat`. The
legacy associate template would require `accessionflow attach`, but enabling
`ingest.associate.enabled` is rejected: the chart does not supply the required
inputs, matching rule, or output contract. The command change
does not rename any namespace, Orthanc label or storage folder.

Everything non-secret is in **one file**, `sites/<site>/values.yaml` (scaffold it
with `scripts/site-secrets.sh new <name> single`). You never edit
`charts/edge/values.yaml`: that holds the defaults and the reasoning behind them.

| Where | What |
|---|---|
| `ingest.image.{repository,tag}` | which accessionflow build every stage runs |
| `ingest.logFormat` | `json` — parsed by the alert rules and dashboards, so functional, not cosmetic |
| `ingest.orthancGroup.{interval,waitPeriod,copyMode,toProcessLabel,processedLabel}` | group-orthanc |
| `ingest.assign.{interval,copyMode,tagMapping.*}` | assign |
| `upload.direct.{loop,waitPeriod,alwaysInclude,requireManifest,verifySsl,tempDir,existingSecret}` | upload |
| `ingest.assign.constantProjectId` | Optional destination for all sessions at a single-project site; it overrides project-tag resolution only |
| `ingest.deidentify.{specs,specConfigMap,specFiles,reidEncryptKeySecret}` | Recipe source and reid-map encryption. A missing key reference leaves plaintext maps. |
| Secret `xnat-credentials` (namespace `xnat-ingest`) | `server`, `username`, `password` — SOPS-encrypted in `sites/<site>/secrets.enc.yaml`, applied by `scripts/site-secrets.sh apply <site>` before the chart |
| `charts/edge/templates/ingest-pipeline.yaml` | the group, assign and deidentify Deployments, plus optional group-fs and package stages; associate is render-blocked |
| `charts/edge/templates/upload.yaml` | the upload Deployment (the `direct` branch) |

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
vCPU, 8 GiB), which runs the same stages with the same arguments. Version 0.20.0
ships the same deid 0.4.13. One synthetic MR study went through the real stages:
12,098 instances, 0.92 GB, in four series (10,000 slices of 128 x 128, 2,000 of
256 x 256, 95 of 1280 x 1280, and 3 localizers). The memory of each container
cgroup was read once a second. `anon` is the memory that the kernel cannot drop;
the working set adds the page cache that is in use. The file-drop stage is off
on the test edge, so it ran on the same files in a container with 4 CPUs.

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

With the observability stack on (`observability.stack.enabled`),
kube-state-metrics sees the restarts. `KubePodCrashLooping` (kube-prometheus-stack
87.19.2) fires when the container waits in `CrashLoopBackOff` at least once in
every 5 minutes for 15 minutes. A stage that runs longer than 5 minutes before
each stop can miss that rule. The session also waits, and `StageBacklogAgeing`
fires when the oldest entry of the stage is older than
`dataPolicy.reporter.stageAgeAlertAfter` (`7d` by default). Without the stack,
nothing alerts. After an unusually large study, check the stage pods.

To recover, raise `limits.memory` for that stage in the site file and upgrade
the release. The next pass takes the waiting session.

Before setting a production profile, measure CPU and memory with the largest
supported studies, the site's recipes, and concurrent stages. Allow memory
headroom above observed peaks and check the total requests against node
allocatable capacity, including Orthanc and the other services. Short synthetic
runs and idle snapshots do not establish a safe upper bound. Verify throughput,
restarts, and recovery on the test deployment before applying a site profile.

### group-orthanc arguments

```
accessionflow collate orthanc \
  http://<release>-orthanc.xnat-ingest.svc.cluster.local:8042  # Orthanc REST URL
  /data/orthanc-storage                    # Orthanc storage dir (as mounted)
  /data/grouped                            # output: grouped studies
  $(ORTHANC_USER) $(ORTHANC_PASSWORD)      # orthanc-credentials, or literal orthanc/orthanc when auth is off
  --processed-label    xnat-ingest-processed     # ingest.orthancGroup.processedLabel
  --copy-mode          hardlink_or_copy          # ingest.orthancGroup.copyMode
  --wait-period        60                        # ingest.orthancGroup.waitPeriod
  # No --loop: the shell wrapper takes grouped.lock for each pass,
  # then sleeps ingest.orthancGroup.interval (default 60 seconds).
```

Under ingest, the chart omits `--to-process-label`. The stored
`ingest.orthancGroup.toProcessLabel` default can still read `xnat-ingest-ready`,
but the engine helper clears its effective value. The separate Lua
`OnStableStudy` callback still applies the configured ready label when the
backup feature loads the script. It can also clear a processed label. Ingest
grouping does not require this ready label. Inspect the rendered arguments,
not only the raw values, when diagnosing study selection.

`--wait-period` governs stable-input selection. It reduces the chance of
processing a study while it is being sent, but does not establish that a later
series cannot arrive. The processed snapshot records the exported state, and
a changed state can cause grouping to run again. Keep the source while handling
an error; a processed label without matching snapshot evidence is not sufficient
for the data-policy backend to delete a study.

Keep the generated group arguments aligned with the selected engine. A custom
ready-label filter introduces a dependency on the stable-study callback and
its configuration. The script is not loaded for ingest when the facility backup
is off, and an empty ready-label setting suppresses the label write. In either
case such a filter can block selection. A label is not evidence of recipe output.

`processedLabel` carries no such constraint, and the difference is worth knowing
before you assume symmetry: group-orthanc applies that one itself via
`--processed-label`, and `charts/edge/templates/data-policy.yaml` hands the same
value to the reclaimer as `ORTHANC_PROCESSED_LABEL`, so both ends of that
handshake read the one values key and stay in step by construction.

### assign arguments

```
accessionflow label xnat \
  /data/grouped                          # input: group-orthanc output
  /data/assigned                         # output: deidentify reads this
  --project  StudyID     # ingest.assign.tagMapping.project
  --subject  PatientID      # ingest.assign.tagMapping.subject
  --session  AccessionNumber    # ingest.assign.tagMapping.session
  --copy-mode      hardlink_or_copy      # ingest.assign.copyMode
  --unlink-source  all                   # only when dataPolicy.derived.grouped.reclaim = onAssigned
```

Assign always runs one pass per shell-wrapper turn; it has **no `--loop`**
argument. Under ingest it takes `assigned.lock` with `edge.serialisedStage`.
When assigned is the upload source, `edge.lockedStage` also holds a shared
`assigned.alive` lock for the wrapper's lifetime so the reclaimer can verify
that a compatible writer is present. The simplified terminal-writer shape is:

```
sh -c 'trap exit TERM INT; mkdir -p /data/.locks && exec 9>>/data/.locks/assigned.alive && flock -s 9 && while :; do flock /data/.locks/assigned.lock "$0" "$@" || exit; sleep 60 & wait $!; done' \
  accessionflow label xnat <the arguments above>
```

Each successful pass sleeps the full configured stage interval. This differs
from 0.20.0 store's internal loop, which subtracts time spent uploading.
A failed pass exits the wrapper. TERM/INT interrupt idle wait; during a
foreground pass the shell handles the signal after that pass. A signal during
lock wait can therefore allow that one pass before exit. Kubernetes can still
send SIGKILL when the termination grace period expires, so a writer lock does
not make a partially completed pass transactional.

With packaging enabled, deidentify holds `deidentified.lock`; package takes
`deidentified.lock` and then `packaged.lock`. Deidentify never takes
`packaged.lock`. The terminal writer holds the matching `.alive` handle and
the reclaimer checks that handle before deletion. See `edge.serialisedStage`,
`edge.lockedStage`, and the signal checks in `scripts/ci/runtime-templates.sh`
for the complete generated behavior. Do not paste this illustrative wrapper
over the chart; use the rendered arguments and retain the existing lock order.



`--unlink-source all` drops each grouped session once it has been assigned, and
it is not an optimisation. `assign` rebuilds its work list from a live
listing of `/data/grouped` every pass, so without it the same sessions are
considered again. Re-created output can cause extra work. Historical duplicate
mail was recorded under the older emitter (date not verified, reviewed
2026-11-10); 0.20.0 suppresses unchanged-session success. This option
unlinks input paths, which can include hardlinks, symlinks, or copied files.
The last link can be removed; neither an Orthanc copy nor a facility backup
is proved by this operation. See the 0.20.0 source-retirement warning below.

The derived ingest mapping selects StudyID, PatientID and AccessionNumber.
An explicit mapping can select other supported tags. The chart rejects tags
whose names begin with ClinicalTrial under ingest. `constantProjectId` supplies
one project for every session when configured. It does not supply missing
subject/session values or hash any value.

Assignment preserves the selected labels in session metadata. Removing their
source tags later in the recipe cannot remove the labels from XNAT. In
particular, PatientID can contain a raw MRN. Check the source values and use
approved research labels before enabling patient upload. Keep project IDs in
`[A-Za-z0-9_-]` to avoid normalization surprises, and verify the actual result.
A missing or empty required field goes to the invalid holding directory.

### upload arguments

```
accessionflow store xnat /data/deidentified $(ACFLOW_HOST)   # LOCAL source dir (no s3://)
  --always-include        all       # upload.direct.alwaysInclude
  --loop                  60        # upload.direct.loop
  --wait-period           60        # upload.direct.waitPeriod
  --require-manifest                # upload.direct.requireManifest = true (default):
                                    #   a half-written resource waits for the next pass
  --dont-require-manifest           # instead, when upload.direct.requireManifest = false
  --dont-verify-ssl                 # rendered when upload.direct.verifySsl = false
                                    #   disables server verification; configure private CA
                                    #   trust instead for a production XNAT endpoint
```

Important env vars:
- `AIS_LOG_FORMAT=json` (`ingest.logFormat`) — enable JSON log output (one object
  per line) so Vector indexes `ts/level/logger/message/event` without regex
  parsing. Drops to text if unset, so the image still works without it.
- `ACFLOW_HOST/USER/PASS` (upload pod only); XNAT REST credentials, sourced from
  the `xnat-credentials` Secret (`server`/`username`/`password`).
- `ACFLOW_TEMPDIR=/data/tmp` (`upload.direct.tempDir`); on the pipeline volume,
  so a large session is assembled on the same filesystem it was read from.

## Operations

```bash
# All stages are in the one release namespace (JSON when AIS_LOG_FORMAT=json)
kubectl logs -n xnat-ingest -l component=group  -f | jq
kubectl logs -n xnat-ingest -l component=assign -f | jq
kubectl logs -n xnat-ingest -l component=upload -f | jq

# Inspect the assigned sessions on the node (storage.pipeline.hostPath)
sudo ls -R /data/xnat-ingest/assigned/

# Recover an invalid session: follow the guarded steps in "Recovering an
# invalid session" below. A plain mv into an existing folder nests the
# session instead of promoting it.

# Re-render what the release will run, without installing
helm template <release> charts/edge -n xnat-ingest -f sites/<site>/values.yaml
```

### Holding folders

Two folders hold data that a stage could not pass on. No stage, reclaimer or
data policy removes either of them.

| Folder | What puts data there | What to do |
|---|---|---|
| `/facility-backup/__unmapped_aet__/<AET>/`, a legacy quarantine | Not populated by ingest; retained content can predate an engine change | Preserve it and consult the deprecated-engine reference in [deidentification.md](deidentification.md#deprecated-orthanc-lua-engine) |
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
To clear it:

1. List the series of the study with their number, description and count of
   instances. The Orthanc container has no `curl`, so use a port-forward in a
   second terminal. Wait for `Forwarding from 127.0.0.1:8042`, and stop it with
   Ctrl-C when you are done. Leave out `-u` if Orthanc authentication is off.

   ```bash
   # second terminal
   kubectl -n xnat-ingest port-forward deploy/<release>-orthanc 8042:8042
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

`assign` puts a session in `/data/assigned/__invalid__/` when it cannot resolve
the project, subject or session ID from the tags. It logs this line at ERROR:

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
  data policy.
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
on the node. A person with the hospital's records finds the missing value. The
operator runs `sudo ais-requeue requeue <folder> --session <value>`. That page
also gives the methods without full sudo (a sudo rule for this command only,
kubectl), the repository script, the manual fallback, what the tool refuses,
and its exit codes.

The chart ships the tool into the label (`assign`) pod: the ConfigMap
`<release>-requeue-tool`, from `charts/edge/files/requeue-invalid.py`, mounted
read-only at `/opt/ais-edge`. The accessionflow image does not change.

Do not send the study again to correct it. Orthanc keeps the instances that it
already has, and it ignores a copy with the same SOPInstanceUID.

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

These checks do not make XNAT and the source store one transaction. They
preserve the existing per-file evidence, local writer locks and conditional
deletes. A dry run makes the same checks and removes no data.

## Benefits

- **Battle-tested DICOM parsing** — handles edge cases (missing
  AccessionNumber, multi-frame, multi-series) we don't want to re-implement
- **Repeat handling:** the 0.20.0 upload verdict can skip a complete session,
  repair missing files where supported, or refuse a conflict. Matching names
  without XNAT checksums is weaker than byte equality; inspect the verdict
- **Loop mode** — every stage runs continuously; new studies are grouped, staged,
  and uploaded as they arrive
- **Connection resilience:** selected connection failures are retried. Other
  errors can end a pass or container; inspect the current exception and restart
  evidence rather than assuming all transient faults stay inside the loop

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| DICOM missing AccessionNumber | If the site maps that missing tag to a required label, `assign` saves the session in `/data/assigned/__invalid__/` | Use the procedure in "Recovering an invalid session" and verify the missing labels against the source records. `InvalidSessionAssigned` matches the pinned missing-ID diagnostic in a 10-minute window, with a one-minute pending period. The older `DICOMValidationFailureSpike` counts more than 10 lines matching `invalid` or `validation.*fail` in one hour, held for five minutes; the missing-ID error matches through `__invalid__` in its saved path, but other invalid warnings also count, so this is neither an exact missing-ID error count nor a distinct-session count. Both require a running Loki ruler and collected assign logs. |
| Secret missing at install | Pod can remain in `CreateContainerConfigError` or a mount failure; inspect Kubernetes events for the missing Secret or key | `install.sh` applies `sites/<site>/secrets.enc.yaml` *before* the chart, deliberately in that order |
| XNAT login fails | upload pod crashes / errors | check the `xnat-credentials` Secret; Use credentials accepted by password-based XNAT REST authentication; a browser-only AAF/OIDC identity is not sufficient |
| XNAT down | Output accumulates in `/data/deidentified`, or `/data/packaged` when packaging is on | Check direct-upload logs, current delivery alerts and free disk. The retained source is retried; a quiet log or a later success line does not prove that a conflicting resource was repaired. |
| stages given different volumes | a stage reads an empty dir | every stage mounts the ONE `<release>-pipeline` claim at `/data`; that is a chart invariant, not a per-pod setting to keep in step |
| cross-filesystem hardlink | `group-orthanc` fails with `EXDEV`, or `hardlink_or_copy` silently degrades to a full byte copy of every study | keep `/data/orthanc-storage`, `/data/grouped` and `/data/assigned` on the one volume — which is why they are subdirectories of a single claim |
| group/assign pod restarts | in-flight stage interrupted; resumes on next loop | The quiet period reduces incomplete input, but late arrivals remain possible. Verify snapshot labels, stage errors, and the next pass rather than treating the wait as a completeness guarantee |
| A writer pass stops or its pod is killed | the pass stops; its lock goes with it | The kernel releases a `flock` when the last process that holds it stops, so the next pass can take it. A child process that a pass leaves keeps the lock until that child stops |
| A custom ready-label filter is added to the running group command | Selection now depends on a configured stable-study label callback, which need not be loaded under ingest | Keep the chart-derived arguments. Ingest clears this filter even though the backup-loaded Lua script can still label stable studies. Inspect the rendered Deployment and callback settings. |
| Assigned reclaim is set to `onUploaded` under ingest | Assigned is an intermediate tree, not the upload source | Use `auto`, which resolves to `onDeidentified`. The terminal tree is verified by the direct-upload staged reclaimer. Do not disable its writer lock or XNAT checks to clear a backlog. |

## Replacements / future

- **DICOMweb (STOW-RS)** receiver — modern alternative to C-STORE; HTTPS-native.
- **Custom Python service**; only worth doing if we outgrow accessionflow; AIS
  keeps adding features upstream, so generally a bad bet.

## Future enhancements (NOT YET implemented, candidate upstream PRs)

- **Native `prometheus_client` metrics** at `:9090/metrics`: counters like
  `xnat_ingest_files_received_total`, `xnat_ingest_sessions_staged_total`, and
  upload-duration histograms. Vector forwards logs to Loki; its removed
  log-to-metric exporter does not create these counters. LogQL can count
  observed events and unwrap numeric durations, but those are not native
  Prometheus histogram buckets or exact counts of delivered sessions.
- **Custom pipeline-event names** in log lines (an `event` field with values like
  `session_staged`, `xnat_upload_completed`) to reduce fragile text matching.
  Version 0.20.0 already emits selected structured events, including
  `xnat_identity_adoption` and `xnat_repair_completed`; broader coverage is
  still a proposal, not an absence of all event names.
- **Structured DICOM SHA256** in the staging-event log for end-to-end integrity
  verification against XNAT.

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
