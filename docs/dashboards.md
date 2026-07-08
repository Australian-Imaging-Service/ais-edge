# Grafana dashboards — what every panel measures

There are four dashboards under the `AIS Edge` folder in Grafana, all loaded
from ConfigMaps in `manifests/01-management/observability/dashboards/` via
the Grafana sidecar. This document is the authoritative reference for what
each panel means, what query backs it, and how to interpret the value.

For each panel: the **title** is what the site admin reads; the **query** is
what the panel actually computes; the **field semantics** are why those two
match.

## The s3-uploader event schema

Every panel relies on the structured JSON events emitted by the edge
s3-uploader (one line per pipeline state change). The shape is fixed by the
bash script in `manifests/02-edge/xnat-ingest.yaml.tpl`:

```jsonc
{
  "ts":         "2026-05-14T07:16:50+00:00",
  "component":  "s3-uploader",
  "edge":       "edge-dev",
  "event":      "upload_completed",    // or upload_started | upload_failed | startup | alias_configured
  "session":    "test-project.subject-04.visit01",
  "message":    "",                    // human-readable; can be empty
  "bytes":       538740,               // total session size on disk via `du -sb`
  "files":       2,                    // count of files staged: DICOMs + manifest + any other metadata
  "dicoms":      1,                    // subset of `files` matching *.dcm / *.DCM
  "duration_s":  0                     // mc-mirror wall time, only on upload_completed / upload_failed
}
```

**dicoms vs files** is the most important distinction:
- **`dicoms`** counts only image files (`.dcm` / `.DCM`). One DICOM dropped
  → `dicoms=1`.
- **`files`** counts every S3 object written. xnat-ingest's assign step
  auto-generates `MANIFEST.json` per session, so a single DICOM drop yields
  `files=2`.

Dashboards expose both as separate panels so neither value is ever
inflated for its title.

---

## Pipeline Overview (`ais-pipeline-overview`)

Cross-cluster view across every edge that's ever pushed logs.

### Row 1 — Headline counters (last 1 hour)

| Panel | Query | What it measures |
|---|---|---|
| **DICOMs uploaded (last 1h)** | `sum(sum_over_time(... event="upload_completed" \| unwrap dicoms [1h]))` | Sum of the `dicoms` field across every successful upload_completed event in the last hour. A single 1-DICOM session contributes 1. Events from before the `dicoms` field existed contribute 0 (the unwrap directive drops events missing the field). |
| **S3 objects uploaded (last 1h)** | `sum(sum_over_time(... event="upload_completed" \| unwrap files [1h]))` | Same shape but uses `files`. Always strictly ≥ DICOMs because of the per-session MANIFEST.json. |
| **Sessions uploaded (last 1h)** | `count_over_time(... event="upload_completed" [1h])` | Count of upload_completed log lines = count of sessions that finished `mc mirror` with exit 0. Each session contains 1 or more DICOMs + 1 MANIFEST.json. |
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

- **Pipeline events per minute (by event type)** — `sum by (event) (count_over_time({namespace="xnat-ingest",component="s3-uploader"} | json [1m]))`. One line per event type (upload_started, upload_completed, upload_failed, startup, alias_configured). Helpful for spotting bursts of failures or stuck pipelines.
- **Per-edge upload throughput (events/min)** — `sum by (cluster) (count_over_time(... event="upload_completed" [1m]))`. One line per edge cluster.
- **Failure rate (upload_failed / upload_started)** — Division of two 15-min counts, displayed as a percentage. Falls back to `clamp_min(..., 0.001)` to avoid divide-by-zero. Should be flat at 0% in steady state.

### Logs panel — Recent pipeline events

LogQL: `{namespace="xnat-ingest"} | json | event != "" | line_format "[{cluster}/{component}] event={event} session={session} duration={duration_s}s files={files} bytes={bytes} — {message}"`

Last 30 minutes of every structured event from any edge, formatted for human reading.

---

## Edge Site Drilldown (`ais-edge-drilldown`)

Per-cluster view selected by the **cluster** and **node** dropdowns at the top of the dashboard.

- `$cluster` is a Loki query of `label_values(cluster)` — single-select; defaults to `edge-dev`.
- `$node` is a Loki query of `label_values({cluster=$cluster}, node)` — multi-select with `All` defaulting to `.+` regex (matches any). Lets you scope to one worker within the selected cluster.

### Stat row

| Panel | Query (with template vars expanded) | Meaning |
|---|---|---|
| **Completed uploads (last 10m, cluster=$cluster / node=$node)** | `count_over_time({cluster=X, node=~Y, component="s3-uploader"} | json | event="upload_completed" [10m])` | Last-10-min upload count for the selected cluster + node. Threshold: red below 1, green above. 0 with active scanners means the pipeline is stuck. |
| **Assign errors (last 1h, cluster=$cluster / node=$node)** | Same shape as "Invalid sessions" but scoped to selected cluster + node | Per-edge view of DICOM validation failures. |
| **Upload failures (last 1h, cluster=$cluster / node=$node)** | Same shape as Pipeline Overview's "Upload failures" but scoped | Per-edge upload_failed count. |

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
`seaweedfs-metrics` Service on port 9324. Loki provides the log tail panel.

| Panel | Query | Meaning |
|---|---|---|
| **S3 LIST requests — ingest-bucket (1h)** | `sum(increase(SeaweedFS_s3_request_total{bucket="ingest-bucket",type="LIST",code="200"}[1h]))` | LIST requests are how `mc mirror` checks "what's already in the bucket". They occur every s3-uploader cycle (~every 30s). Reliable proxy for s3-uploader liveness. |
| **Volume server disk used** | `sum(SeaweedFS_volumeServer_total_disk_size)` | Total bytes on disk across all SeaweedFS volume files. Grows as data lands; SeaweedFS allocates new 30 GiB volumes as needed. |
| **S3 requests/min (last 5m)** | `sum(rate(SeaweedFS_s3_request_total[5m])) * 60` | Rolling 5-min average S3 request rate scaled to per-minute. |
| **Volumes (across all buckets)** | `max(SeaweedFS_volumeServer_volumes{type="volume"})` | Count of SeaweedFS volume files currently allocated. |
| **S3 request rate by HTTP code** | `sum by (code) (rate(SeaweedFS_s3_request_total[5m]))` | One series per response code. A spike in 4xx/5xx indicates client errors or SeaweedFS distress. |
| **S3 request rate by operation type** | `sum by (type) (rate(SeaweedFS_s3_request_total[5m]))` | Same data sliced by request type: PUT (uploads), GET (reads), LIST (catalog), DELETE. Note: SeaweedFS doesn't increment this counter for `mc mirror`'s actual multipart PUT bodies — those bypass the S3-layer counter and go through the volume server directly. So PUT here counts mostly the manifest object, not the DICOMs themselves; for DICOM-arrival accounting use Loki's `dicoms` field instead. |

---

## How to validate a panel after changing it

Use the audit script at `/tmp/audit-panels.py` (rebuilt as needed) — it
enumerates every panel and runs its query against Loki/Prometheus. Workflow:

1. Snapshot **before** the change.
2. Make the change. Drop a single test DICOM with a unique subject name.
3. Predict the delta on every panel.
4. Snapshot **after**.
5. For each panel, `delta == prediction` ⇒ panel is correct.

Any mismatch is a bug — fix the query to match the title (or the title
to match the query). Never accept "the dashboard looks roughly right".
