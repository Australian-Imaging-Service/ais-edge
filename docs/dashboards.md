# Grafana dashboards — what every panel measures

Grafana exists on tier-1 only when `observability.stack.enabled: true` in
`sites/<site>/values.yaml`. It comes from the kube-prometheus-stack subchart
vendored at `charts/edge/charts/kube-prometheus-stack-87.19.2.tgz`, and it is
reached on a **NodePort** — `http://<nodeIP>:<observability.stack.grafana.nodePort>`,
default 30030, Service `<release>-grafana` — because a single node has no
ingress and no cert-manager to put one behind.

Three things that Grafana does **not** arrive with, each of which silently
empties every panel below:

* **A Loki datasource.** The subchart provisions Prometheus and Alertmanager
  only (ConfigMap `ais-kps-grafana-datasource`). Every query in this document is
  LogQL, so add Loki at `http://ais-loki.<namespace>.svc.cluster.local:3100`.
  `ais-loki` is pinned by `loki.fullnameOverride` in `charts/edge/values.yaml`
  and is the same address Vector pushes to, so a Vector that is shipping proves
  the URL.
* **The three pipeline dashboards below.** `charts/edge` ships the
  kube-prometheus-stack's own Kubernetes dashboards (ConfigMaps `ais-kps-*`) and
  nothing about the pipeline. Grafana's sidecar watches **every namespace** for
  ConfigMaps labelled `grafana_dashboard: "1"` and loads them into the default
  folder — no folder annotation is configured, so they do not land in a folder of
  their own. That label, and nothing else, is what provisions a dashboard:

  ```bash
  kubectl -n xnat-ingest create configmap ais-dashboard-pipeline-overview \
      --from-file=pipeline-overview.json --dry-run=client -o yaml \
    | kubectl label --local -f - grafana_dashboard=1 -o yaml \
    | kubectl apply -f -
  ```

  This document is the definition of what each panel has to compute; every query
  in it also runs as-is in **Explore**, which is where to confirm one before
  wrapping it in a panel.
* **Logs, if only half the observability switch is on.**
  `observability.stack.enabled` hosts the store; `observability.enabled` runs
  Vector, and `charts/edge/templates/vector.yaml` renders on that second key
  alone. Stack on, shipper off = an empty Loki, a site that reads as idle, and
  no error anywhere.

For each panel: the **title** is what the site admin reads; the **query** is
what the panel actually computes; the **field semantics** are why those two
match.

Tier-1 runs everything in ONE namespace (`namespace:` in the site file,
`xnat-ingest` by default) on ONE node, so the panels are driven entirely by the
pod logs Vector tails there: `group-orthanc`, `assign` and the direct XNAT
uploader. There is no s3-uploader and no SeaweedFS layer on this tier.

---

## The log lines these panels read

Vector (`charts/edge/files/vector-local.yaml`) attaches these Loki **stream
labels**, and every query below selects on them:

`cluster` (= `clusterLabel`), `namespace`, `pod`, `container`, `node`, `app`,
`component`, `level`.

They are load-bearing: `component` in particular is what tells the pipeline
stages apart, and it is copied straight from the pod label the chart sets.

| `component` | pod | rendered when |
|---|---|---|
| `dicom-receiver` | Orthanc | always |
| `group` | `xnat-ingest group-orthanc` | `ingest.orthancGroup.enabled` |
| `group-fs` | `xnat-ingest group` over the watched directory | `ingest.fileDrop.enabled` (off) |
| `assign` | `xnat-ingest assign` | either ingest path enabled |
| `associate` | Siemens side-file attach | `ingest.associate.enabled` (off) |
| `upload` | `xnat-ingest upload` → XNAT | `upload.mode: direct` |
| `data-policy` | the retention reporter | `dataPolicy.reporter.enabled` |

The pipeline pods run with `AIS_LOG_FORMAT=json` (`edge.logEnv` in
`charts/edge/templates/_helpers.tpl`), so each line is one JSON object and
`| json` makes `message` — and, where the stage has one, `session` — queryable
without regexing raw text. `level` is a special case: Vector promotes it out of
the JSON body onto the stream (`remove_label_fields: true` removes it from the
payload), so it is a stream label. `{…,level="ERROR"}` in the selector is the
cheap form; `| json | level="ERROR"` also works, because a label filter reads
stream labels as well as extracted ones.

**There is no `event` field on tier-1, and no panel may depend on one.**
`event=upload_started|upload_completed|upload_failed` is the convention of
`charts/edge/files/s3-uploader.sh`, which only runs under `upload.mode: s3`.
With `upload.mode: direct` the uploader *is* `xnat-ingest upload`, and its one
terminal success signal is the message line:

```
Successfully uploaded all files in '<PROJECT>.<SUBJECT>.<SESSION>'
```

so the counters anchor on that text instead. A panel counting
`event="upload_completed"` here returns nothing, forever, and an empty panel is
indistinguishable from a quiet site — which is the failure this whole document
exists to prevent.

One terminal line = one session finished. Where a multi-site deployment splits
`dicoms` vs `files` (the s3-uploader's per-object counters), tier-1 counts
**sessions**.

---

## Pipeline Overview

Single-node view over every pipeline log line pushed to Loki.

### Row 1 — Headline counters (last 1 hour)

| Panel | Query | What it measures |
|---|---|---|
| **Sessions uploaded (last 1h)** | `sum(count_over_time({namespace="xnat-ingest",component="upload"} \|~ "Successfully uploaded all files in" [1h]))` | One count per session `xnat-ingest upload` confirmed into XNAT in the last hour. Match the string exactly; it is the only terminal signal the uploader emits, so a reworded regex silently reports a dead pipeline. |
| **Upload errors (last 1h)** | `sum(count_over_time({namespace="xnat-ingest",component="upload"} \|~ "(?i)error\|failed\|exception\|traceback" [1h]))` | A LINE count, not a session count — one Python traceback contributes several. Deliberately over-sensitive: the value matters as 0 vs not-0, not as a magnitude. Set the panel's `noValue` to `0`, or an empty result reads "No data" where the operator expects a failure count. |

### Row 2 — Pipeline-health counters

| Panel | Query | What it measures |
|---|---|---|
| **Invalid sessions (last 1h)** | `sum(count_over_time({namespace="xnat-ingest",component="assign"} \| json \| level="ERROR" \| message =~ "^Invalid IDs found.*" [1h]))` | Sessions `assign` routed to `__invalid__/` under its output directory because the DICOM metadata is missing a required field — on this chart that is the three `ClinicalTrial*` tags the de-identification profile writes. Each invalid session contributes exactly 1: we anchor on the per-session error message and ignore the secondary "Staging completed with N errors" summary line, which repeats the same content. |
| **Assign cycles with errors (last 1h)** | `sum(count_over_time({namespace="xnat-ingest",component="assign"} \| json \| message =~ "(?s)^Staging completed with.*" [1h]))` | Per-cycle counter: each `assign` loop that ended with ≥1 error logs a single summary line. Counting that line gives one tick per failed cycle, regardless of how many sessions were rejected within it. The `(?s)` flag makes `.` match the newlines that follow the colon in the multi-line summary. |
| **Pipeline liveness** | `count_over_time({namespace="xnat-ingest",component="assign"}[1h]) > 0` | Non-zero while the assign loop is logging = the pipeline is alive. 0 means assign has stopped emitting (pod down, crash-looping, or Vector not shipping). |

### Logs panel — Recent invalid sessions

LogQL: `{namespace="xnat-ingest",component="assign"} | json | level="ERROR" | message =~ "^Invalid IDs found.*" | line_format "{{.cluster}} — {{.message}}"`

`line_format` is a Go template: `{{.cluster}}`, not `{cluster}`. The single-brace
form is not LogQL and renders literally, which looks like a data problem rather
than a query one.

Each line is a session `assign` placed in `__invalid__/`. Site-admin action:
rename the directory to `PROJECT.SUBJECT.SESSION` and move it back one level, out
of `__invalid__/` and into the assigned directory — on the node,
`<storage.pipeline.hostPath>/assigned/__invalid__/<dir>` →
`<storage.pipeline.hostPath>/assigned/`, so `/data/xnat-ingest/assigned/` with
the default paths. The upload loop picks it up on its next pass
(`upload.direct.loop` seconds).

### Time series

- **Pipeline log lines per minute (by component)** — `sum by (component) (count_over_time({namespace="xnat-ingest",app="xnat-ingest"}[1m]))`. One line per stage. A stalled pipeline is visible as one line dropping to zero while the others keep going, which is the shape you cannot see from any single counter.
- **Upload throughput (sessions/min)** — `sum(count_over_time({namespace="xnat-ingest",component="upload"} |~ "Successfully uploaded all files in" [1m]))`. Completed sessions per minute.
- **Upload error lines per minute** — the same selector with the error regex from Row 1, on the same graph.

There is deliberately **no failure-rate percentage**. The s3-uploader emitted
`upload_started` / `upload_completed` / `upload_failed` triples, so a ratio had a
denominator counted in the same unit as its numerator. `xnat-ingest upload`
emits one terminal line per success and unstructured error text on the way, so
any such percentage would divide log lines by sessions and read as a precise
number that means nothing. Two series on one graph, read together, is the honest
version.

### Logs panel — Recent pipeline events

LogQL: `{namespace="xnat-ingest",app="xnat-ingest"} | json | line_format "[{{.component}}]{{if .session}} session={{.session}}{{end}} — {{.message}}"`

Last 30 minutes of every line from the group, assign and upload pods, formatted
for human reading. `app="xnat-ingest"` keeps Orthanc's native C++ server chatter
(`app="orthanc"`) out of the tail while leaving every pipeline stage in.

---

## Edge Site Drilldown

Per-cluster / per-node view selected by the **cluster** and **node** dropdowns at
the top of the dashboard.

- `$cluster` is a Loki query of `label_values(cluster)` — single-select.
- `$node` is a Loki query of `label_values({cluster="$cluster"}, node)` — multi-select with `All` defaulting to `.+` (matches any).

On tier-1 both resolve to exactly one value: one `clusterLabel`, one node, so the
dropdowns only really serve to scope the log tail. The dashboard is kept anyway
because the scoping costs nothing when there is one of each, and the same panels
are what a fleet pushing into one Loki needs unchanged.

### Stat row

| Panel | Query (with template vars expanded) | Meaning |
|---|---|---|
| **Completed uploads (last 10m)** | `sum(count_over_time({cluster="$cluster",node=~"$node",namespace="xnat-ingest",component="upload"} \|~ "Successfully uploaded all files in" [10m]))` | Last-10-min session count for the selected scope. Threshold red below 1, green above. 0 while scanners are sending means the pipeline is stuck — but 0 overnight is also normal, so read it next to the throughput graph, never alone. |
| **Assign errors (last 1h)** | Same shape as "Invalid sessions" above, plus the `cluster`/`node` selectors | DICOM metadata validation failures. |
| **Upload errors (last 1h)** | Same shape as Pipeline Overview's "Upload errors", plus the `cluster`/`node` selectors | Error-level noise from the uploader. |
| **DICOM rejected — unmapped AE title (last 1h)** | `sum(count_over_time({cluster="$cluster",node=~"$node",app="orthanc"} \|~ "REJECT: no project mapped for CalledAET" [1h]))` | Studies whose calling AE title is not in `orthanc.deid.aetMap`. They are QUARANTINED, not dropped, so a non-zero count is a mapping to add and re-send — not data lost. Selects `app="orthanc"` because the line comes from the de-identification Lua hook, not a pipeline stage. |

### Time series + log tail

- **Upload log lines per minute (by level)** — `sum by (level) (count_over_time({cluster="$cluster",node=~"$node",namespace="xnat-ingest",component="upload"}[1m]))`. No `| json` needed: `level` is already a stream label, so `sum by (level)` groups on it directly.
- **Live log tail** — `{cluster="$cluster",node=~"$node",namespace="xnat-ingest"} | json | line_format "[{{.component}}]{{if .session}} session={{.session}}{{end}} {{.message}}"`, every stage on the selected scope.

---

## Session Timeline

Single-session trace. The dashboard variable `session` is a text input — paste a
session name and the dashboard shows every log line referencing it across the
group, assign and upload pods.

Query: `{namespace="xnat-ingest"} |= "$session" | json | line_format "{{.component}} | {{.message}}"`.

`|=` is a line match, not a label match, which is why this works even though
nothing promotes `session` to a stream label: the name appears in the message
text of every stage that touches it.

The name to paste is `PROJECT.SUBJECT.SESSION` **as assign derived it** from
`ClinicalTrialProtocolID` / `ClinicalTrialSubjectID` / `ClinicalTrialTimePointID`
(`ingest.assign.tagMapping`). Those tags are written by the de-identification
profile, so on a de-identified site they are the pseudonyms —
`<project>.<subject hash>.<session hash>` — and not the scanner's original IDs.
Searching this dashboard for a real patient name returns nothing, by design; go
from the XNAT session label or the invalid-sessions panel instead.

Sort order is Ascending so the trace reads top-to-bottom in time order.

Used for forensics after a specific session reports a problem.

---

## How to validate a panel after changing it

Enumerate every panel and run its query against Loki. Workflow:

1. Snapshot **before** the change.
2. Make the change. Send a single test study with a unique subject name:
   `dcmsend <nodeIP> 4242 -aec <orthanc.aet> /path/to/study/`.
3. Predict the delta on every panel.
4. Snapshot **after**.
5. For each panel, `delta == prediction` ⇒ panel is correct.

Any mismatch is a bug — fix the query to match the title (or the title to match
the query). Never accept "the dashboard looks roughly right": a panel that reads
zero because its selector matches nothing looks exactly like a site with nothing
to do.
