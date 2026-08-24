# xnat-ingest

## Overview

[xnat-ingest](https://github.com/Australian-Imaging-Service/xnat-ingest)
is the AIS-maintained Python tool that turns deid'd DICOMs into
XNAT-ready sessions and uploads them. Upstream **0.13.1** is the pinned
version. The old single `sort` command was split into these stages:
1. **`group-orthanc`** — REST-pulls deid'd studies from Orthanc and
   groups their DICOMs into per-session directories
2. **`assign`** — extracts the XNAT project/subject/session/scan IDs from
   the grouped DICOMs and stages them as a structured directory
3. **`upload`** — pushes staged sessions to an XNAT server via REST

We run these as three xnat-ingest pods, plus one non-xnat-ingest
uploader that carries the sessions between the edge and the management
node:
- **`xnat-ingest group-orthanc`** and **`xnat-ingest assign`** on each
  edge VM
- **`s3-uploader`** on each edge VM — an `rclone copy` loop, not
  xnat-ingest at all (see "Where it runs"). It was `aws s3 sync` until the
  rclone port; `rclone copy` is deliberate, because `rclone sync` deletes at
  the destination and `aws s3 sync` does not
- **`xnat-ingest upload`** on the management node, rendered **once per
  edge site** rather than once for the fleet

> **De-identification is done in Orthanc by default** (the Lua hook), not in
> xnat-ingest. The optional `deidentify` stage is also wired into this chart
> (`ingest.deidentify.enabled`, off by default) — it suits pipelines where
> studies arrive already carrying their project/subject/session identifiers,
> and it writes reversible re-identification metadata, which the Lua hook does
> not. See [choosing-a-deid-engine.md](../choosing-a-deid-engine.md).

## Role in this stack

The DICOM ingest engine. On each edge worker Orthanc receives and
de-identifies studies (see [orthanc.md](orthanc.md)); `group-orthanc`
REST-pulls the studies Orthanc has labelled `xnat-ingest-ready` and
groups their DICOMs into `/data/grouped/<session>/`, then `assign`
produces the `/data/assigned/<project>.<subject>.<visit>/` hierarchy —
`xnat-ingest assign /data/grouped /data/assigned`
(`charts/edge/templates/ingest-pipeline.yaml`), declared as
`dataPolicy.derived.assigned.location` in `charts/edge/values.yaml`.
There is **no `staging/` directory on the edge**: "staged" is the
*S3-side* word for those same sessions once the s3-uploader has synced
them under `s3://<bucket>/staged/`. The management upload pod pulls
from SeaweedFS (an `s3://` source) and pushes to XNAT.

## What xnat-ingest has access to

### group-orthanc + assign pods (edge)
- **The pipeline PVC, mounted at `/data`** — one hostPath-backed claim
  (`storage.pipeline.hostPath: /data/xnat-ingest`) that *every* stage
  mounts at the same path. That is a requirement, not tidiness: the
  stages hardlink between the directories and a hardlink cannot cross a
  filesystem boundary, so splitting them makes `hardlink_or_copy`
  silently degrade to a full byte copy of every study. group-orthanc
  reads `orthanc-storage/` and writes `grouped/`; assign reads
  `grouped/` and writes `assigned/`
- **In-cluster HTTP to Orthanc** — group-orthanc REST-pulls from
  `edge-orthanc.xnat-ingest.svc.cluster.local:8042` (release-prefixed —
  see [orthanc.md](orthanc.md)); assign is purely local filesystem work
- **Orthanc REST credentials** — group-orthanc reads `orthanc-user` and
  `orthanc-password` from the `orthanc-credentials` Secret, because
  Orthanc's API is authenticated (`orthanc.auth.enabled: true` by
  default). If they disagree with the user in that Secret's
  `users.json`, Orthanc answers 401 and the pipeline stalls silently
- **No XNAT credentials** — neither edge stage talks to XNAT

### s3-uploader pod (edge)
- **The same pipeline PVC** — reads `assigned/`, and removes each
  session after a verified sync when
  `dataPolicy.derived.assigned.reclaim: onUploaded`
- **Outbound HTTPS to SeaweedFS** — the `https://seaweedfs.<domain>`
  Ingress on the management node, not the in-cluster Service; it
  therefore needs the CA bundle (`ca-bundle` Secret, key `ca.crt`,
  delivered by the cert-sync CronJob) as `AWS_CA_BUNDLE`
- **One Secret** — `s3-edge-credentials` (`upload.s3.existingSecret`),
  keys `access-key` / `secret-key`, scoped to this site's own bucket

### upload pod (mgmt)
- **In-cluster S3** —
  `http://mgmt-seaweedfs.ais-mgmt.svc.cluster.local:8333` via `boto3`
  honouring the `AWS_ENDPOINT_URL` env var. The address is **derived
  from the release name**, not hardcoded (`mgmt.s3InternalEndpoint` in
  `charts/mgmt/templates/_helpers.tpl`) — the imperative manifest's
  literal `seaweedfs.seaweedfs` broke the moment the release was not
  named `seaweedfs`. Plain http on purpose: this traffic never leaves
  the node, so the custom CA never has to reach this pod
- **Outbound HTTPS** to the configured XNAT server
- **Two Secrets:**
  - `xnat-credentials` (`xnatUpload.xnatSecretRef`) — server URL,
    username, password
  - `seaweedfs-upload` (`xnatUpload.s3SecretRef`, overridable per site
    with `edges[].uploadSecretRef`) — S3 access key/secret. **Not the
    admin identity:** the matching `upload-<edge>` S3 identity is scoped
    to `Read`/`List`/`Write`/`Tagging` on that one edge's bucket
    (`charts/mgmt/templates/seaweedfs.yaml`), so a leaked uploader key
    cannot reach another site's staged imaging. `Write` is what lets it
    delete a staged session once XNAT has confirmed it — SeaweedFS folds
    object DELETE into that action

xnat-ingest has no S3 env-var path of its own: it persists the keys into
its own credential store on first run, so the same two values are also
passed positionally as `--store-credentials $(S3_ACCESS_KEY)
$(S3_SECRET_KEY)`. That is the only way to seed it.

## Where it runs

| Pod | Cluster | Namespace | Image |
|---|---|---|---|
| `edge-group-orthanc` | edge | `xnat-ingest` | `ghcr.io/australian-imaging-service/xnat-ingest:0.13.1` |
| `edge-assign` | edge | `xnat-ingest` | `ghcr.io/australian-imaging-service/xnat-ingest:0.13.1` |
| `edge-s3-uploader` | edge | `xnat-ingest` | `amazon/aws-cli:2.31.19` (NOT xnat-ingest) |
| `mgmt-upload-<edge>` | mgmt | `xnat-upload` | `ghcr.io/australian-imaging-service/xnat-ingest:0.13.1` |

Every name is **release-prefixed** by the chart's `fullname` helper, and
`install.sh` installs the edge chart as release `edge` and the management
chart as release `mgmt` — so the objects are `edge-assign` and
`mgmt-upload-<edge>`, not the bare `xnat-ingest-*` names the imperative
installer used. A site installed under a different release name shifts
all four.

The management uploader is **one Deployment per edge site**, not one for
the fleet. Correctness first: with one staging bucket per site, a single
uploader cannot serve them all, because `xnat-ingest upload` takes
exactly one `s3://bucket/prefix`. Reliability second: a fleet-wide
uploader means one site's poison session, stuck multipart or expired
credential stops delivery for *every* site, and the failures are
indistinguishable because they share one log stream. Per-site uploaders
give per-site isolation, per-site alerting via the `edge` label, and let
one site be paused without touching the others. Measured cost of a
single uploader — 231Mi resident, 4m CPU — puts a practical ceiling
around 15 sites on a 16Gi management node.

A site can also skip S3 entirely with `upload.mode: direct`, which
renders `edge-upload` (xnat-ingest `upload` straight from the edge to
XNAT) instead of `edge-s3-uploader` and needs no management plane, no S3
and no CA plumbing. The two modes are mutually exclusive and the chart
refuses to render both — enabling both would push every session into
XNAT twice.

The `0.13.1` tag is the **merged-upstream** AIS build pulled from
`ghcr.io/australian-imaging-service/xnat-ingest` — it replaces the earlier
local fork. The AIS-Edge patch set (including the `AIS_LOG_FORMAT=json`
structured-log output and the `upload --loop` reconnect fix) is now all
upstream, so no local rebuild is needed — and no image-import step
either. Both charts set `imagePullPolicy: IfNotPresent`
(`ingest.image.pullPolicy` in `charts/edge/values.yaml`,
`xnatUpload.image.pullPolicy` in `charts/mgmt/values.yaml`), so each node
pulls the tag from ghcr.io the first time a pod lands on it and reuses
the cached layers afterwards. Nothing in `install.sh` or `scripts/`
side-loads the image into the container runtime. Override the tag via
`xnatUpload.image.tag` in `charts/mgmt/values.yaml` (mgmt side) or
`ingest.image.tag` in `charts/edge/values.yaml` (edge side).

## Configuration

| File | Purpose |
|---|---|
| `charts/mgmt/templates/xnat-upload.yaml` | one upload Deployment per `edges[]` entry, env vars, AIS_LOG_FORMAT=json |
| `charts/edge/templates/ingest-pipeline.yaml` | group-orthanc + assign Deployments, hostAliases |
| `charts/edge/templates/upload.yaml` | the edge uploader — `edge-s3-uploader` (mode `s3`) or `edge-upload` (mode `direct`); exactly one renders |
| `charts/edge/files/s3-uploader.sh` | the `aws s3 sync` loop itself, plus the `jlog()` event schema below. A real file, not inline YAML, so `bash -n` can lint it in CI |
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
  "event":      "upload_completed",    // one of nine — full list below
  "session":    "test-project.subject01.visit01",  // PROJECT.SUBJECT.VISIT
  "message":    "",                    // free-form; empty for the routine events
  "bytes":       538740,               // total session size on disk (du -sb)
  "files":       2,                    // every object uploaded: DICOMs + __MANIFEST__.json + __METADATA__.json
  "dicoms":      1,                    // subset of `files` matching *.dcm / *.DCM
  "duration_s":  0                     // `aws s3 sync` wall time, present on upload_completed and upload_failed
}
```

The nine event names, and what each one means:

| Event | Emitted when |
|---|---|
| `startup` | the loop starts; records endpoint, bucket, prefix and reclaim mode |
| `endpoint_ready` | the `head-bucket` probe succeeded |
| `endpoint_retrying` | probe failed; retrying (12 attempts over 60s) |
| `endpoint_failed` | probe failed 12 times — refuses to enter the upload loop. Message also reports whether a client certificate is configured and readable: with mTLS on the S3 path this probe is what a bad or missing one breaks first, and (measured) the rejection arrives as an HTTP 400/403 that rclone reports as an S3 XML parse failure |
| `upload_started` | a settled session is about to be synced |
| `upload_completed` | `aws s3 sync` exited zero |
| `upload_failed` | `aws s3 sync` exited non-zero; retried next cycle |
| `upload_skipped` | dangling symlinks, or the endpoint went away mid-loop — the local copy is deliberately preserved rather than uploaded incomplete |
| `reclaim_skipped` | uploaded, but `dataPolicy` is disabled or in dry-run, so the local copy stays |

Only **`upload_started`, `upload_completed` and `upload_failed`** are
matched by Loki ruler alerts (`EdgeUploadStalled`, `EdgeUploadsFailing`,
`EdgeUploadRetrying`, `S3ToXNATBacklog`). Renaming one of those disables
its alert *silently* — no error, just a rule that never fires again.
The three `endpoint_*` events are operator diagnostics; they were called
`alias_configured` / `alias_retrying` / `alias_failed` under the old
`minio/mc` implementation, and were renamed because "alias" is an `mc`
concept that does not exist now the client is the AWS CLI. Nothing
matched the old names, which is what made that rename safe.

An already-uploaded, unchanged session emits **nothing at all**. The
uploader fingerprints each session directory and compares it against a
state file under `/data/LOGS/s3-uploader-state/`; a per-cycle "still
fine" event here is exactly what produced two days of duplicate
upload-completed alert mail.

The `dicoms` vs `files` split exists because xnat-ingest assign
auto-generates a `__MANIFEST__.json` per RESOURCE (not per session) and the s3-uploader writes
it to S3 alongside the DICOMs. Dashboards / alerts that want a true
DICOM count must read `dicoms`; ones that want "S3 PUT count" or
"objects written" use `files` — which counts DICOMs **plus**
`__MANIFEST__.json` **plus** `__METADATA__.json`, not just DICOMs and a
manifest. Both are computed straightforwardly in
`charts/edge/files/s3-uploader.sh`:

```bash
files=$(find -L "$session_dir" -type f | wc -l)
dicoms=$(find -L "$session_dir" -type f \( -iname '*.dcm' \) | wc -l)
```

`-L` because the session tree is hardlinks and symlinks into
`orthanc-storage/`, and `-iname` because scanners emit both `.dcm` and
`.DCM`. The `du -a | case`-pattern trick that used to be documented here
was a workaround for `minio/mc`, whose busybox base had no
`find`/`awk`/`grep`/`sed` at all; it went away with the client, since
`amazon/aws-cli` ships full findutils.

## Operations

```bash
# Edge staging logs (JSON if AIS_LOG_FORMAT=json is set)
KUBECONFIG=kubeconfig-edge-dev kubectl logs -n xnat-ingest \
  -l component=group -f | jq    # group-orthanc
KUBECONFIG=kubeconfig-edge-dev kubectl logs -n xnat-ingest \
  -l component=assign -f | jq   # assign

# Edge S3 uploader (aws-cli, not xnat-ingest — one JSON line per event)
KUBECONFIG=kubeconfig-edge-dev kubectl logs -n xnat-ingest \
  -l component=s3-uploader -f | jq

# Upload logs. There is one uploader PER EDGE, so narrow by the `edge`
# label unless you actually want every site interleaved.
kubectl logs -n xnat-upload -l component=upload,edge=edge-dev -f | jq

# Drop a test DICOM on edge (the optional `group (fs)` source watches
# /data/incoming; the normal path is a C-STORE into Orthanc)
ssh ubuntu@<edge-ip> "cp /home/ubuntu/MRBRAIN.DCM /data/xnat-ingest/incoming/"

# Manually rename an invalid session to test promotion. On the host these
# live under the pipeline volume's hostPath, /data/xnat-ingest, which the
# pods see as /data — so /data/assigned is /data/xnat-ingest/assigned.
ssh ubuntu@<edge-ip> "sudo mv /data/xnat-ingest/assigned/__invalid__/<dir> \
                              /data/xnat-ingest/assigned/<project>.<subject>.<visit>"
```

`__invalid__` is one of the reserved directory names the s3-uploader
skips (alongside `__build__` and `__metadata__`), so a session sitting
there is never uploaded — that is what makes the rename a promotion.

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
| Node cannot reach ghcr.io (registry outage, air-gapped site) | New or rescheduled pods sit in `ImagePullBackOff`; already-running pods are unaffected | Both charts use `imagePullPolicy: IfNotPresent`, so a node that has already pulled `0.13.1` keeps starting pods with no registry at all. There is deliberately no image-import step in `install.sh` — a genuinely air-gapped site has to seed the tag into each node's container runtime itself |
| Orthanc REST credentials drift from `users.json` | group-orthanc gets 401 on every poll; studies pile up in Orthanc with nothing failing downstream | All three keys live in one Secret (`orthanc-credentials`) so they are rotated together; the edge chart refuses to render with `orthanc.auth.enabled` and no Secret named |

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

### 3. A benign checksum mismatch logs at ERROR, every loop, until XNAT catches up

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

Not dangerous today: no alert rule matches on log text or level for the
`xnat-upload` namespace (checked — `grep -i "checksum\|already exists"
charts/mgmt/files/loki-ruler-rules.yaml` returns nothing), so this currently
produces noise in `kubectl logs` and nothing else. It is the same trap as
defect 1 above, one severity level worse: an ERROR-labelled line that means
nothing is wrong, re-emitted every loop for as long as the session is
freshly staged. **If anyone ever adds a rule that alerts on `level="ERROR"`
in this namespace without reading the message first, this line will fire it
on every normal upload** — the exact failure mode that made
`OrthancStorageGrowing` and `XNATBacklogGrowing` (deleted this session, see
`docs/TOUR.md` §9.9) look like coverage while measuring nothing.

**Suggested upstream fix.** Either skip the checksum comparison (and this
log line) when XNAT's stored checksum is empty/unset — that state means "not
computed yet", not "computed and different" — or log it at INFO/DEBUG, since
the pass's own outcome is already success.

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
  Today there are no pipeline *metrics* at all. Vector's `log_to_metric`
  transform and its `:9598` Prometheus exporter were removed — the edge
  Vector renders no Service (`charts/edge/templates/vector.yaml`) and the
  mgmt one sets `service: {enabled: false}` — so everything below is
  derived from **log lines** instead: Vector ships the JSON events to
  Loki, and Loki's own ruler counts them
  (`charts/mgmt/files/loki-ruler-rules.yaml`). Counting lines is accurate
  for rates but has no histogram buckets, so upload-duration percentiles
  have no source today.
- **Custom pipeline-event names** in log lines — e.g. an `event` field
  with values `session_staged`, `xnat_upload_completed`, etc.
  Today the upload pod emits free-form messages that Vector can grep
  for keywords; an `event` field would make Loki queries cleaner.
- **Structured DICOM SHA256** in the staging-event log — for
  end-to-end integrity verification against XNAT.

These would be small, additive PRs upstream — none of them require
touching the core group-orthanc / assign / upload logic.
