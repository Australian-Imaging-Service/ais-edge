# Grafana dashboards — what every panel measures

There are three dashboards under the `AIS Edge` folder in Grafana, all loaded
from ConfigMaps in `manifests/01-management/observability/dashboards/` via
the Grafana sidecar. This document is the authoritative reference for what
each panel means, what query backs it, and how to interpret the value.

For each panel: the **title** is what the site admin reads; the **query** is
what the panel actually computes; the **field semantics** are why those two
match.

In this single-node deployment the panels are driven by the structured JSON log
events emitted by the pipeline pods: `xnat-ingest group-orthanc`/`assign`
(`component=group`/`component=assign`) and the
`xnat-ingest upload` pod (`component=upload`). The **upload events now come from
the direct XNAT upload pod** — there is no s3-uploader / SeaweedFS layer anymore.
Vector parses the JSON and pushes it to Loki, and every panel is a LogQL query
over that stream.

## The pipeline event fields

The upload pod emits one JSON line per session state change with `AIS_LOG_FORMAT=json`:

```jsonc
{
  "ts":         "2026-05-14T07:16:50+00:00",
  "component":  "upload",
  "cluster":    "mgmt",
  "event":      "upload_completed",    // or upload_started | upload_failed
  "session":    "test-project.subject-04.visit01",
  "message":    "",                    // human-readable; can be empty
  "level":      "INFO"
}
```

`xnat-ingest assign` emits its own JSON lines (staging progress, and per-session
`ERROR` lines for sessions routed to `__invalid__/`); `group-orthanc` emits
REST-pull / grouping lines. The dashboards count both event streams by
`event` / `component` / `cluster`.

Where a panel historically split `dicoms` vs `files` (the s3-uploader's
per-object counters), tier-1 counts **sessions** via `count_over_time` on
`event="upload_completed"` instead — one completed upload = one session finished.

---

## Pipeline Overview (`ais-pipeline-overview`)

Single-node view over every pipeline event pushed to Loki.

### Row 1 — Headline counters (last 1 hour)

| Panel | Query | What it measures |
|---|---|---|
| **Sessions uploaded (last 1h)** | `count_over_time({namespace="xnat-upload",component="upload"} \| json \| event="upload_completed" [1h])` | Count of `upload_completed` log lines from the XNAT upload pod = count of sessions successfully pushed to XNAT in the last hour. |
| **Upload failures (last 1h)** | `count_over_time(... event="upload_failed" [1h])` | Count of `upload_failed` events. Should be a steady 0 in normal operation. Empty result renders as 0 via `noValue: "0"`. |

### Row 2 — Pipeline-health counters

| Panel | Query | What it measures |
|---|---|---|
| **Invalid sessions (last 1h)** | `count_over_time(... level="ERROR" \| message =~ "^Invalid IDs found.*" [1h])` | Sessions xnat-ingest assign routed to `/data/staging/__invalid__/` because the DICOM metadata is missing required fields (typically AccessionNumber). Each invalid session contributes exactly 1 (we anchor on the per-session error message and ignore the secondary "Staging completed with N errors" summary line that repeats the same content). |
| **Assign cycles with errors (last 1h)** | `count_over_time(... message =~ "(?s)^Staging completed with.*" [1h])` | Per-cycle counter: each xnat-ingest assign loop that ended with ≥1 error logs a single summary line. Counting that line gives one tick per failed cycle, regardless of how many sessions were rejected within it. The `(?s)` flag makes `.` match the newlines that follow the colon in the multi-line summary. |
| **Pipeline liveness** | `count_over_time({namespace="xnat-ingest",component="assign"}[1h]) > 0` | Non-zero when the assign loop is logging = the pipeline is alive. 0 means assign has stopped emitting (pod down or crash-looping). |

### Logs panel — Recent invalid sessions

LogQL: `{namespace="xnat-ingest",component="assign"} | json | level="ERROR" | message =~ "^Invalid IDs found.*" | line_format "{cluster} — {message}"`

Each line is a session assign placed in `__invalid__/`. Site-admin action: rename the dir to `PROJECT.SUBJECT.SESSION` and move it back to `/data/staging/`.

### Time series

- **Pipeline events per minute (by event type)** — `sum by (event) (count_over_time({namespace="xnat-upload",component="upload"} | json [1m]))`. One line per event type (upload_started, upload_completed, upload_failed). Helpful for spotting bursts of failures or a stuck pipeline.
- **Upload throughput (events/min)** — `count_over_time(... event="upload_completed" [1m])`. Completed uploads per minute.
- **Failure rate (upload_failed / upload_started)** — Division of two 15-min counts, displayed as a percentage. Falls back to `clamp_min(..., 0.001)` to avoid divide-by-zero. Should be flat at 0% in steady state.

### Logs panel — Recent pipeline events

LogQL: `{namespace=~"xnat-ingest|xnat-upload"} | json | event != "" | line_format "[{component}] event={event} session={session} — {message}"`

Last 30 minutes of every structured event from the group, assign, and upload pods, formatted for human reading.

---

## Edge Site Drilldown (`ais-edge-drilldown`)

Single-node / per-worker view selected by the **cluster** and **node** dropdowns
at the top of the dashboard. On a single node there is one `cluster` and one
`node`, so the dropdowns mostly serve to scope the log tail; the dashboard is
retained for layout consistency with multi-node deployments.

- `$cluster` is a Loki query of `label_values(cluster)` — single-select.
- `$node` is a Loki query of `label_values({cluster=$cluster}, node)` — multi-select with `All` defaulting to `.+` regex (matches any).

### Stat row

| Panel | Query (with template vars expanded) | Meaning |
|---|---|---|
| **Completed uploads (last 10m)** | `count_over_time({cluster=X, node=~Y, component="upload"} | json | event="upload_completed" [10m])` | Last-10-min upload count for the selected scope. Threshold: red below 1, green above. 0 with active scanners means the pipeline is stuck. |
| **Assign errors (last 1h)** | Same shape as "Invalid sessions" but scoped | DICOM validation failures. |
| **Upload failures (last 1h)** | Same shape as Pipeline Overview's "Upload failures" but scoped | `upload_failed` count. |

### Time series + log tail

- **Upload events per minute** — `sum by (event) (count_over_time({cluster=X, node=~Y, component="upload"} | json | event != "" [1m]))`. Per-event timeseries for the selected scope.
- **Live log tail** — every line from the group, assign, and upload pods on the selected scope, formatted as `[{component}] event={event} session={session} {message}`.

---

## Session Timeline (`ais-session-timeline`)

Single-session trace. The dashboard variable `session` is a text input — paste a session name (e.g. `test-project.mrbrain.visit01`) and the dashboard shows every log line referencing it across the group, assign, and upload pods.

Query: `{namespace=~"xnat-ingest|xnat-upload"} |= "$session" | json | line_format "{component} | {event} | {message}"`.

Sort order is Ascending so the trace reads top-to-bottom in time order.

Used for forensics after a specific session reports a problem.

---

## How to validate a panel after changing it

Enumerate every panel and run its query against Loki/Prometheus. Workflow:

1. Snapshot **before** the change.
2. Make the change. Drop a single test DICOM with a unique subject name.
3. Predict the delta on every panel.
4. Snapshot **after**.
5. For each panel, `delta == prediction` ⇒ panel is correct.

Any mismatch is a bug — fix the query to match the title (or the title
to match the query). Never accept "the dashboard looks roughly right".
