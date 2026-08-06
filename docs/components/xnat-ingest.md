# xnat-ingest

## Overview

[xnat-ingest](https://github.com/Australian-Imaging-Service/xnat-ingest)
is the AIS-maintained Python tool that turns deid'd DICOMs into
XNAT-ready sessions and uploads them. As of upstream **0.12.3** the old
single `sort` command was split into two edge stages:
1. **`group-orthanc`** — REST-pulls deid'd studies from Orthanc and
   groups their DICOMs into per-session directories
2. **`assign`** — extracts the XNAT project/subject/session/scan IDs from
   the grouped DICOMs and stages them as a structured directory
3. **`upload`** — pushes staged sessions to an XNAT server via REST

We run these as three pods:
- **`xnat-ingest group-orthanc`** and **`xnat-ingest assign`** on each
  edge VM
- **`xnat-ingest upload`** on the management node

> **De-identification is done in Orthanc** (the Lua hook), not in
> xnat-ingest. Upstream 0.12.3 also ships a standalone, optional
> `deidentify` command (project-specific JSON specs + reversible
> re-identification metadata) — this deployment does **not** use it.

## Role in this stack

The DICOM ingest engine. On each edge worker Orthanc receives and
de-identifies studies (see [orthanc.md](orthanc.md)); `group-orthanc`
REST-pulls the studies Orthanc has labelled `xnat-ingest-ready` and
groups their DICOMs into `/data/grouped/<session>/`, then `assign`
produces the `/data/staging/<project>.<subject>.<visit>/` hierarchy. The
s3-uploader mirrors the staged dirs to SeaweedFS, and the management
upload pod pulls from SeaweedFS (an `s3://` source) and pushes to XNAT.

## What xnat-ingest has access to

### group-orthanc + assign pods (edge)
- **hostPath `/data/xnat-ingest/`** — group-orthanc reads
  `orthanc-storage/` and writes `grouped/`; assign reads `grouped/` and
  writes `staging/`
- **In-cluster HTTP to Orthanc** — group-orthanc REST-pulls from
  `orthanc.xnat-ingest.svc.cluster.local:8042`; assign is purely local
  filesystem work
- **No XNAT credentials** — neither edge stage talks to XNAT

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
| `xnat-ingest-group` | edge | `xnat-ingest` | `ghcr.io/australian-imaging-service/xnat-ingest:0.12.3` |
| `xnat-ingest-assign` | edge | `xnat-ingest` | `ghcr.io/australian-imaging-service/xnat-ingest:0.12.3` |
| `s3-uploader` | edge | `xnat-ingest` | `minio/mc:latest` (NOT xnat-ingest) |
| `xnat-ingest-upload` | mgmt | `xnat-upload` | `ghcr.io/australian-imaging-service/xnat-ingest:0.12.3` |

The `0.12.3` tag is the **merged-upstream** AIS build pulled from
`ghcr.io/australian-imaging-service/xnat-ingest` — it replaces the earlier
local fork. The AIS-Edge patch set (including the `AIS_LOG_FORMAT=json`
structured-log output and the `upload --loop` reconnect fix) is now all
upstream, so no local rebuild is needed: the image is pulled directly and
imported into k0s containerd via `ctr image import` on the management host
and each edge worker. Override the tag via `xnatUpload.image.tag` in
`charts/mgmt/values.yaml` (mgmt side) or `ingest.image.tag` in
`charts/edge/values.yaml` (edge side).

## Configuration

| File | Purpose |
|---|---|
| `charts/mgmt/templates/xnat-upload.yaml` | upload Deployment, env vars, AIS_LOG_FORMAT=json |
| `charts/edge/templates/ingest-pipeline.yaml` | group-orthanc + assign + s3-uploader Deployments, hostAliases |
| `install.sh` | installs both charts; cert-sync (CronJob) pushes the CA bundle into each edge |
| `sites/<site>/secrets.enc.yaml` (`xnat-credentials`) | server URL, username, password — SOPS-encrypted |
| `sites/<edge>/values.yaml` (`ingest:`) | per-edge loop intervals; the AET-to-project map is `orthanc.deid.aetMap` in the same file |

Important env vars on each pod:
- `AIS_LOG_FORMAT=json` — enable JSON structured log output (now
  upstream; drops to text format if unset)
- `AWS_ENDPOINT_URL` (upload pod only) — points boto3 at SeaweedFS
- `XINGEST_HOST/USER/PASS` — XNAT REST credentials

### s3-uploader event schema

Every state change in the upload loop emits one JSON line via the
`jlog()` shell helper in `charts/edge/files/s3-uploader.sh`. The
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

The `dicoms` vs `files` split exists because xnat-ingest assign
auto-generates a `__MANIFEST__.json` per RESOURCE (not per session) and the s3-uploader writes
it to S3 alongside the DICOMs. Dashboards / alerts that want a true
DICOM count must read `dicoms`; ones that want "S3 PUT count" or
"objects written" use `files`. Both fields are computed in busybox-only
bash (no `awk`/`find`/`grep`/`sed` in the minio/mc image): see the
inline comments in the manifest for the `du -a | case`-pattern trick.

## Operations

```bash
# Edge staging logs (JSON if AIS_LOG_FORMAT=json is set)
KUBECONFIG=kubeconfig-edge-dev kubectl logs -n xnat-ingest \
  -l component=group -f | jq    # group-orthanc
KUBECONFIG=kubeconfig-edge-dev kubectl logs -n xnat-ingest \
  -l component=assign -f | jq   # assign

# Upload logs
kubectl logs -n xnat-upload -l component=upload -f | jq

# Drop a test DICOM on edge
ssh ubuntu@<edge-ip> "cp /home/ubuntu/MRBRAIN.DCM /data/xnat-ingest/incoming/"

# Manually rename an invalid session to test promotion
ssh ubuntu@<edge-ip> "sudo mv /data/xnat-ingest/staging/__invalid__/<dir> \
                              /data/xnat-ingest/staging/<project>.<subject>.<visit>"
```

## Benefits

- **DICOM parsing already handles our edge cases** — (missing
  AccessionNumber, multi-frame, multi-series) that we don't want to
  re-implement
- **Idempotent** — re-running upload skips sessions already in XNAT. It really
  does skip the transfer; it just does not *say* so. See "Known upstream
  defects" below before building anything on its log output.
- **Loop mode with label tracking** — group-orthanc marks each pulled
  study `xnat-ingest-processed`, so subsequent loops skip it → no
  double-ingest
- **Connection-resilience patch** (merged upstream) — handles
  transient network errors that previously killed the upload loop

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| DICOM missing AccessionNumber | Routes to `__invalid__/` | Manual rename + move; alert (`DICOMValidationFailureSpike`) fires when this happens >10x/h |
| XNAT login fails | upload pod crashes immediately | check `xnat-credentials` Secret; XNAT user must be a local account, not AAF/OIDC |
| XNAT down or uploader just slow | uploads queue in SeaweedFS; backlog grows | No dedicated backlog-rate alert today — see "Known upstream defects" below. `SessionStagedNotConfirmedInXNAT` (docs/alerting-architecture.md) still catches a session that never lands, just later (minAge + offset) |
| S3 endpoint unreachable from upload pod | uploads fail | `AWS_ENDPOINT_URL` is in-cluster Service DNS — fails only if SeaweedFS pod down |
| group/assign pod restarts | in-flight stage interrupted; resumes on next loop | `--wait-period 60` ensures we don't stage half-written files |
| Image not present in containerd (after teardown) | `imagePullPolicy: Never` causes `ErrImageNeverPull` | `ctr image import` step in install |

## Known upstream defects (candidate reports)

Both were found by measurement on the dev deployment, both are in the uploader,
and both are in the same file as the de-identification issue already raised with
kirsty-UoN. Neither is dangerous — no data is lost or duplicated in XNAT — but
each makes the uploader's output lie about what it did, and anything monitoring
that output inherits the lie.

### 1. The success line is logged on the SKIP path

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

**Suggested upstream fix.** Emit a distinct message on the skip path — e.g.
`Session '<session>' already in XNAT, skipping` — or drop the success line to
debug when nothing was transferred. Either makes the successful-upload line an
event again, which is what every consumer assumes it is.

**It also blocks a real backlog alert.** `XNATBacklogGrowing` tried to measure
"arriving in S3 faster than being pushed to XNAT" by subtracting a count of
this string from a count of edge `upload_completed` events. Because the
string is a level, its count grows with however many sessions are sitting in
static backlog, not with new arrivals in the window — so a genuine backlog
makes the subtraction more negative, not more positive, and the alert could
never fire in the direction it was meant to. Removed rather than shipped as
false coverage; a real version needs the fix above, or a distinct
"session confirmed in XNAT" event with no level-persistence problem.

### 2. The XNAT listing is cached for the lifetime of a `--loop` run

`xnat-ingest upload --loop` opens one XNAT connection and xnatpy caches the
project/experiment listing on it. A connection opened while a session does not
yet exist keeps returning that stale view for the life of the process, so the
uploader cannot see its own writes.

It is a **state** bug, not a logic bug: restarting the pod clears it, and with a
fresh connection the deduplication is correct.

**Operational consequence, worth knowing even if upstream never changes it:** if
you ever clear XNAT by hand, **restart the uploader**. Otherwise it keeps
deciding against a snapshot that no longer matches reality — it will skip
everything staged, and report success while doing it.

**Suggested upstream fix.** Refresh the listing once per loop iteration, or
expose the cache TTL as a flag.

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
touching the core group-orthanc / assign / upload logic.
