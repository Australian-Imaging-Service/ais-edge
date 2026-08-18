# Grafana dashboards — what every panel measures

There are four dashboards under the `AIS Edge` folder in Grafana, all loaded
from ConfigMaps in `charts/mgmt/files/dashboards/` via
the Grafana sidecar. This document is the authoritative reference for what
each panel means, what query backs it, and how to interpret the value.

For each panel: the **title** is what the site admin reads; the **query** is
what the panel actually computes; the **field semantics** are why those two
match.

## The s3-uploader event schema

Every panel relies on the structured JSON events emitted by the edge
s3-uploader (one line per pipeline state change). The shape is fixed by the
bash script in `charts/edge/files/s3-uploader.sh`:

```jsonc
{
  "ts":         "2026-05-14T07:16:50+00:00",
  "component":  "s3-uploader",
  "edge":       "edge-dev",
  "event":      "upload_completed",    // one of nine names — see the table below
  "session":    "test-project.subject-04.visit01",
  "message":    "",                    // human-readable; can be empty
  "bytes":       538740,               // total session size on disk via `du -sb`
  "files":       2,                    // objects staged: DICOMs + __MANIFEST__.json per resource + any other metadata
  "dicoms":      1,                    // subset of `files` matching *.dcm / *.DCM
  "duration_s":  0                     // `aws s3 sync` wall time, only on upload_completed / upload_failed
}
```

### Every event name the uploader emits

The `sum by (event)` panels draw one series per name in this table and nothing
filters the set, so a legend entry that is not listed here means the script
grew an event and this page did not. All nine come from `jlog` calls in
`charts/edge/files/s3-uploader.sh`.

| Event | Emitted when | What it tells the operator |
|---|---|---|
| `startup` | Once per container start, before the endpoint pre-flight. | Restart marker. A repeating sawtooth of these is a crashlooping uploader, not a busy one. |
| `endpoint_ready` | The `aws s3api head-bucket` pre-flight succeeded. | Normal path, one per start. Its absence after a `startup` is the whole story. |
| `endpoint_retrying` | A pre-flight attempt failed; retrying in 5s, up to 12 attempts. | Expected for a few seconds during a pod-startup or DNS race; alarming any later. |
| `endpoint_failed` | All 12 attempts failed (60s); the script exits rather than entering the upload loop. | The pod crashloops **on purpose** — a broken endpoint or credential is made visible instead of quietly uploading nothing. Its `message` names the client-certificate state (`no client certificate is configured` / `configured and readable` / `MISSING OR UNREADABLE`), because with mTLS on the upload path this probe is the **first** thing a bad certificate breaks — and (measured) the endpoint answers HTTP 400/403 with an HTML body that rclone reports as an S3 XML parse failure, naming neither certificates nor auth, so it otherwise reads as an unreachable endpoint. The rclone error for each attempt is on stderr, not in this field. |
| `upload_started` | A settled, changed session is about to transfer; carries `bytes`, `files`, `dicoms`. | Denominator of the failure-rate panel. |
| `upload_completed` | `aws s3 sync` exited 0; adds `duration_s`. | The success counter every headline panel sums. |
| `upload_failed` | `aws s3 sync` exited non-zero; adds `duration_s`. Retried next cycle. | Numerator of the failure-rate panel. |
| `upload_skipped` | The session has dangling symlinks, or the re-probe immediately before the transfer failed. | Neither success nor failure: the local copy is deliberately preserved for the next cycle. Sustained `upload_skipped` with no `upload_completed` is a stalled pipeline that the `upload_failed` panels will never show. |
| `reclaim_skipped` | The upload succeeded but `dataPolicy` is in `dryRun`, so the local copy stays. | Expected while previewing reclaim decisions; in steady state it means staging keeps growing after every successful upload. |

An already-uploaded, unchanged session emits **nothing at all** — the
fingerprint check `continue`s silently, because a per-cycle "still fine" event
here is what once produced two days of duplicate upload-completed alert mail.
Quiet panels during a quiet night are therefore correct, not broken.

The `alias_*` names are gone. `alias_configured`, `alias_retrying` and
`alias_failed` became `endpoint_ready`, `endpoint_retrying` and
`endpoint_failed` when the uploader moved from `minio/mc` to the AWS CLI —
"alias" was an `mc` concept with nothing behind it any more. No panel or alert
matched the old names, so nothing broke silently; but a panel description that
still legends `alias_configured` is naming a series that can never appear,
while hiding the `endpoint_*` series that say the S3 endpoint is unreachable.

**dicoms vs files** is the most important distinction:
- **`dicoms`** counts only image files (`.dcm` / `.DCM`). One DICOM dropped
  → `dicoms=1`.
- **`files`** counts every S3 object written. The name is
  `__MANIFEST__.json` (double underscores both sides — that is what
  `charts/mgmt/files/reclaim-staged.sh` matches on), and xnat-ingest's assign
  step generates one **per resource, not per session**; the uploader's own
  schema note lists the objects as "DICOMs + `__MANIFEST__.json` +
  `__METADATA__.json`". So `files - dicoms` is **not** a fixed 1: a
  single-resource session sits near it, a multi-resource session carries a
  manifest each. Do not reconcile the DICOMs and S3-objects tiles by assuming
  "dicoms + 1" — the mismatch is the schema, not a lost object.

Dashboards expose both as separate panels so neither value is ever
inflated for its title.

---

## Pipeline Overview (`ais-pipeline-overview`)

Cross-cluster view across every edge that's ever pushed logs.

### Row 1 — Headline counters (last 1 hour)

| Panel | Query | What it measures |
|---|---|---|
| **DICOMs uploaded (last 1h)** | `sum(sum_over_time(... event="upload_completed" \| unwrap dicoms [1h]))` | Sum of the `dicoms` field across every successful upload_completed event in the last hour. A single 1-DICOM session contributes 1. Events from before the `dicoms` field existed contribute 0 (the unwrap directive drops events missing the field). |
| **S3 objects uploaded (last 1h)** | `sum(sum_over_time(... event="upload_completed" \| unwrap files [1h]))` | Same shape but uses `files`. Always ≥ DICOMs, because every session also ships at least one `__MANIFEST__.json` — one per resource — plus its metadata object. The gap between this tile and the DICOMs tile is that overhead, not a discrepancy. |
| **Sessions uploaded (last 1h)** | `count_over_time(... event="upload_completed" [1h])` | Count of upload_completed log lines = count of sessions whose `aws s3 sync` exited 0. Each session contains 1 or more DICOMs plus a `__MANIFEST__.json` per resource. |
| **Upload failures (last 1h)** | `count_over_time(... event="upload_failed" [1h])` | Count of upload_failed events. Should be a steady 0 in normal operation. Empty result renders as 0 via `noValue: "0"`. |

### Row 2 — Pipeline-health counters

| Panel | Query | What it measures |
|---|---|---|
| **Invalid sessions (last 1h)** | `count_over_time(... level="ERROR" \| message =~ "^Invalid IDs found.*" [1h])` | Sessions xnat-ingest assign routed to `/data/staging/__invalid__/` because the DICOM metadata is missing required fields (typically AccessionNumber). Each invalid session contributes exactly 1 (we anchor on the per-session error message and ignore the secondary "Staging completed with N errors" summary line that repeats the same content). |
| **Assign cycles with errors (last 1h)** | `count_over_time(... message =~ "(?s)^Staging completed with.*" [1h])` | Per-cycle counter: each xnat-ingest assign loop that ended with ≥1 error logs a single summary line. Counting that line gives one tick per failed cycle, regardless of how many sessions were rejected within it. The `(?s)` flag makes `.` match the newlines that follow the colon in the multi-line summary. |
| **Active edge sites** | `count(count by (cluster) (count_over_time({cluster!="",cluster!="mgmt"}[1h])))` | Distinct non-mgmt cluster labels seen in Loki in the last hour. 1 when only edge-dev is shipping; grows by 1 per additional edge. |

### Logs panel — Recent invalid sessions

LogQL: `{namespace="xnat-ingest",component="assign"} | json | level="ERROR" | message =~ "^Invalid IDs found.*" | line_format "{cluster} — {message}"`

Each line is a session that assign placed in `__invalid__/`. Site-admin action: rename the dir to `PROJECT.SUBJECT.VISIT` and move it back to `/data/staging/`.

### Time series

- **Pipeline events per minute (by event type)** — `sum by (event) (count_over_time({namespace="xnat-ingest",component="s3-uploader"} | json [1m]))`. There is no event filter in that query, so the legend carries **every** name in the table above: `startup`, `endpoint_ready`, `endpoint_retrying`, `endpoint_failed`, `upload_started`, `upload_completed`, `upload_failed`, `upload_skipped`, `reclaim_skipped`. Helpful for spotting bursts of failures or stuck pipelines — and it is the only panel where the `endpoint_*` series appear, which is what a site sees when the S3 endpoint or its credential is broken rather than the pipeline itself.
- **Per-edge upload throughput (events/min)** — `sum by (cluster) (count_over_time(... event="upload_completed" [1m]))`. One line per edge cluster.
- **Failure rate (upload_failed / upload_started)** — Division of two 15-min counts, displayed as a percentage. Falls back to `clamp_min(..., 0.001)` to avoid divide-by-zero. Should be flat at 0% in steady state.

### Logs panel — Recent pipeline events

LogQL: `{namespace="xnat-ingest"} | json | event != "" | line_format "[{cluster}/{component}] event={event} session={session} duration={duration_s}s files={files} bytes={bytes} — {message}"`

Last 30 minutes of every structured event from any edge, formatted for human reading.

---

## Edge Site Drilldown (`ais-edge-drilldown`)

Per-cluster view selected by the **cluster** and **node** dropdowns at the top of the dashboard.

- `$cluster` is a Loki query of `label_values(cluster)` — single-select; defaults to `edge-dev`.
- `$node` is a Loki query of `label_values({cluster=$cluster}, node)` — single-select (`"multi": false`) with an `All` option whose `allValue` is the `.+` regex, so "All" matches any node rather than expanding to a list. Every panel selects it as `node=~"$node"`, which is why the regex form is required. Lets you scope to one worker within the selected cluster.

### Stat row

| Panel | Query (with template vars expanded) | Meaning |
|---|---|---|
| **Completed uploads (last 10m, cluster=$cluster / node=$node)** | `count_over_time({cluster=X, node=~Y, component="s3-uploader"} | json | event="upload_completed" [10m])` | Last-10-min upload count for the selected cluster + node. Threshold: red below 1, green above. 0 with active scanners means the pipeline is stuck. |
| **Assign errors (last 1h, cluster=$cluster / node=$node)** | Same shape as "Invalid sessions" but scoped to selected cluster + node | Per-edge view of DICOM validation failures. |
| **Upload failures (last 1h, cluster=$cluster / node=$node)** | Same shape as Pipeline Overview's "Upload failures" but scoped | Per-edge upload_failed count. |
| **DICOM rejected — unmapped AE title (last 1h, cluster=$cluster / node=$node)** | `sum(count_over_time({cluster=X, node=~Y, app="orthanc"} \|~ "REJECT: no project mapped for CalledAET" [1h])) or vector(0)` | **The silent-data-loss tile.** Orthanc's deid hook looks the calling AE title up in `routing.json`'s AETMap; if it is absent the instance is logged with this string and deleted, while the scanner still receives a DICOM-level C-STORE SUCCESS. So the modality believes the study was delivered and it never reaches XNAT. Anything above 0 means a newly commissioned scanner, a re-imaged console back on its default AE title, or a typo in the AET. Note the selector is `app="orthanc"`, not `component=`, and it is a line filter on Orthanc's raw output rather than a JSON `event` — this is the one drilldown panel that does not read the uploader's schema. Same signal as the `DICOMRejectedUnmappedAET` alert in `charts/mgmt/files/loki-ruler-rules.yaml`. |

The previous "Pod restarts" and "Worker NotReady?" panels were querying
Prometheus metrics that don't exist on this datasource — mgmt Prometheus
can't scrape edge clusters across the konnectivity boundary, so those
queries always returned empty. They were replaced with the Loki-derived
equivalents above.

### Time series + log tail

- **Upload events per minute** — `sum by (event) (count_over_time({cluster=X, node=~Y, component="s3-uploader"} | json | event != "" [1m]))`. Per-event timeseries for the selected scope.
- **Live log tail** — every line from any xnat-ingest pod on the selected cluster+node, formatted as `[{component}] event={event} session={session} {message}`.

---

## Session Timeline (`ais-session-timeline`)

Single-session trace. The dashboard variable `session` is a text input — paste a session name (e.g. `test-project.mrbrain.visit01`) and the dashboard shows every log line referencing it across edges and mgmt.

Query: `{namespace="xnat-ingest"} |= "$session" | json | line_format "{cluster} | {component} | {event} | {message}"`.

Sort order is Ascending so the trace reads top-to-bottom in time order.

Used for forensics after a specific session reports a problem.

---

## SeaweedFS Health (`ais-seaweedfs-health`)

Storage-layer view from Prometheus metrics scraped from the
`<release>-seaweedfs-metrics` Service on port 9324 (`charts/mgmt/templates/seaweedfs.yaml`,
selected by the ServiceMonitor on `app: seaweedfs`). That half is correct and
live.

> **The "SeaweedFS log tail" panel on this dashboard is empty on every current
> install, and it is not your cluster's fault.** It selects
> `{namespace="seaweedfs"}`, which was the *imperative installer's* layout. The
> chart puts every SeaweedFS object in the release namespace —
> `namespace: {{ .Release.Namespace }}` throughout `seaweedfs.yaml`, which
> `install.sh` sets to `ais-mgmt` — so that stream label never exists and the
> panel returns nothing rather than erroring. It is the same stale-namespace
> class the chart comments call out elsewhere (a Loki selector that matches
> nothing looks exactly like a component with nothing to say). Until the panel
> is repointed, read SeaweedFS logs in Explore with
> `{cluster="mgmt", app="seaweedfs"}` — mgmt Vector tags every pod with
> `namespace`, `app` and `component` from its pod labels, and the SeaweedFS
> pods carry `app: seaweedfs`, so that selector is release-namespace-independent.

| Panel | Query | Meaning |
|---|---|---|
| **S3 LIST requests — ingest-bucket (1h)** | `sum(increase(SeaweedFS_s3_request_total{bucket="ingest-bucket",type="LIST",code="200"}[1h]))` | Intended as an s3-uploader liveness proxy: LIST is how `aws s3 sync` works out what is already in the bucket, once per uploader cycle (`upload.s3.interval`, default **60s**). **As written it reads 0 forever.** `seaweedfs.perSiteBuckets` defaults to true and both shipped sites set it true, so buckets are named `<bucketPrefix>-<edge>` — `ingest-edge-dev`, not `ingest-bucket`. The literal `ingest-bucket` only exists when `perSiteBuckets` is false (`charts/mgmt/values.yaml`, `seaweedfs.buckets.ingest`). A label that matches nothing and a dead pipeline produce the same tile, which is the failure mode a liveness proxy exists to rule out — so treat this panel as unreadable until its matcher is `bucket=~"ingest-.*"` (or the per-site bucket name), and use Pipeline Overview's upload counters for liveness meanwhile. |
| **Volume server disk used** | `sum(SeaweedFS_volumeServer_total_disk_size)` | Total bytes on disk across all SeaweedFS volume files. Grows as data lands; SeaweedFS allocates new 30 GiB volumes as needed. |
| **S3 requests/min (last 5m)** | `sum(rate(SeaweedFS_s3_request_total[5m])) * 60` | Rolling 5-min average S3 request rate scaled to per-minute. |
| **Volumes (across all buckets)** | `max(SeaweedFS_volumeServer_volumes{type="volume"})` | Count of SeaweedFS volume files currently allocated. |
| **S3 request rate by HTTP code** | `sum by (code) (rate(SeaweedFS_s3_request_total[5m]))` | One series per response code. A spike in 4xx/5xx indicates client errors or SeaweedFS distress. |
| **S3 request rate by operation type** | `sum by (type) (rate(SeaweedFS_s3_request_total[5m]))` | Same data sliced by request type: PUT (uploads), GET (reads), LIST (catalog), DELETE. Caveat on PUT: this counter was measured under the old `minio/mc` uploader and found not to increment for multipart PUT bodies, which bypass the S3-layer counter and reach the volume server directly — so PUT under-counted the DICOMs badly. The uploader is now `aws s3 sync`, whose multipart thresholds and request shape differ, and **nobody has re-measured it since**. Do not read this series as a DICOM count in either direction; for DICOM-arrival accounting use Loki's `dicoms` field, which is counted on the edge before the transfer and does not depend on how the S3 layer accounts for it. |

---

## How to validate a panel after changing it

**There is no panel-audit script in this repo.** Earlier revisions of this page
pointed at `/tmp/audit-panels.py` "rebuilt as needed"; nothing under `scripts/`
generates it and no such file is tracked, so that instruction had nothing to
run. Two real tools cover adjacent ground and neither covers panels:

- `scripts/check-alert-inputs.sh` extracts every metric name the
  PrometheusRules reference and asks the live Prometheus whether each has any
  series — the "does this query have inputs at all" check, but for **alert
  rules**, not dashboards. It is what would have caught the `ingest-bucket`
  matcher above if dashboards were in scope.
- `make ci`'s `runtime-templates` stage asserts that the `line_format`
  templates in the pipeline-overview and edge-drilldown ConfigMaps survive
  Helm rendering — it proves the `{{ }}` reached the cluster verbatim, not
  that any query returns the right number.

So the workflow below is done by hand, against the panel's own datasource in
Grafana **Explore** (paste the panel's query, expand the template variables
yourself). It is unchanged in substance, because the method — predict, then
measure — is what makes a panel trustworthy, not the tool:

1. Snapshot **before** the change: run every affected panel's query in Explore
   over a fixed absolute time range and write the numbers down.
2. Make the change. Drop a single test DICOM with a unique subject name.
3. Predict the delta on every panel, including the ones you did not touch —
   the `files` / `dicoms` split above is exactly where a confident wrong
   prediction shows up.
4. Snapshot **after** over the same absolute range plus the new window.
5. For each panel, `delta == prediction` ⇒ panel is correct.

Any mismatch is a bug — fix the query to match the title (or the title
to match the query). Never accept "the dashboard looks roughly right".
A panel whose selector matches nothing renders a confident `0`, so "no news"
from a dashboard is only good news once you have proved the query can move.
