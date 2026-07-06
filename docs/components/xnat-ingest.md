# xnat-ingest

## Overview

[xnat-ingest](https://github.com/Australian-Imaging-Service/xnat-ingest)
is the AIS-maintained Python tool that:
1. **Sorts** DICOM files into an XNAT project/subject/session/scan hierarchy and
   stages them as a structured directory
2. **Uploads** staged sessions to an XNAT server via REST

We run it as two pods on the single node:
- **`xnat-ingest sort`** (namespace `xnat-ingest`) — REST-pulls de-identified
  studies from Orthanc and hardlinks them into staging
- **`xnat-ingest upload`** (namespace `xnat-upload`) — reads the LOCAL staging
  directory and uploads sessions to XNAT

There is **no S3 hop**. Sort writes to a local directory and upload reads that
same local directory directly.

## Role in this stack

The DICOM ingest engine downstream of Orthanc.

- **sort** polls Orthanc's REST API on the node
  (`http://orthanc.xnat-ingest.svc.cluster.local:8042`), selects studies labelled
  `xnat-ingest-ready` (and not yet `xnat-ingest-skip`), and hardlinks the deid'd
  instances from Orthanc's storage tree (`/data/orthanc-storage`) into
  `/data/staging/<project>.<subject>.<visit>/`. Same filesystem ⇒ hardlink, not
  copy. It then labels the study `xnat-ingest-skip` so later cycles skip it.
- **upload** reads that same `/data/staging` directory (both pods mount the host
  dir `/data/xnat-ingest` at `/data`) and pushes each session to XNAT over HTTPS.

## What xnat-ingest has access to

### sort pod (`xnat-ingest` namespace)
- **hostPath `/data/xnat-ingest`** mounted at `/data` — reads
  `/data/orthanc-storage`, writes `/data/staging`
- **Orthanc REST API** in-cluster at
  `http://orthanc.xnat-ingest.svc.cluster.local:8042` (to list labelled studies)
- **No XNAT credentials** — sort doesn't talk to XNAT

### upload pod (`xnat-upload` namespace)
- **hostPath `/data/xnat-ingest`** mounted at `/data` — reads `/data/staging`
  (the SAME host directory sort writes to; the mount must be byte-identical or
  upload sees an empty dir)
- **Outbound HTTPS** to the configured XNAT server
- **One Secret** `xnat-credentials` — server URL, username, password

## Where it runs

| Pod | Namespace | Image |
|---|---|---|
| `xnat-ingest-sort` | `xnat-ingest` | `${XNAT_INGEST_IMAGE}` (default `ghcr.io/akshitbeniwal/xnat-ingest:v5`) |
| `xnat-ingest-upload` | `xnat-upload` | same `${XNAT_INGEST_IMAGE}` |

`XNAT_INGEST_IMAGE` points at our fork on `ghcr.io`, which adds JSON log output
(`AIS_LOG_FORMAT=json`), the Orthanc REST-pull sort mode, and a local-filesystem
upload source (the first positional arg to `upload` is a local path, not an
`s3://` URL). Override it in `config/management.env` to switch (e.g. to upstream
once these land there).

## Configuration

| File | Purpose |
|---|---|
| `manifests/01-management/xnat-upload.yaml.tpl` | upload Deployment + `xnat-credentials` Secret, `AIS_LOG_FORMAT=json` |
| `manifests/02-edge/xnat-ingest.yaml.tpl` | sort Deployment (Orthanc REST-pull mode) |
| `scripts/04-deploy-xnat-upload.sh` | apply upload Deployment |
| `scripts/07-deploy-edge-ingest.sh` | apply sort Deployment |
| `config/management.env` | `XNAT_URL`, `XNAT_USER`, `XNAT_PASS`, `PROJECT_ID`, `INGEST_LOOP_SECONDS`, `INGEST_WAIT_PERIOD`, `XNAT_INGEST_IMAGE` |

### sort arguments

```
xnat-ingest sort /data/staging
  --orthanc-url          http://orthanc.xnat-ingest.svc.cluster.local:8042
  --orthanc-storage-dir  /data/orthanc-storage
  --orthanc-label        xnat-ingest-ready   # only consider studies with this label
  --orthanc-skip-label   xnat-ingest-skip    # skip studies already staged
  --project-id           ${PROJECT_ID}
  --loop                 ${INGEST_LOOP_SECONDS}
  --wait-period          ${INGEST_WAIT_PERIOD}
```

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
  unset, so the upstream image still works.
- `XINGEST_HOST/USER/PASS` (upload pod only) — XNAT REST credentials, sourced from
  the `xnat-credentials` Secret.

## Operations

```bash
# Sort logs (JSON when AIS_LOG_FORMAT=json)
kubectl logs -n xnat-ingest -l component=sort -f | jq

# Upload logs
kubectl logs -n xnat-upload -l component=upload -f | jq

# Inspect the local staging directory on the node
sudo ls -R /data/xnat-ingest/staging/

# Manually promote an invalid session to test upload
sudo mv /data/xnat-ingest/staging/__invalid__/<dir> \
        /data/xnat-ingest/staging/<project>.<subject>.<visit>
```

## Benefits

- **Battle-tested DICOM parsing** — handles edge cases (missing
  AccessionNumber, multi-frame, multi-series) we don't want to re-implement
- **Idempotent** — re-running upload skips sessions already in XNAT
- **Loop mode** — runs continuously; new studies are staged and uploaded as they
  arrive
- **Connection-resilience** (in our fork) — transient network errors don't kill
  the upload loop

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| DICOM missing AccessionNumber | Session routed to `/data/staging/__invalid__/` | Manual rename + move; `DICOMValidationFailureSpike` alert fires when this happens >10x/h |
| XNAT login fails | upload pod crashes / errors | check `xnat-credentials` Secret; XNAT user must be a local account, not AAF/OIDC |
| XNAT down | uploads fail; staged sessions accumulate in `/data/staging` | `XNATBacklogGrowing` alert; upload loop clears the backlog when XNAT returns |
| sort and upload mount different dirs | upload reads an empty dir | both mount host `/data/xnat-ingest` at `/data`; keep them identical |
| cross-filesystem hardlink | sort fails with `EXDEV` | keep `/data/orthanc-storage` and `/data/staging` on one physical mount |
| Sort pod restarts | in-flight stage interrupted; resumes on next loop | `--wait-period` avoids staging half-written studies |

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
