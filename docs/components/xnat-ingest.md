# xnat-ingest

## Overview

[xnat-ingest](https://github.com/Australian-Imaging-Service/xnat-ingest)
is the AIS-maintained Python tool that:
1. **Sorts** raw DICOM files dropped on a watch directory into XNAT
   project/subject/session/scan hierarchy and stages them as a
   structured directory
2. **Uploads** staged sessions to an XNAT server via REST

We run it as two separate pods:
- **`xnat-ingest sort`** on each edge VM
- **`xnat-ingest upload`** on the management node

## Role in this stack

The DICOM ingest engine. Edge sites have a `/data/xnat-ingest/incoming/`
drop directory; the sort pod parses metadata and produces a
`/data/staging/<project>.<subject>.<visit>/` hierarchy. The s3-uploader
mirrors the staged dirs to SeaweedFS, and the management upload pod
pulls from SeaweedFS and pushes to XNAT.

## What xnat-ingest has access to

### sort pod (edge)
- **hostPath `/data/xnat-ingest/`** — read incoming, write staging
- **No outbound network** — purely local filesystem work
- **No XNAT credentials** — sort doesn't talk to XNAT

### upload pod (mgmt)
- **In-cluster S3** — `http://seaweedfs.seaweedfs.svc.cluster.local:8333`
  via `boto3` honouring the `AWS_ENDPOINT_URL` env var
- **Outbound HTTPS** to the configured XNAT server
- **Two Secrets:**
  - `xnat-credentials` — server URL, username, password
  - `s3-credentials` — admin S3 access key/secret

## Where it runs

| Pod | Cluster | Namespace | Image |
|---|---|---|---|
| `xnat-ingest-sort` | edge | `xnat-ingest` | `docker.io/library/xnat-ingest:logging-v1` |
| `s3-uploader` | edge | `xnat-ingest` | `minio/mc:latest` (NOT xnat-ingest) |
| `xnat-ingest-upload` | mgmt | `xnat-upload` | `docker.io/library/xnat-ingest:logging-v1` |

The `:logging-v1` tag is our **local fork** with one minimal patch
(JSON log output via `AIS_LOG_FORMAT=json`). The image is built from
the fork at `/home/ubuntu/tmp/xnat-ingest-fork`, exported to a tar via
`docker save`, and imported into k0s containerd via `ctr image import`
on both the management host and each edge worker. See
the upstream PR (in progress) for the full
diff and rebuild instructions.

## Configuration

| File | Purpose |
|---|---|
| `manifests/01-management/xnat-upload.yaml.tpl` | upload Deployment, env vars, AIS_LOG_FORMAT=json |
| `manifests/02-edge/xnat-ingest.yaml.tpl` | sort + s3-uploader Deployments, hostAliases |
| `scripts/04-deploy-xnat-upload.sh` | apply mgmt-side Deployment |
| `scripts/07-deploy-edge-ingest.sh` | apply edge-side Deployments + push CA bundle |
| `config/management.env` | `XNAT_URL`, `XNAT_USER`, `XNAT_PASS` |
| `config/edge-nodes.env` | per-edge `PROJECT_ID`, `INGEST_LOOP_SECONDS`, `INGEST_WAIT_PERIOD` |

Important env vars on each pod:
- `AIS_LOG_FORMAT=json` — enable our fork's JSON log output (drops to
  text format if unset, so the upstream image still works)
- `AWS_ENDPOINT_URL` (upload pod only) — points boto3 at SeaweedFS
- `XINGEST_HOST/USER/PASS` — XNAT REST credentials

### s3-uploader event schema

Every state change in the upload loop emits one JSON line via the
`jlog()` shell helper in `manifests/02-edge/xnat-ingest.yaml.tpl`. The
shape is fixed and is what every Grafana panel + Loki ruler alert reads:

```jsonc
{
  "ts":         "2026-05-14T07:16:50+00:00",
  "component":  "s3-uploader",
  "edge":       "edge-dev",            // CLUSTER_NAME — used as Vector's `cluster` label
  "event":      "upload_completed",    // upload_started | upload_completed | upload_failed | startup | alias_configured
  "session":    "test-project.subject01.visit01",  // PROJECT.SUBJECT.VISIT
  "message":    "",                    // free-form; empty for the routine events
  "bytes":       538740,               // total session size on disk (du -sb)
  "files":       2,                    // count of staged files: DICOMs + manifest + any other per-session metadata
  "dicoms":      1,                    // subset of `files` matching *.dcm / *.DCM
  "duration_s":  0                     // mc-mirror wall time, present on upload_completed and upload_failed
}
```

The `dicoms` vs `files` split exists because xnat-ingest sort
auto-generates a `MANIFEST.json` per session and the s3-uploader writes
it to S3 alongside the DICOMs. Dashboards / alerts that want a true
DICOM count must read `dicoms`; ones that want "S3 PUT count" or
"objects written" use `files`. Both fields are computed in busybox-only
bash (no `awk`/`find`/`grep`/`sed` in the minio/mc image): see the
inline comments in the manifest for the `du -a | case`-pattern trick.

## Operations

```bash
# Sort logs (will be JSON if AIS_LOG_FORMAT=json is set)
KUBECONFIG=kubeconfig-edge-dev kubectl logs -n xnat-ingest \
  -l component=sort -f | jq

# Upload logs
kubectl logs -n xnat-upload -l component=upload -f | jq

# Drop a test DICOM on edge
ssh ubuntu@<edge-ip> "cp /home/ubuntu/MRBRAIN.DCM /data/xnat-ingest/incoming/"

# Manually rename an invalid session to test promotion
ssh ubuntu@<edge-ip> "sudo mv /data/xnat-ingest/staging/__invalid__/<dir> \
                              /data/xnat-ingest/staging/<project>.<subject>.<visit>"
```

## Benefits

- **Battle-tested DICOM parsing** — handles edge cases (missing
  AccessionNumber, multi-frame, multi-series) that we don't want to
  re-implement
- **Idempotent** — re-running upload skips sessions already in XNAT
- **Loop mode with `--delete`** — once staged, source files are
  removed from incoming → no double-upload
- **Connection-resilience patch** (already merged in our fork) — handles
  transient network errors that previously killed the upload loop

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| DICOM missing AccessionNumber | Routes to `__invalid__/` | Manual rename + move; alert (`DICOMValidationFailureSpike`) fires when this happens >10x/h |
| XNAT login fails | upload pod crashes immediately | check `xnat-credentials` Secret; XNAT user must be a local account, not AAF/OIDC |
| XNAT down | uploads queue in SeaweedFS; backlog grows | `XNATBacklogGrowing` alert fires after 30 min |
| S3 endpoint unreachable from upload pod | uploads fail | `AWS_ENDPOINT_URL` is in-cluster Service DNS — fails only if SeaweedFS pod down |
| Sort pod restarts | in-flight stage interrupted; resumes on next loop | `--wait-period 60` ensures we don't stage half-written files |
| Image not present in containerd (after teardown) | `imagePullPolicy: Never` causes `ErrImageNeverPull` | `ctr image import` step in install |

## Replacements / future

- **Orthanc** as a C-STORE listener instead of file-watch (would
  replace the manual scp/cp into incoming); xnat-ingest can sit
  downstream of Orthanc
- **DICOMweb (STOW-RS)** receiver — modern alternative to C-STORE;
  HTTPS-native, plays well with our TLS architecture
- **Custom Python service** — only worth doing if we outgrow xnat-ingest;
  AIS keeps adding features upstream so generally a bad bet

## Future enhancements (NOT YET implemented, candidate upstream PRs)

These are the "nice-to-haves" we considered for the fork but
deliberately scoped out of the current change set:

- **Native `prometheus_client` metrics** at `:9090/metrics`:
  counters like `xnat_ingest_files_received_total`,
  `xnat_ingest_sessions_staged_total`, histograms for upload duration.
  Today we derive these from log-line counts via Vector's `log_to_metric`,
  which is good enough but loses precision (no histogram buckets).
- **Custom pipeline-event names** in log lines — e.g. an `event` field
  with values `session_staged`, `xnat_upload_completed`, etc.
  Today the upload pod emits free-form messages that Vector can grep
  for keywords; an `event` field would make Loki queries cleaner.
- **Structured DICOM SHA256** in the staging-event log — for
  end-to-end integrity verification against XNAT.

These would be small, additive PRs upstream — none of them require
touching `sort.py` or `upload.py` core logic.
