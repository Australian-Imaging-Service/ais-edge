# Observability integration & swap guide

**Ground truth:** branch `tier-1-solution` @ `fc96936`. The emitted log schemas were verified against the live single-node deployment (2026-07-08) and re-checked against the code that emits them; everything about the stack itself is verified against `charts/edge` as it renders today (§7 has the render command).

This note is for a platform/monitoring team who want to **replace the bundled observability stack with their own** (Splunk, Elastic/OpenSearch, Datadog, an institutional Prometheus/Grafana, etc.). The bundled stack — Loki + Prometheus + Grafana + Alertmanager + Vector — is a **reference default, not a hard dependency**. The DICOM→XNAT pipeline is instrumented in a vendor-neutral way; this document is the contract you build against.

---

## 0. The stack is optional (two switches, and they are not the same switch)

Everything is configured in **one file**, `sites/<site>/values.yaml` (scaffold it from `sites/example-single/` with `scripts/site-secrets.sh new <name> single`). Two independent keys govern observability:

```yaml
observability:
  enabled: true          # run Vector on this node — ship logs SOMEWHERE
  stack:
    enabled: true        # host the store HERE — Loki + Prometheus + Grafana
                         # + Alertmanager, on this same node. Default: false.
```

They are orthogonal **on purpose**. `observability.enabled` decides whether a collector runs at all; `observability.stack.enabled` decides whether this node also *stores* what the collector produces. A team shipping to their own backend wants the first true and the second false — that is a supported posture, not a workaround. Overloading one key to mean both would make "ship logs" and "host a log store" impossible to configure apart.

`stack.enabled` is the `condition:` on the two dependencies in [`charts/edge/Chart.yaml`](../charts/edge/Chart.yaml) — **kube-prometheus-stack 87.19.2** and **loki 7.1.0**, pinned and **vendored** as `charts/edge/charts/*.tgz`. Nothing is fetched at install time: no `helm repo add`, no `helm dependency update`. A hospital appliance must not need a working path to `grafana.github.io` in order to reinstall.

> **Caution:** the key must *exist and be false*, not be absent. A Helm dependency whose condition path does not resolve is treated as ENABLED.

The pipeline (Orthanc → group-orthanc → assign → upload → XNAT) installs and runs **completely independently** of this stack — verified: the drop test's DICOM→XNAT flow ran and was confirmed before observability was ever deployed.

So integration has three postures:
1. **Leave it off** and run only your own tooling.
2. **Run it alongside** yours (both consume the same node).
3. **Replace piece-by-piece** using the contracts below.

### 0a. The knobs, and where they actually take effect

| Site value (`sites/<site>/values.yaml`) | Effect |
|---|---|
| `observability.enabled` | Vector DaemonSet on/off ([`charts/edge/templates/vector.yaml`](../charts/edge/templates/vector.yaml)) |
| `observability.stack.enabled` | both subcharts on/off |
| `observability.stack.grafana.nodePort` | the port `install.sh` prints as `http://<nodeIP>:<port>` |
| `observability.stack.retentionDays` | the site's stated retention |
| `observability.stack.alerting.{emailTo,emailFrom,smtpHost,smtpPort,smtpUsername}` | alert mail routing; SMTP password is the `alertmanager-smtp` Secret |
| `nodeIP` | the address Grafana is reached on |

Grafana's admin login is the `grafana-admin-credentials` Secret and the SMTP password is `alertmanager-smtp` — both SOPS-encrypted in `sites/<site>/secrets.enc.yaml`, both in namespace `xnat-ingest`, never in the values file.

> **Read this before you tune retention or the NodePort:** the *enforcing* values are the subchart blocks at the bottom of [`charts/edge/values.yaml`](../charts/edge/values.yaml) — `loki.loki.limits_config.retention_period`, `kube-prometheus-stack.prometheus.prometheusSpec.retention`, `kube-prometheus-stack.grafana.service.nodePort`. Helm does not template subchart values, so the site-level keys above state intent and the subchart values must be kept in step by hand. Change one, change the other.

---

## 1. The three signal planes

| Plane | What carries it today | Bundled consumer | Your replacement |
|---|---|---|---|
| **Logs** (the *primary* pipeline signal) | Every pod's **stdout**, structured JSON where the app emits it | Vector DaemonSet → Loki (`ais-loki`) | any log agent → your log store |
| **Metrics** (cluster only) | kube-state-metrics, kubelet/cAdvisor, apiserver | Prometheus (`ais-kps-prometheus`) | any Prometheus-compatible scraper |
| **Alerts** | LogQL rules (Loki ruler) + PromQL rules (Prometheus) | Alertmanager (`ais-kps-alertmanager`) → email/Slack | re-express rules in your platform |

**Names you will need.** The subcharts are installed with `fullnameOverride`, so the objects are *not* `<release>-…`: kube-prometheus-stack is **`ais-kps`** (`ais-kps-prometheus`, `ais-kps-alertmanager`, `ais-kps-operator`) and Loki is **`ais-loki`** (Service and StatefulSet). Grafana is the exception — it keeps the release name, `<release>-grafana`. The Loki name is pinned deliberately: `charts/edge/files/vector-local.yaml` names that Service *literally* (a `.Files.Get` file is never templated), so if it followed the release name, Vector would push at an address that never resolves — and logs that silently never arrive look exactly like a quiet site.

> **Key fact:** the pipeline exposes **no custom Prometheus `/metrics` endpoints** — there are zero pipeline ServiceMonitors. The eight ServiceMonitors that render all belong to kube-prometheus-stack itself. All pipeline-level signal (uploads, de-id, sessions, failures, disk) is in **logs**. Plan your integration around **logs first**.

---

## 2. Logs — the main contract

### 2a. Two kinds of "labels" — don't conflate them

- **Loki stream labels** — attached by Vector from Kubernetes pod metadata (not from the log text). These are what you filter streams by:

  | label | source | example values |
  |---|---|---|
  | `namespace` | pod namespace | `xnat-ingest` (the whole release), `kube-system`, `local-path-storage` |
  | `app` | pod label `app` | `orthanc`, `xnat-ingest`, `data-policy`, `vector` |
  | `component` | pod label `component` | `dicom-receiver`, `group`, `assign`, `upload`, `data-policy` |
  | `pod`, `container`, `node`, `cluster`, `level` | pod metadata | `cluster` is the site's `clusterLabel` |

  The label set is defined in [`charts/edge/files/vector-local.yaml`](../charts/edge/files/vector-local.yaml) (tier-1) and is load-bearing: every rule and dashboard panel selects on these names.

- **JSON message fields** — inside the log line itself, parsed with LogQL `| json`. **Availability varies by component** (below).

Any collector you swap in should preserve at least `namespace`/`app`/`component` (from `kubernetes.pod_namespace` / `pod_labels.app` / `pod_labels.component`) so your queries can target each stage. On a single node everything — pipeline, Vector, and the stack itself — lives in the one release namespace (`namespace: xnat-ingest` in the site file), so `namespace` no longer separates ingest from upload; `component` does.

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

**data-policy reporter** (`app=data-policy`, `component=data-policy`) — the DaemonSet from [`charts/edge/files/data-policy.sh`](../charts/edge/files/data-policy.sh). It runs even with `dataPolicy.enabled: false` (report-only: the volumes are mounted read-only, so it *cannot* delete), walks each declared storage stage every `dataPolicy.reporter.interval` seconds (default 300) and reports. **This is the only disk-headroom signal on the node** — see §3.

```json
{"ts":"2026-08-10T02:00:00+00:00","component":"data-policy","edge":"tier1-example",
 "event":"stage_report","stage":"originals.facilityBackup","message":"41% free, 918 file(s), oldest 63204s",
 "location":"/facility-backup","kind":"original","free_pct":41,"size_kb":524288000,"avail_kb":214958080,
 "entries":918,"oldest_age_s":63204,"min_free_pct":10,"policy":"forever"}
```
Fields: `ts, component, edge, event, stage, message` on every line; `stage_report` adds `location, kind, free_pct, size_kb, avail_kb, entries, oldest_age_s` and echoes that stage's **own** thresholds (`min_free_pct`, `alert_after_s`) so a rule compares against the stage's limit rather than one hardcoded fleet-wide. Stage names as rendered: `originals.facilityBackup`, `originals.quarantine`, `derived.orthancStorage`, `derived.grouped`, `derived.assigned`. `event` and the numeric fields are real JSON keys — the script's header calls this schema a public interface, because renaming a field disables its alert silently.

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
| **Disk headroom** (per stage) | data-policy | `\| json \| event="stage_report"` → `free_pct` vs `min_free_pct` |
| Unmapped-AET data sitting in quarantine | data-policy | `\| json \| event="stage_report", stage="originals.quarantine"` → `oldest_age_s` vs `alert_after_s` |

> **Honest caveat (ground truth):** the `session` field is a **real JSON key only in the Orthanc de-id events**. For assign/upload it lives in the message text, so per-session correlation should anchor on the **Orthanc de-id event** (or regex-extract the session from assign/upload messages). Two bundled rules (`SessionUploadStalled`, `XNATBacklogGrowing`) use `component="assign" | json | session` — they work best when correlated against the Orthanc event; treat them as best-effort until assign/upload emit `session` as a first-class field.

### 2d. Swapping the log path

Point any agent at the kubelet log files and ship to your backend — nothing here is Loki-specific:
- **Source:** `/var/log/pods` and `/var/log/containers`, both mounted **read-only** on the Vector DaemonSet.
- **Agents that work unchanged:** Fluent Bit, Fluentd, Splunk OTel/Universal Forwarder, Elastic Filebeat/Elastic Agent, Datadog Agent, Grafana Alloy, or your own Vector.
- **Parsing:** JSON-decode the `message` where present; carry `namespace/app/component/pod/node` as index fields/labels.
- **Turning ours off:** `observability.enabled: false` removes the DaemonSet, its ServiceAccount and its RBAC. Nothing else in the chart references it.

**If you keep Vector but repoint it.** It is a **hand-written DaemonSet** ([`charts/edge/templates/vector.yaml`](../charts/edge/templates/vector.yaml)), not the Vector subchart — that avoids the subchart's `tpl`-over-`customConfig` behaviour, where Helm evaluates Vector's own `{{ }}` syntax and renders every stream label as an empty string, silently breaking every rule and panel that selects on one. The config is a plain file mounted verbatim, in two variants:

| File | Used when | Difference |
|---|---|---|
| `charts/edge/files/vector.yaml` | `stack.enabled: false` — pushing off-box | has the sink `tls:` block (client cert + CA for a remote Loki) |
| `charts/edge/files/vector-local.yaml` | `stack.enabled: true` — tier-1 | **exactly that `tls:` block removed**, nothing else |

Two files rather than one conditional, because Helm must never evaluate either. Tier-1's Loki is in-cluster over plain `http` with no client certificate; leaving the `tls:` block in would point Vector at `/etc/ssl/loki-client/tls.crt`, which does not exist here, and every push would fail at the handshake. Anything site-specific arrives as an env var instead — `CLUSTER_LABEL` and `LOKI_ENDPOINT`, the latter derived to `http://ais-loki.<namespace>.svc.cluster.local:3100` when the local stack is on, or to `observability.loki.endpoint` when you set one. **Keep the two files in step:** any non-TLS change to one belongs in the other.

---

## 3. Metrics — infrastructure only

There are **no bespoke pipeline metrics**. What the bundled Prometheus scrapes is a *reduced* kube-prometheus-stack default set:

- **kube-state-metrics** — `kube_node_status_condition`, `kube_pod_container_status_restarts_total`, `kube_node_info`, `kube_pod_status_phase`, …
- **kubelet / cAdvisor** — `container_cpu_*`, `container_memory_*`, per-pod resource use
- **apiserver** — `up{job="apiserver"}`
- **the stack watching itself** — Prometheus, Alertmanager, Grafana, the operator, CoreDNS

**Deliberately disabled** in `charts/edge/values.yaml`: `nodeExporter`, `kubeControllerManager`, `kubeScheduler`, `kubeProxy`, `kubeEtcd`. On a single k0s node those scrape targets do not exist as separately-addressable endpoints, and left on they produce permanently-firing "target down" alerts — which trains operators to ignore Alertmanager, which is worse than having no alerts.

> **Consequence, and it matters:** there are **no `node_*` host metrics**, so `node_filesystem_avail_bytes` is not available for "is `/data` filling up?". On tier-1 that question is answered from **logs** — the data-policy `stage_report` events in §2b carry `free_pct`/`avail_kb` per storage stage, measured at the directory that actually holds the data. If your platform wants disk as a metric, extract it from those fields, or scrape a node-exporter you run yourself.

The bundled metric alerts only depend on a handful: `up{job="apiserver"}`, `kube_node_status_condition{condition="Ready"}`, `kube_pod_container_status_restarts_total`, `kube_node_info`.

**Swap:** these are standard metric names — scrape the same endpoints with your own Prometheus, VictoriaMetrics, Grafana Alloy, or Datadog. If you want pipeline *rates* as metrics (uploads/min, failures/min) rather than logs, derive them from the log signals in §2c via your log platform's metric-extraction (e.g. Loki `count_over_time`, Splunk `timechart`, Datadog log-based metrics).

---

## 4. Alert inventory (current definitions)

Two engines, one Alertmanager.

- **Log alerts** — LogQL over the §2 streams, evaluated by **Loki's own ruler**, configured under `loki.loki.rulerConfig` in [`charts/edge/values.yaml`](../charts/edge/values.yaml): local rule storage, `enable_alertmanager_v2`, and `alertmanager_url: http://ais-kps-alertmanager.<namespace>.svc.cluster.local:9093`. That URL is the detail to check after any rename — it must match the Service the kube-prometheus-stack subchart creates under `fullnameOverride: ais-kps`. It was wrong once, inherited as `<release>-kube-prometheus-stack-alertmanager`: Loki stayed healthy, rules loaded, dashboards fine, and every pipeline alert silently never fired.
- **Metric alerts** — PromQL as `PrometheusRule` objects, evaluated by `ais-kps-prometheus`. `ruleSelectorNilUsesHelmValues: false`, so it picks up every rule in the namespace rather than only those carrying the subchart's own release label.

Mail routing is stated in `observability.stack.alerting.*`, with the password in the `alertmanager-smtp` Secret.

> **What the chart actually ships today (check before you rely on it).** `stack.enabled: true` installs kube-prometheus-stack's **own** recording/alert rules and stock dashboards, and Prometheus + Alertmanager as Grafana datasources — the pipeline rule bodies below are **not** in `charts/edge` and must be supplied. Two things to get right when you do: (1) the ruler reads `/etc/loki/rules`, while the loki subchart's rules sidecar watches ConfigMaps labelled `loki_rule` and writes them to `/rules` — point one at the other, or the rules load as nothing and nothing says so; (2) Alertmanager ships with kube-prometheus-stack's default route to the `null` receiver, so a receiver has to exist before any of this reaches a mailbox. [`alerting-architecture.md`](alerting-architecture.md) has the full wiring; [`alerting-diy.md`](alerting-diy.md) covers writing the expressions.

The table below is the **inventory** — read it as the set of signals worth alerting on, in whichever engine you use.

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
| `EdgeDiskLow` | warning | Loki | a stage's `stage_report.free_pct` below its own `min_free_pct` |
| `QuarantinedDataUnresolved` | warning | Loki | `originals.quarantine` `oldest_age_s` past its `alert_after_s` (an unmapped AET nobody has mapped) |
| `ManagementClusterDown` | critical | Prom | `up{job="apiserver"}==0` for 5m |
| `EdgeWorkerDisconnected` | critical | Prom | node `Ready` condition != true for 5m |
| `IngestPodCrashLoop` | warning | Prom | >3 restarts/1h in the release namespace |
| `NodeCountChanged` | info | Prom | `kube_node_info` changed in 10m |

**Swap:** re-express these in your platform's query language. The *definitions* are portable — each row's "fires when" column is the signal; the LogQL/PromQL is just one encoding of it. The log rules map cleanly to Splunk SPL / Elastic EQL / Datadog log monitors; the metric rules are plain PromQL over standard kube-state-metrics/apiserver series, so they run as-is on any Prometheus.

---

## 5. Swap matrix

| Bundled component | How it runs here | Drop-in replacements | What you must re-implement |
|---|---|---|---|
| **Vector** | hand-written DaemonSet, `observability.enabled` | Fluent Bit, Fluentd, Splunk fwd, Filebeat, Datadog, Alloy | collector config (source `/var/log/pods`, keep `namespace/app/component` labels) |
| **Loki** | `ais-loki`, SingleBinary, **filesystem** storage on a PVC | Splunk, Elastic/OpenSearch, Datadog Logs, your Loki | the LogQL rules in §4 → your query language |
| **Prometheus** | `ais-kps-prometheus`, PVC-backed | your Prometheus, VictoriaMetrics, Alloy, Datadog | nothing (standard scrape targets); PromQL rules port 1:1 to another Prometheus |
| **Alertmanager** | `ais-kps-alertmanager`; both engines push here | your Alertmanager, PagerDuty, Opsgenie, Datadog monitors | receiver/routing config — the default route is the `null` receiver |
| **Grafana** | `<release>-grafana`, **NodePort** at `http://<nodeIP>:<observability.stack.grafana.nodePort>` | your Grafana | add a Loki datasource (`http://ais-loki.<ns>.svc.cluster.local:3100` — only Prometheus and Alertmanager are provisioned); the pipeline dashboards (`pipeline-overview`, `session-timeline`, `edge-drilldown`) are LogQL over §2 — supply them as ConfigMaps labelled `grafana_dashboard=1`, or rebuild them in your own tool |

**Why Loki uses the filesystem and not S3:** there is no object store on a single node. This is the one place tier-1's observability genuinely diverges from a fleet deployment rather than just being wired differently — chunks, the index and the ruler's rules all land on a local-path PVC, which means retention is bounded by this node's disk and nothing spills anywhere.

---

## 6. Minimal recipes

**Drop the bundled stack entirely, ship logs to your backend:**

```yaml
observability:
  enabled: false          # no Vector either — you are running your own agent
  stack:
    enabled: false        # no Loki/Prometheus/Grafana/Alertmanager on the node
```
Then deploy your own log-agent DaemonSet reading `/var/log/pods` (JSON-decode `message`, carry `namespace/app/component`) and route to your store. Nothing in the pipeline changes; `./install.sh <site>` is the same three steps.

**Keep our Vector, but push to your Loki instead of hosting one:** `observability.enabled: true`, `observability.stack.enabled: false`, and set `observability.loki.endpoint` (with `observability.loki.clientCertSecret`/`caBundleSecret` if the endpoint is mTLS — that path is the tier-2 wiring and it is what `charts/edge/files/vector.yaml`, the file with the `tls:` block, exists for).

**Keep metrics in your Prometheus:** scrape kube-state-metrics/kubelet/apiserver; re-express the four metric alerts in §4 as `PrometheusRule` objects (or their equivalent) there. Remember there is no node-exporter here — see §3.

**Recreate the two must-have signals anywhere:**
- *Pipeline delivering?* — count of `Successfully uploaded all files in` per interval (should be non-zero when studies arrive).
- *Pipeline broken?* — upload-error lines rising while that success count is zero.

---

## 7. Ground-truth appendix

Reproduce the stack half of this document without installing anything:

```bash
helm template t1 charts/edge -n xnat-ingest -f sites/example-single/values.yaml \
    --set orthanc.deid.policyReviewed=true \
    --set observability.stack.enabled=true
```

- Vector attaches these stream labels: `app, cluster, component, container, level, namespace, node, pod`. Loki adds `service_name` itself; the live deployment also carried `stream`.
- `namespace`: one value for everything the chart installs — the release namespace, `xnat-ingest` by default — plus `kube-system` and `local-path-storage` from the node itself. `component` values: `dicom-receiver`, `group`, `assign`, `upload`, `data-policy`.
- Pipeline ServiceMonitors: **none** (no custom pipeline metrics). The eight that render belong to kube-prometheus-stack.
- Log format: pipeline pods run with `AIS_LOG_FORMAT=json` (`ingest.logFormat`, a functional setting — turning it off breaks monitoring, not just formatting). Orthanc mixes JSON hook events with native C++ server logs.
- Grafana is reached at `http://<nodeIP>:<nodePort>` — there is no ingress and no cert-manager on tier-1, so there is no TLS in front of it. Treat it as a LAN-only UI.
- Naming leftover to be aware of: the metric alert `EdgeWorkerDisconnected` is really "this node NotReady" on a single-node appliance (cosmetic name from the two-node era).
