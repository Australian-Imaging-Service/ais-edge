# xnat-ingest

## Overview

[xnat-ingest](https://github.com/Australian-Imaging-Service/xnat-ingest)
is the AIS-maintained Python tool that:
1. **Groups** DICOM instances into studies by REST-pulling them from Orthanc
   (`group-orthanc`)
2. **Assigns** each study an XNAT project/subject/session identity and stages it
   as a structured directory (`assign`)
3. **Uploads** staged sessions to an XNAT server via REST (`upload`)

Upstream ≥ 0.12 split the old single `sort` command into these discrete stages.
We run them as three Deployments on the single node, all rendered by
`charts/edge`:
- **`xnat-ingest group-orthanc`** (`<release>-group-orthanc`, `component=group`)
  — REST-pulls de-identified studies from Orthanc and hardlinks them into
  `/data/grouped`
- **`xnat-ingest assign`** (`<release>-assign`, `component=assign`) — reads
  `/data/grouped`, assigns project/subject/session IDs, and collates into
  `/data/assigned`
- **`xnat-ingest upload`** (`<release>-upload`, `component=upload`) — reads
  `/data/assigned` and uploads sessions to XNAT

All three run in ONE namespace — `namespace:` in `sites/<site>/values.yaml`,
`xnat-ingest`. Tier-2 splits ingest (edge cluster) from upload (management
cluster) because they are different machines; on one node there is nothing to
split.

Two further stages exist in the chart and are off by default: `group-fs`
(`ingest.fileDrop.enabled` — a watched directory instead of a modality) and
`associate` (`ingest.associate.enabled` — Siemens twix/rda/puls side files).

There is **no S3 hop**: `upload.mode: direct`, and `install.sh` refuses anything
else, because `s3` needs the tier-2 management plane (SeaweedFS, a staging
bucket, a management-side reclaimer) that does not exist here. Every stage reads
and writes directories on one shared volume; upload reads the same
`/data/assigned` that `assign` wrote.

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
| `<release>-group-orthanc` | `xnat-ingest` | `ingest.image.repository:ingest.image.tag` (default `ghcr.io/australian-imaging-service/xnat-ingest:0.12.3`) |
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

### group-orthanc arguments

```
xnat-ingest group-orthanc \
  http://<release>-orthanc.xnat-ingest.svc.cluster.local:8042  # Orthanc REST URL
  /data/orthanc-storage                    # Orthanc storage dir (as mounted)
  /data/grouped                            # output: grouped studies
  $(ORTHANC_USER) $(ORTHANC_PASSWORD)      # orthanc-credentials, or literal orthanc/orthanc when auth is off
  --to-process-label   xnat-ingest-ready         # ingest.orthancGroup.toProcessLabel
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
  --loop           60                    # ingest.assign.interval
```

`--unlink-source all` drops each grouped session once it has been assigned, and
it is not an optimisation. `assign --loop` rebuilds its work list from a live
listing of `/data/grouped` every cycle, so without it the same sessions are
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
  --dont-require-manifest           # rendered when upload.direct.requireManifest = false
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
| DICOM missing AccessionNumber | `assign` routes the session to `/data/assigned/__invalid__/` | Manual rename + move (see Operations); the `DICOMValidationFailureSpike` LogQL alert covers the >10/h case, evaluated by the Loki ruler — so only when `observability.stack.enabled` |
| Secret missing at install | pod sits in `CreateContainerConfigError` with nothing saying why | `install.sh` applies `sites/<site>/secrets.enc.yaml` *before* the chart, deliberately in that order |
| XNAT login fails | upload pod crashes / errors | check the `xnat-credentials` Secret; XNAT user must be a local account, not AAF/OIDC |
| XNAT down | uploads fail; assigned sessions accumulate in `/data/assigned` | `XNATBacklogGrowing` (Loki ruler, same caveat); the upload loop clears the backlog when XNAT returns |
| stages given different volumes | a stage reads an empty dir | every stage mounts the ONE `<release>-pipeline` claim at `/data`; that is a chart invariant, not a per-pod setting to keep in step |
| cross-filesystem hardlink | `group-orthanc` fails with `EXDEV`, or `hardlink_or_copy` silently degrades to a full byte copy of every study | keep `/data/orthanc-storage`, `/data/grouped` and `/data/assigned` on the one volume — which is why they are subdirectories of a single claim |
| group/assign pod restarts | in-flight stage interrupted; resumes on next loop | `--wait-period` avoids grouping half-written studies |
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
