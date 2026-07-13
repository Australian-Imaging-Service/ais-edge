# Observability integration & swap guide

**Ground truth:** branch `tier-1-solution` @ `fb1b14c`, 2026-07-08, verified against the live single-node deployment.

This note is for a platform/monitoring team who want to **replace the bundled observability stack with their own** (Splunk, Elastic/OpenSearch, Datadog, an institutional Prometheus/Grafana, etc.). The bundled stack — Loki + Prometheus + Grafana + Alertmanager + Vector — is a **reference default, not a hard dependency**. The DICOM→XNAT pipeline is instrumented in a vendor-neutral way; this document is the contract you build against.

---

## 0. The stack is optional (on/off switch)

The whole stack self-skips on one config field. In `config/management.env`:

```bash
export ALERT_EMAIL_TO=""     # empty  -> observability step installs NOTHING
                             # set    -> installs Loki/Prometheus/Grafana/Alertmanager/Vector
```

`scripts/02d-install-observability.sh` exits early when it's empty ([lines 26-32](../scripts/02d-install-observability.sh#L26-L32)). The pipeline (Orthanc → group-orthanc → assign → upload → XNAT) installs and runs **completely independently** of this stack — verified: the drop test's DICOM→XNAT flow ran and was confirmed before observability was ever deployed.

So integration has three postures:
1. **Leave it off** and run only your own tooling.
2. **Run it alongside** yours (both consume the same node).
3. **Replace piece-by-piece** using the contracts below.

---

## 1. The three signal planes

| Plane | What carries it today | Bundled consumer | Your replacement |
|---|---|---|---|
| **Logs** (the *primary* pipeline signal) | Every pod's **stdout**, structured JSON where the app emits it | Vector → Loki | any log agent → your log store |
| **Metrics** (infra only) | Standard Kubernetes/host exporters | kube-prometheus-stack Prometheus | any Prometheus-compatible scraper |
| **Alerts** | LogQL rules (Loki ruler) + PromQL rules (Prometheus) | Alertmanager → email/Slack | re-express rules in your platform |

> **Key fact:** the pipeline exposes **no custom Prometheus `/metrics` endpoints** — there are zero pipeline ServiceMonitors. All pipeline-level signal (uploads, de-id, sessions, failures) is in **logs**. Metrics are only standard cluster/host infrastructure telemetry. Plan your integration around **logs first**.

---

## 2. Logs — the main contract

### 2a. Two kinds of "labels" — don't conflate them

- **Loki stream labels** — attached by Vector from Kubernetes pod metadata (not from the log text). These are what you filter streams by:

  | label | source | example values |
  |---|---|---|
  | `namespace` | pod namespace | `xnat-ingest`, `xnat-upload` |
  | `app` | pod label `app` | `orthanc`, `xnat-ingest` |
  | `component` | pod label `component` | `dicom-receiver`, `group`, `assign`, `upload` |
  | `pod`, `container`, `node`, `cluster`, `level` | pod metadata | — |

- **JSON message fields** — inside the log line itself, parsed with LogQL `| json`. **Availability varies by component** (below).

Any collector you swap in should preserve at least `namespace`/`app`/`component` (from `kubernetes.pod_namespace` / `pod_labels.app` / `pod_labels.component`) so your queries can target each stage.

### 2b. Per-component emitted schema (as actually emitted today)

**Orthanc de-id hook** (`app=orthanc`, `component=dicom-receiver`) — the **richest structured events**, emitted by the Lua hook via `print(DumpJson(...))`. Best per-session/audit anchor:

```json
{"ts":"2026-07-06T05:05:36Z","component":"orthanc-deid","event":"instance_deidentified",
 "mode":"modify","calledAet":"AISEDGE","project":"test-project",
 "session":"test-project.90001C64992C.BB6AAD071A7A",
 "originalId":"76d61ff2-…","newId":"3091d67e-…","backupPath":"/facility-backup/…/….dcm"}

{"ts":"…","component":"orthanc-deid","event":"study_labeled_ready","studyId":"08c0…","label":"xnat-ingest-ready"}
```
Fields: `ts, component, event, mode, calledAet, project, session, originalId, newId, backupPath` (deid) / `ts, component, event, studyId, label` (ready). `event` and `session` are **real JSON fields** here — use `| json | event="instance_deidentified"`.
Orthanc also emits its **native (non-JSON) server logs** (`DICOM server listening…`, `new stored instance`, Lua tracebacks) — matched by text, not `| json`.

**xnat-ingest group-orthanc / assign** (`app=xnat-ingest`, `component=group` and `component=assign`) — upstream ≥0.12 split the old `sort` command into two stages that log in the same shape. `group-orthanc` REST-pulls from Orthanc and labels each study; `assign` derives the project/subject/session IDs and stages the session (it also emits the `Invalid IDs found` lines):
```json
{"ts":"2026-07-08T01:49:01+0000","level":"INFO","logger":"xnat-ingest","message":"Staged and labelled study '08c0…' -> 'test-project.test_project_90001C64992C.BB6AAD071A7A'"}
```
Fields: `ts, level, logger, message`. **No top-level `session`/`event` JSON key** — the session name is *inside* `message`. (`level` is present on most lines, absent on a few.)

**xnat-ingest upload** (`app=xnat-ingest`, `component=upload`):
```json
{"ts":"…","level":"INFO","logger":"xnat-ingest","message":"Successfully uploaded all files in 'test-project.test_project_90001C64992C.BB6AAD071A7A'"}
```
Fields: `ts, level, logger, message` (some progress lines carry only `message`). The **terminal-success signal** is the message text `Successfully uploaded all files in '<session>'`. Session name is *inside* `message`.

### 2c. Reliable signals to build on

| Signal | Where | Match |
|---|---|---|
| De-id happened (per instance) | orthanc | `\| json \| event="instance_deidentified"` (has `session`, `project`, `calledAet`) |
| Study ready | orthanc | `\| json \| event="study_labeled_ready"` |
| **Upload success** (terminal) | upload | message `=~ "Successfully uploaded all files in"` |
| Upload error | upload | message `=~ "(?i)error\|failed\|exception\|traceback"` |
| XNAT auth failure | upload | message `=~ "(?i)\b(401\|403\|unauthorized\|forbidden)\b"` |
| Invalid DICOM (`__invalid__`) | assign | message `=~ "(?i)invalid\|validation.*fail"` |
| Orthanc backlog | orthanc | native log `=~ "new stored instance"` |

> **Honest caveat (ground truth):** the `session` field is a **real JSON key only in the Orthanc de-id events**. For assign/upload it lives in the message text, so per-session correlation should anchor on the **Orthanc de-id event** (or regex-extract the session from assign/upload messages). Two bundled rules (`SessionUploadStalled`, `XNATBacklogGrowing`) use `component="assign" | json | session` — they work best when correlated against the Orthanc event; treat them as best-effort until assign/upload emit `session` as a first-class field.

### 2d. Swapping the log path

Point any agent at the kubelet log files and ship to your backend — nothing here is Loki-specific:
- **Source:** `/var/log/pods/*/*/*.log` (what Vector reads today, read-only).
- **Agents that work unchanged:** Fluent Bit, Fluentd, Splunk OTel/Universal Forwarder, Elastic Filebeat/Elastic Agent, Datadog Agent, Grafana Alloy, or your own Vector.
- **Parsing:** JSON-decode the `message` where present; carry `namespace/app/component/pod/node` as index fields/labels.

---

## 3. Metrics — infrastructure only

There are **no bespoke pipeline metrics**. What the bundled Prometheus scrapes is the kube-prometheus-stack default set:

- **kube-state-metrics** — `kube_node_status_condition`, `kube_pod_container_status_restarts_total`, `kube_node_info`, `kube_pod_status_phase`, …
- **node-exporter** — `node_filesystem_avail_bytes`, `node_memory_*`, `node_cpu_*`, … (host/disk — relevant for `/data` filling up)
- **kubelet / cAdvisor** — `container_cpu_*`, `container_memory_*`, per-pod resource use
- **apiserver** — `up{job="apiserver"}`

The bundled alerts only actually depend on a handful: `up{job="apiserver"}`, `kube_node_status_condition{condition="Ready"}`, `kube_pod_container_status_restarts_total`, `kube_node_info`.

**Swap:** these are standard metric names — scrape the same endpoints with your own Prometheus, VictoriaMetrics, Grafana Alloy, or Datadog. If you want pipeline *rates* as metrics (uploads/min, failures/min) rather than logs, derive them from the log signals in §2c via your log platform's metric-extraction (e.g. Loki `count_over_time`, Splunk `timechart`, Datadog log-based metrics).

---

## 4. Alert inventory (current definitions)

Two engines. **Log alerts** (Loki ruler, LogQL over §2 logs) live in [`loki-ruler-rules.yaml`](../manifests/01-management/observability/loki-ruler-rules.yaml); **metric alerts** (PromQL) live in [`alerts/*.yaml`](../manifests/01-management/observability/alerts/). All route to Alertmanager → email/Slack.

| Alert | Sev | Engine | Fires when (the underlying signal) |
|---|---|---|---|
| `XNATUploadFailingForAllSessions` | critical | Loki | upload errors present **and** zero `Successfully uploaded…` for 15m |
| `XNATUploadRetryStorm` | warning | Loki | >5 upload errors in 10m |
| `SessionUploadStalled` | warning | Loki | a staged session with no matching upload-success in 15m *(session-field caveat, §2c)* |
| `XNATBacklogGrowing` | warning | Loki | staged-count − upload-success-count > 3 over 30m |
| `DICOMValidationFailureSpike` | warning | Loki | >10 `invalid`/validation lines from assign in 1h |
| `XNATUploadSuccess` | info | Loki | any `Successfully uploaded…` in 30s (audit/heartbeat) |
| `XNATAuthFailure` | warning | Loki | 401/403/unauthorized/forbidden from upload in 5m |
| `OrthancDeidLuaError` | warning | Loki | Lua error/traceback from orthanc in 10m (deid stalled) |
| `OrthancStorageGrowing` | warning | Loki | >1000 `new stored instance` in 1h |
| `ManagementClusterDown` | critical | Prom | `up{job="apiserver"}==0` for 5m |
| `EdgeWorkerDisconnected` | critical | Prom | node `Ready` condition != true for 5m |
| `IngestPodCrashLoop` | warning | Prom | >3 restarts/1h in `xnat-ingest`/`xnat-upload` |
| `NodeCountChanged` | info | Prom | `kube_node_info` changed in 10m |

**Swap:** re-express these in your platform's query language. The *definitions* are portable — each row's "fires when" column is the signal; the LogQL/PromQL is just one encoding of it. The log rules map cleanly to Splunk SPL / Elastic EQL / Datadog log monitors; the metric rules run as-is on any Prometheus (they're plain `PrometheusRule` CRDs / recording rules).

---

## 5. Swap matrix

| Bundled component | Role | Drop-in replacements | What you must re-implement |
|---|---|---|---|
| **Vector** | tail pod stdout → ship logs | Fluent Bit, Fluentd, Splunk fwd, Filebeat, Datadog, Alloy | collector config (source `/var/log/pods`, keep `namespace/app/component` labels) |
| **Loki** | store + query logs, run log alerts | Splunk, Elastic/OpenSearch, Datadog Logs, your Loki | the LogQL rules in §4 → your query language |
| **Prometheus** | scrape + store infra metrics, run metric alerts | your Prometheus, VictoriaMetrics, Alloy, Datadog | nothing (standard scrape targets); PromQL rules port 1:1 to another Prometheus |
| **Alertmanager** | route firing alerts to email/Slack | your Alertmanager, PagerDuty, Opsgenie, Datadog monitors | receiver/routing config |
| **Grafana** | dashboards | your Grafana | 3 dashboards (`pipeline-overview`, `session-timeline`, `edge-drilldown`) point at Loki/Prometheus datasources — repoint or rebuild |

---

## 6. Minimal recipes

**Send logs to your backend, drop the bundled stack:** leave `ALERT_EMAIL_TO` empty, deploy your own log-agent DaemonSet reading `/var/log/pods` (JSON-decode `message`, carry `namespace/app/component`), route to your store. Nothing in the pipeline changes.

**Keep metrics in your Prometheus:** scrape the standard node-exporter/kube-state-metrics/kubelet endpoints; import the four `PrometheusRule` groups (`ais-edge-critical/-warning/-info`) directly.

**Recreate the two must-have signals anywhere:**
- *Pipeline delivering?* — count of `Successfully uploaded all files in` per interval (should be non-zero when studies arrive).
- *Pipeline broken?* — upload-error lines rising while that success count is zero.

---

## 7. Ground-truth appendix (as verified 2026-07-08)

- Loki stream labels present: `app, cluster, component, container, level, namespace, node, pod, service_name, stream`.
- `namespace` values: `xnat-ingest`, `xnat-upload`, `observability`, `local-path-storage`. `component` values: `dicom-receiver`, `group`, `assign`, `upload`.
- Pipeline ServiceMonitors: **none** (no custom pipeline metrics).
- Loglevel/format: pipeline pods run with `AIS_LOG_FORMAT=json`; Orthanc mixes JSON hook events with native C++ server logs.
- Naming leftover to be aware of: the metric alert `EdgeWorkerDisconnected` is really "this node NotReady" on a single-node appliance (cosmetic name from the two-node era).
