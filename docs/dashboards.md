# Grafana dashboards: what every panel measures

The `AIS Edge` Grafana folder contains four dashboards and 26 panels. Their
source is `charts/mgmt/files/dashboards/`. The management chart loads these
files through ConfigMaps and the Grafana sidecar. Edit the source files so
that a later deployment keeps the change.

This document defines each panel's inputs, units, scope, and limits. A zero
count means that the query found no matching events. It does not establish
that the pipeline or its log delivery is healthy. Check the data source and
an expected activity signal before treating zero as good news.

Orthanc receives and archives the DICOM instances. In the receiver-only
configuration, de-identification runs in **xnat-ingest**. The dashboards do
not require Orthanc de-identification.

## Data sources, time ranges, and limits

| Dashboard | Panels | Data sources | Default range | Refresh |
|---|---:|---|---|---|
| Pipeline Overview | 12 | Loki | Last 6 hours | 30 seconds |
| Edge Site Drilldown | 6 | Loki | Last 6 hours | 30 seconds |
| SeaweedFS Health | 7 | Prometheus and Loki | Last 6 hours | 30 seconds |
| Session Timeline | 1 | Loki | Last 24 hours | 10 seconds |

Refresh is the configured dashboard interval. It is not a promise that logs
arrive within that time. Collection, forwarding, scraping, and query time
can add delay. The Prometheus datasource uses a 30-second time interval.

Counter lookbacks such as `[1h]` and `[10m]` are part of the query. A stat
panel evaluates at the query end time; changing the dashboard start does
not change a fixed counter lookback. Time-series panels use the selected
dashboard range and evaluate their rolling window at each sample.

Recent invalid sessions has a `1h` panel time override. Recent pipeline
events has a `30m` override. Grafana applies these overrides with relative
dashboard ranges; an absolute dashboard range takes precedence. The other
log panels use the selected dashboard range.

The configured Loki datasource has `maxLines: 5000`. A log panel can show
only part of a busy interval. Ascending display order does not prove that a
session trace is complete. Narrow the time range and use Explore to inspect
adjacent intervals. Metric queries calculate over the matching logs rather
than just the lines displayed by a log panel, but they can still fail on
backend query limits. A query error must not be interpreted as zero.

For a datasource check, use Grafana's connection test and then run a small
query against the actual API. A plugin health endpoint alone is not enough:
for example, the Alertmanager health endpoint can return `plugin.unavailable`
while its proxied `/api/v2/status` request succeeds. These four dashboards
use Loki and Prometheus, not the Alertmanager datasource.

## The s3-uploader event schema

The pipeline headline counters and uploader event charts read structured
JSON emitted by `charts/edge/files/s3-uploader.sh`. Other panels read assign
logs, Orthanc logs, management pipeline logs, or SeaweedFS metrics.

```jsonc
{
  "ts":         "2026-05-14T07:16:50+00:00",
  "component":  "s3-uploader",
  "edge":       "edge-dev",
  "event":      "upload_completed",
  "session":    "test-project.subject-04.visit01",
  "message":    "",
  "bytes":       538740,  // pre-transfer session size from du -sb
  "files":       2,       // pre-transfer regular-file count; follows symlinks
  "dicoms":      1,       // pre-transfer files with case-insensitive .dcm suffix
  "duration_s":  0        // transfer wall time on completion or failure
}
```

### Event names

The event charts include any non-empty `event` field. A future event can
therefore appear without a dashboard edit. Unstructured output with no
event field is excluded, rather than drawn as an unnamed event series.

| Event | Emitted when | Operator meaning |
|---|---|---|
| `startup` | The container starts, before endpoint checks. | Repeated starts can indicate restarts; they are not upload activity. |
| `endpoint_ready` | The `rclone lsd sw:<bucket>` probe succeeds. | The startup bucket probe passed. |
| `endpoint_retrying` | A startup probe fails; it retries after 5 seconds, up to 12 attempts. | A short startup delay can be normal; sustained retries need inspection. |
| `endpoint_failed` | All startup probe attempts fail and the script exits. | Read the message and rclone stderr for endpoint, credential, or certificate errors. |
| `upload_started` | A settled, changed session is selected for transfer. | Carries the pre-transfer inventory. The later endpoint recheck can still skip this attempt. |
| `upload_completed` | `rclone copy` returns zero; a claimed repair request is removed. | The command completed; it does not prove that XNAT has imported the session. |
| `upload_failed` | `rclone copy` returns non-zero; a claimed repair request returns to pending. | The loop can retry on a later cycle. |
| `upload_skipped` | Dangling links, a failed endpoint recheck, or a writer-lock timeout prevent a transfer. | Local data is kept. A skipped attempt is neither a completion nor an upload failure. Sustained skips can leave the pipeline stalled while the failure counter stays zero. |
| `recopy_requeued` | Startup returns a previously claimed repair request to pending. | A later pass can retry a copy interrupted by a container exit. |
| `recopy_claimed` | The uploader claims a staged-reclaimer repair request and copies with `--ignore-times`. | A repair attempt is starting. Inspect the later completion or failure event. |
| `recopy_done` | The copy for a claimed repair request returns zero. | The reclaimer can check the repaired objects on its next run. More than three such events for one session in 24 hours trigger `RecopyLoop`; this historical count alone does not establish the current cause. |
| `dependency_missing` | A required tool or required tool option is unavailable; the uploader exits. | Inspect the named dependency and `upload.s3.shell.image`. `S3UploaderRestartedRecently` selects this failure event. |
| `lock_failed` | Opening the writer lock or acquiring it fails for a reason other than timeout; the uploader exits and returns a claimed repair request to pending. | Inspect lock permissions and the named error. A timeout emits `upload_skipped` instead. `S3UploaderRestartedRecently` selects the failure event. |
| `marker_retired` | No pipeline stage directory retains the marked session. | The upload marker is removed. This is state housekeeping, not a new upload. |

Earlier uploader versions emitted `reclaim_skipped`. The current uploader
copies only; the staged-reclaimer owns local deletion after its S3 proof.
The uploader no longer emits that event. A selector for it can stay empty
even when the current upload and reclaim stages work correctly.

The endpoint failure message describes whether an mTLS client certificate
is configured and readable. A server can return an HTML 400/403 page that
rclone reports as an S3 XML error. Inspect the underlying stderr and the
certificate state before concluding that this is a network failure.

An unchanged session with an upload fingerprint emits no repeated completion
event. A changed or retried session can emit another completion. A quiet
chart can therefore be correct during an idle period. The earlier `alias_*`
events belonged to the former minio/mc client; the current client is rclone.

### DICOMs, files, attempts, and delivery

`dicoms` counts files with a `.dcm` suffix, not every possible DICOM file.
`files` includes those files, each resource's `__MANIFEST__.json`, and other
staged metadata. A manifest is per resource, not per session. Consequently,
`files - dicoms` is not a fixed one-object overhead.

Both inventories are measured **before** the copy. Rclone can skip a file
already present at the destination, and a later copy of a changed session
can count an earlier file again. These fields are not counts of new objects
written, distinct DICOM instances, or completed XNAT imports. Reconcile an
individual transfer with its session and start/completion events. Use XNAT
and management uploader evidence to establish final delivery.

The numeric queries filter `__error__=""` after `unwrap`. Missing or invalid
numeric fields are excluded. An excluded event is unknown inventory, not
proof that it contained zero files. See the [Loki metric query reference](https://grafana.com/docs/loki/latest/query/metric_queries/)
for numeric extraction and pipeline errors.

## Pipeline Overview (`ais-pipeline-overview`)

The uploader and assign selectors use the edge pipeline namespace
`xnat-ingest`. This dashboard reports edge stages. Use Session Timeline for
the later management upload and reclaim stages.

### Headline counters

| Panel | Query input and window | Meaning |
|---|---|---|
| **DICOMs in completed S3 uploads (last 1h)** | Sum `dicoms` from `upload_completed`, with numeric error filtering, `[1h]`. | Pre-transfer DICOM file inventory on completed attempts. Repeated attempts can count a file again. |
| **Files in completed S3 uploads (last 1h)** | Sum `files` from the same events, `[1h]`. | Pre-transfer regular-file inventory, including manifests and metadata. It is not a count of new S3 objects. |
| **Completed S3 uploads (last 1h)** | Count `upload_completed`, `[1h]`. | Successful copy commands, not distinct sessions or XNAT imports. |
| **Upload failures (last 1h)** | Count `upload_failed`, `[1h]`. | Failed copy commands, including failures that later recovered. Zero does not prove that an attempt ran. |

The stat queries use `or vector(0)` to show zero when no matching events
exist. That fallback cannot establish that the log collector is working.

### Pipeline-health counters

| Panel | Query input and window | Meaning |
|---|---|---|
| **Invalid sessions (last 1h)** | Assign `level="ERROR"`, `message =~ "^Invalid IDs found.*"`, `[1h]`. | Invalid identifier reports. The summary error line is excluded, but a repeated attempt can report the same session again. |
| **Assign cycles with errors (last 1h)** | Assign `message =~ "(?s)^Staging completed with.*"`, `[1h]`. | Cycle summary lines. The `(?s)` flag includes newlines in the summary. |
| **Edge sites with assign logs (last 1h)** | Distinct non-empty, non-`mgmt` cluster labels on `component="assign"`, `[1h]`. | Recent assign log delivery. This excludes management reclaimers whose cluster label identifies the edge they serve. It is not a pod-health test. |

### Recent invalid sessions

```logql
{namespace="xnat-ingest",component="assign"}
  | json | level="ERROR" | message =~ "^Invalid IDs found.*"
```

The panel displays the cluster and message and has a one-hour relative
time override. Inspect the error and the
staged files before correcting identifiers and retrying. Renaming a folder
alone is not a universal repair for missing or invalid DICOM identifiers.

### Time series

| Panel | Query input | Meaning |
|---|---|---|
| **Pipeline events per minute (by event type)** | Uploader JSON with `event != ""`, counted over `[1m]`, grouped by event. | Includes startup, endpoint, copy, and marker events. Lines without an event field do not create a blank legend entry. |
| **Per-edge upload throughput (events/min)** | `upload_completed` over `[1m]`, grouped by cluster. | Completed S3 attempt events per minute. |
| **Failure rate (upload_failed / upload_started)** | Per-cluster failure and start counts over `[15m]`. | An event ratio displayed as a percentage. Starts without failures produce zero; no starts produce a gap. |

The failure ratio uses LogQL vector arithmetic:
`(failures or (0 * starts)) / (starts > 0)`. It does not use PromQL-only
`clamp_min`, which Loki rejects. A transfer can start and finish in different
windows, so this ratio is not a matched-attempt failure probability. Also
inspect `upload_skipped` and `endpoint_failed`: neither is `upload_failed`.

### Recent pipeline events

The query selects `{namespace="xnat-ingest"} | json | event != ""` and
formats cluster, component, event, and optional session, duration, files,
and bytes. Its relative time override is 30 minutes. The displayed `files`
and `bytes` have the inventory meaning described above.

## Edge Site Drilldown (`ais-edge-drilldown`)

The **cluster** dropdown lists cluster labels seen on edge assign logs.
The **Worker node** dropdown lists nodes in that cluster's `xnat-ingest`
namespace. This avoids offering the management reclaimer's node merely
because its logs carry the edge's cluster label. The `All` node value is
`.+`, used by each `node=~"$node"` selector.

Dropdown labels depend on retained logs. They are not a current inventory of
healthy Kubernetes nodes. All panels use the selected edge and worker.

### Stat row

| Panel | Query input | Meaning |
|---|---|---|
| **Completed uploads (last 10m)** | Uploader `upload_completed`, `[10m]`. | Completed S3 attempts. A zero value is normal when idle; with expected scanner traffic, inspect the stages and log delivery. |
| **Invalid session reports (last 1h)** | Assign `ERROR` messages beginning `Invalid IDs found`, `[1h]`. | Invalid identifier reports, not every assign error. |
| **Upload failures (last 1h)** | Uploader `upload_failed`, `[1h]`. | Failed attempts, including failures followed by recovery. |
| **Unmapped AE rejection logs (last 1h)** | Orthanc raw lines containing `REJECT: no project mapped for CalledAET`, `[1h]`. | Legacy AET-map rejection log lines. This does not count studies. In receiver-only mode it is expected to stay zero. |

### Time series + log tail

| Panel | Query input | Meaning |
|---|---|---|
| **Live log tail** | All selected edge `xnat-ingest` namespace lines. | Component, optional event/session, and message. The original line is shown when a JSON message is absent. |
| **Upload events per minute** | Uploader non-empty event fields over `[1m]`. | One series per event type, not a unique-session count. |

In receiver-only mode, `deidentify-and-forward.lua` returns before the
legacy AET-map lookup. De-identification occurs in xnat-ingest, so the AE
rejection tile does not test its routing or de-identification. The legacy
rejection path preserves originals in the facility quarantine; a rejection
log alone is not evidence that the source bytes were lost. The same raw
log pattern is used by the `DICOMRejectedUnmappedAET` Loki rule.

The former Pod restarts and Worker NotReady panels used edge Prometheus
metrics unavailable to the management datasource across the konnectivity
boundary. These Loki panels avoid that unsupported scrape assumption, but
they do not replace Kubernetes node or pod health checks.

## Session Timeline (`ais-session-timeline`)

Paste the full `PROJECT.SUBJECT.VISIT` session name into the text input.
The query uses a substring filter, so a short name can match other sessions.
An empty input matches every pipeline line and is likely to reach the log
limit. The source query is:

```logql
{app=~"xnat-ingest|data-policy|orthanc"} |= "$session" | json
  | line_format "{{.namespace}} | {{.cluster}} | {{.component}} | {{if .event}}{{.event}} | {{end}}{{if .message}}{{.message}}{{else}}{{__line__}}{{end}}"
```

Both edge stages and management upload/reclaim pods carry `app=xnat-ingest`.
The selector also retains `app=data-policy` decisions and matching
`app=orthanc` receiver logs, without hard-coding namespaces. An instance
receiver log that contains only a DICOM UID will not match a session name;
use that UID separately when tracing reception. A selector
limited to `namespace="xnat-ingest"` misses the management `xnat-upload`
namespace and cannot show the whole route to XNAT.

The displayed namespace and component distinguish the stages. A management
reclaimer can carry `cluster=edge-dev` because it serves that edge, while a
management uploader carries `cluster=mgmt`. The cluster label alone does
not identify where a process runs. The original line is retained when no
JSON message exists. Ascending order makes the returned trace readable;
use smaller time intervals if it reaches the 5,000-line limit.

## SeaweedFS Health (`ais-seaweedfs-health`)

Prometheus scrapes the `<release>-seaweedfs-metrics` Service on port 9324.
The ServiceMonitor selects `app: seaweedfs`; see
`charts/mgmt/templates/seaweedfs.yaml`.

The **S3 bucket** dropdown discovers `bucket` labels from
`SeaweedFS_s3_request_total`. It supports one or several buckets. `All` uses
`.*`, so it includes requests with or without a bucket label. It works with
per-site names such as `ingest-edge-dev` and with custom bucket prefixes.
A bucket with no metric series does not appear until activity is recorded.

The dropdown filters all four S3 request panels. It does not filter volume
storage or service logs. Bucket values use `${bucket:regex}` to escape
literal names and support multiple selection. The custom All expression
is passed as a regex, as documented by [Grafana's variable reference](https://grafana.com/docs/grafana/latest/visualizations/dashboards/variables/variable-syntax/).

| Panel | Query | Meaning |
|---|---|---|
| **Successful S3 LIST requests - $bucket (last 1h)** | `sum(increase(SeaweedFS_s3_request_total{bucket=~"${bucket:regex}",type="LIST",code="200"}[1h])) or vector(0)` | Successful LIST activity from any S3 client. It is not proof that a particular uploader is alive. `increase` can return fractional estimates. |
| **Volume data-file bytes (all collections)** | `sum(SeaweedFS_volumeServer_total_disk_size{type="normal"})` | Reported volume data-file bytes across all collections. Excludes the separate deleted-content gauge to avoid double-counting. |
| **S3 requests/min - $bucket (last 5m)** | `sum(rate(SeaweedFS_s3_request_total{bucket=~"${bucket:regex}"}[5m])) * 60` | Rolling request rate for selected buckets, scaled to per-minute. |
| **Volumes (across all buckets)** | `max(SeaweedFS_volumeServer_volumes{type="volume"})` | Maximum reported volume count for the current single-volume-server deployment. |
| **S3 request rate by HTTP code - $bucket** | `sum by (code) (rate(SeaweedFS_s3_request_total{bucket=~"${bucket:regex}"}[5m]))` | Per-second rate by response code. Inspect 4xx and 5xx responses. |
| **S3 request rate by operation type - $bucket** | `sum by (type) (rate(SeaweedFS_s3_request_total{bucket=~"${bucket:regex}"}[5m]))` | Per-second operation rate. Multipart requests and retries do not map one-to-one to files. |
| **SeaweedFS log tail** | `{cluster="mgmt",app="seaweedfs"} | json` with message/original-line formatting. | Service logs selected independently of the Helm release namespace. |

The former LIST query fixed `bucket="ingest-bucket"`. That can show zero on
a healthy per-site deployment because the actual bucket is named
`<bucketPrefix>-<edge>`. The bucket dropdown removes this assumption.
The former log selector fixed `namespace="seaweedfs"`, while the chart puts
SeaweedFS in the management release namespace, normally `ais-mgmt`.

SeaweedFS reports `normal` size and `deleted_bytes` as separate series.
The latter describes deleted content already represented in the volume
size, rather than extra disk usage. Adding them overstates usage. The
[SeaweedFS 4.34 metric producer](https://github.com/seaweedfs/seaweedfs/blob/4.34/weed/storage/store.go)
records these quantities separately. The panel is not a full filesystem
usage measurement: indexes, filer storage, and filesystem overhead need
separate disk telemetry. Confirm that this telemetry exists before relying
on a filesystem panel; a volume-size gauge alone cannot establish free space.

The volume-count metric repeats a server total under collection labels in
the current deployment. Summing those series would overcount. The existing
`max` query returns seven when three collection series each report seven.
Revisit this query if the chart gains multiple volume servers; the maximum
alone will not represent a fleet total.

Do not infer DICOM counts from S3 operation rates. Multipart upload and
request accounting depend on client and server behavior. The current client
is rclone, and the uploader inventory counters have the limits stated above.
XNAT delivery requires downstream evidence.

## How to validate a panel after changing it

There is no tracked panel-audit script in this repository. Two existing
checks cover related concerns:

- `scripts/check-alert-inputs.sh` checks inputs to alert rules, not dashboard
  selectors or panel arithmetic.
- `make runtime-templates` checks that dashboard `line_format` templates
  survive Helm rendering. It does not prove that a query returns correct data.

Use the panel's own datasource in Grafana Explore or its read-only API:

1. Choose a fixed absolute start and end time. Record the query, variable
   values, datasource, source revision, and expected result.
2. Check the underlying labels and raw events or metric series. Confirm
   that the selector matches the intended component, bucket, and location.
3. Run the old and new queries against the same window. For a counter,
   reconcile raw events; for a ratio, check numerator, denominator, zero
   failures with starts, and an idle interval with no starts.
4. Test missing data and an invalid selector separately. A fallback zero
   can hide a wrong selector, while a query error is a different condition.
5. Parse each dashboard as JSON. Render the chart and run
   `make runtime-templates`. Compare the rendered dashboard JSON with its
   source, including LogQL `{{ }}` and Grafana `${variable:regex}` syntax.
6. Check dropdown expansion, panel time overrides, datasource limits, and
   refresh settings. Browser rendering and scheduled refresh require a
   separate UI check; API success alone does not prove those behaviors.

If a new synthetic transfer is needed, use a designated test environment
and the agreed test ownership. Predict the file inventory and events first,
then reconcile the result. A dashboard review does not require injecting
new data or restarting a running test.

A 2026-10-15 fixed-window review found 21 S3 completions with inventories of
2,062 DICOMs and 2,215 files. A selected synthetic session had 14 edge log
lines and 40 further management lines. Those are bounded observations from
that test window, not baseline values for another installation. After a
change, prove the selector and arithmetic again with that site's evidence.
