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
We run them as three pods on the single node:
- **`xnat-ingest group-orthanc`** (namespace `xnat-ingest`, `component=group`) —
  REST-pulls de-identified studies from Orthanc and hardlinks them into
  `/data/grouped`
- **`xnat-ingest assign`** (namespace `xnat-ingest`, `component=assign`) — reads
  `/data/grouped`, assigns project/subject/session IDs, and collates into
  `/data/staging`
- **`xnat-ingest upload`** (namespace `xnat-upload`, `component=upload`) — reads
  the LOCAL staging directory and uploads sessions to XNAT

There is **no S3 hop**. Every stage reads and writes local directories on one
shared filesystem; upload reads the same `/data/staging` that `assign` wrote.

## Role in this stack

The DICOM ingest engine downstream of Orthanc.

- **group-orthanc** polls Orthanc's REST API on the node
  (`http://orthanc.xnat-ingest.svc.cluster.local:8042`), selects studies labelled
  `xnat-ingest-ready` (and not yet `xnat-ingest-processed`), and hardlinks the
  deid'd instances from Orthanc's storage tree (`/data/orthanc-storage`) into
  grouped studies under `/data/grouped`. Same filesystem ⇒ hardlink, not copy. It
  then labels the study `xnat-ingest-processed` so later cycles skip it.
- **assign** reads `/data/grouped`, derives the XNAT project/subject/session IDs
  from the DICOM clinical-trial tags the Orthanc deid hook writes, and collates
  each study into `/data/staging/<project>.<subject>.<session>/`. Project comes
  from `ClinicalTrialProtocolID` (= the `routing.json` AETMap entry for the
  sending AET), subject from `ClinicalTrialSubjectID`, session from
  `ClinicalTrialTimePointID` — no hardcoded project constant.
- **upload** reads that same `/data/staging` directory (all pods mount the host
  dir `/data/xnat-ingest` at `/data`) and pushes each session to XNAT over HTTPS.

## What xnat-ingest has access to

### group pod (`xnat-ingest` namespace, `component=group`)
- **hostPath `/data/xnat-ingest`** mounted at `/data` — reads
  `/data/orthanc-storage`, writes `/data/grouped`
- **Orthanc REST API** in-cluster at
  `http://orthanc.xnat-ingest.svc.cluster.local:8042` (to list labelled studies
  and pull instances)
- **No XNAT credentials** — group-orthanc doesn't talk to XNAT

### assign pod (`xnat-ingest` namespace, `component=assign`)
- **hostPath `/data/xnat-ingest`** mounted at `/data` — reads `/data/grouped`,
  writes `/data/staging`
- **No Orthanc or XNAT access** — it only reshapes local directories

### upload pod (`xnat-upload` namespace, `component=upload`)
- **hostPath `/data/xnat-ingest`** mounted at `/data` — reads `/data/staging`
  (the SAME host directory `assign` writes to; the mount must be byte-identical or
  upload sees an empty dir)
- **Outbound HTTPS** to the configured XNAT server
- **One Secret** `xnat-credentials` — server URL, username, password

## Where it runs

| Pod | Namespace | Image |
|---|---|---|
| `xnat-ingest-group` | `xnat-ingest` | `${XNAT_INGEST_IMAGE}` (default `ghcr.io/australian-imaging-service/xnat-ingest:0.12.3`) |
| `xnat-ingest-assign` | `xnat-ingest` | same `${XNAT_INGEST_IMAGE}` |
| `xnat-ingest-upload` | `xnat-upload` | same `${XNAT_INGEST_IMAGE}` |

`XNAT_INGEST_IMAGE` points at the **upstream** image on `ghcr.io` — all the
AIS-Edge changes (JSON log output via `AIS_LOG_FORMAT=json`, the `group-orthanc`
Orthanc REST-pull, the `assign` ID-assignment stage, and a local-filesystem
upload source where the first positional arg to `upload` is a local path, not an
`s3://` URL) are now merged upstream. Override the tag in `config/management.env`
to pin or bump the version.

## Configuration

| File | Purpose |
|---|---|
| `manifests/01-management/xnat-upload.yaml.tpl` | upload Deployment + `xnat-credentials` Secret, `AIS_LOG_FORMAT=json` |
| `manifests/02-edge/xnat-ingest.yaml.tpl` | group + assign Deployments (Orthanc REST-pull → staging) |
| `scripts/04-deploy-xnat-upload.sh` | apply upload Deployment |
| `scripts/07-deploy-edge-ingest.sh` | apply group + assign Deployments |
| `config/management.env` | `XNAT_URL`, `XNAT_USER`, `XNAT_PASS`, `INGEST_LOOP_SECONDS`, `INGEST_WAIT_PERIOD`, `XNAT_INGEST_IMAGE` (project comes from `routing.json`) |

### group-orthanc arguments

```
xnat-ingest group-orthanc \
  http://orthanc.xnat-ingest.svc.cluster.local:8042   # Orthanc REST URL
  /data/orthanc-storage                               # Orthanc storage dir (as mounted)
  /data/grouped                                       # output: grouped studies
  orthanc orthanc                                     # Orthanc user / password (auth disabled)
  --to-process-label   xnat-ingest-ready              # only pull studies with this label
  --processed-label    xnat-ingest-processed          # label applied after pulling (skip next cycle)
  --loop               ${INGEST_LOOP_SECONDS}
  --wait-period        ${INGEST_WAIT_PERIOD}
```

### assign arguments

```
xnat-ingest assign \
  /data/grouped                          # input: group-orthanc output
  /data/staging                          # output: upload reads this
  --project  ClinicalTrialProtocolID     # project from the deid-written tag
  --subject  ClinicalTrialSubjectID      # subject hash
  --session  ClinicalTrialTimePointID    # session hash
  --loop     ${INGEST_LOOP_SECONDS}
```

The `ClinicalTrial*` tags are written by the Orthanc deid hook
(`ClinicalTrialProtocolID` = project, `ClinicalTrialSubjectID` = SubjectHash,
`ClinicalTrialTimePointID` = SessionHash), so `assign` reads them directly — the
project comes from `routing.json`, not a config constant. IDs are normalised to
`[A-Za-z0-9_]`, so keep XNAT project IDs in that set (a hyphen becomes `_`).

### upload arguments

```
xnat-ingest upload /data/staging ${XNAT_URL}   # LOCAL source dir (no s3://)
  --always-include        all
  --loop                  60
  --dont-require-manifest
  --dont-verify-ssl       # XNAT presents a private/self-signed cert
```

Important env vars:
- `AIS_LOG_FORMAT=json` — enable JSON log output (one object per line) so Vector
  indexes `ts/level/logger/message/event` without regex parsing. Drops to text if
  unset, so the image still works without it.
- `XINGEST_HOST/USER/PASS` (upload pod only) — XNAT REST credentials, sourced from
  the `xnat-credentials` Secret.

## Operations

```bash
# Group + assign logs (JSON when AIS_LOG_FORMAT=json)
kubectl logs -n xnat-ingest -l component=group  -f | jq
kubectl logs -n xnat-ingest -l component=assign -f | jq

# Upload logs
kubectl logs -n xnat-upload -l component=upload -f | jq

# Inspect the local staging directory on the node
sudo ls -R /data/xnat-ingest/staging/

# Manually promote an invalid session to test upload
sudo mv /data/xnat-ingest/staging/__invalid__/<dir> \
        /data/xnat-ingest/staging/<project>.<subject>.<session>
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
| DICOM missing AccessionNumber | `assign` routes the session to `/data/staging/__invalid__/` | Manual rename + move; `DICOMValidationFailureSpike` alert fires when this happens >10x/h |
| XNAT login fails | upload pod crashes / errors | check `xnat-credentials` Secret; XNAT user must be a local account, not AAF/OIDC |
| XNAT down | uploads fail; staged sessions accumulate in `/data/staging` | `XNATBacklogGrowing` alert; upload loop clears the backlog when XNAT returns |
| stages mount different dirs | a stage reads an empty dir | all pods mount host `/data/xnat-ingest` at `/data`; keep them identical |
| cross-filesystem hardlink | `group-orthanc` fails with `EXDEV` | keep `/data/orthanc-storage`, `/data/grouped`, and `/data/staging` on one physical mount |
| group/assign pod restarts | in-flight stage interrupted; resumes on next loop | `--wait-period` avoids grouping half-written studies |

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
</content>
</invoke>
