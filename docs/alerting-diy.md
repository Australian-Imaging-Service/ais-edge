# DIY — adding your own alert rules

This page is the "I want a new alert tomorrow" recipe. It assumes the
observability stack is installed (`scripts/02d-install-observability.sh`).
For the *why* of the two-tier split between Prometheus and Loki, see
[`alerting-architecture.md`](alerting-architecture.md).

## TL;DR

Five questions, each with a fast answer:

| Question | Answer |
|---|---|
| Where do I find metrics I could alert on? | Prometheus UI → Graph tab; Grafana → Explore → `Prometheus` data source |
| Where do I find log streams I could alert on? | Grafana → Explore → `Loki` data source; click the **Log labels** picker |
| Where does the new rule file go? | `manifests/01-management/observability/alerts/*.yaml` (Prometheus) OR append to `loki-ruler-rules.yaml` (Loki) |
| How do I apply? | Re-run `bash scripts/02d-install-observability.sh` (idempotent) |
| How do I send to a different inbox / Slack channel? | Add a route in `alertmanager-config.yaml.tpl`; re-run step 02d |

---

## Step 1 — Pick the right rule engine

Decision tree:

```
Is the thing you want to alert on …

  ┌─ already a Prometheus metric? (CPU, memory, kube_node_status,
  │  kubelet_volume_stats_*, etc.)
  │     → Prometheus rule. See "Prometheus rules" below.
  │
  ├─ a JSON log line emitted by xnat-ingest group-orthanc / assign / upload /
  │  Orthanc / kube-prometheus components?
  │     → Loki ruler rule. See "Loki ruler rules" below.
  │
  └─ raw text emitted somewhere?
        → Still Loki, but you'll need to grep with `|~` regex
          instead of `| json | <field>=<value>`.
```

The split exists because pipeline events are JSON log lines (the natural source
of truth for "did an upload fail?"), while K8s object state is already a
Prometheus metric. Pipeline-event alerts therefore live in the Loki ruler;
K8s-resource-state alerts live in Prometheus. See
[`alerting-architecture.md`](alerting-architecture.md) for the full rationale.

---

## Step 2 — Discover what to alert on

### 2a. Find Prometheus metrics

Port-forward Prometheus and use its built-in expression browser:

```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# Open http://localhost:9090 in a browser
```

Useful pages:
- **Status → Targets** — every endpoint Prometheus is scraping. Click one
  to see the full label set + a sample of metric names.
- **Graph** tab — start typing a metric name; auto-complete shows every
  matching metric the stack knows about.

Quick-find from CLI:
```bash
# List all metric names matching a pattern
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/label/__name__/values' \
  | jq -r '.data[]' | grep -i volume
```

The metrics already shipped on this cluster include:
- All `kube_*` from kube-state-metrics (pod, node, deployment, PVC, …)
- All `node_*` from node-exporter (cpu, memory, disk, network, …)
- `kubelet_volume_stats_*` (PVC usage for Loki / Prometheus / Grafana volumes)
- `loki_*` (ingestion rate, ruler eval status)
- `up` (per-target liveness — single most useful metric in the stack)

### 2b. Find Loki streams + content

Port-forward Grafana:
```bash
kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80
# Open http://localhost:3000  — login as admin / <GRAFANA_ADMIN_PASSWORD>
# Explore → data source: Loki → Log browser
```

Click **Log labels** to see every label your logs are indexed by. On
this setup the high-value labels are:

| Label | Example values | Why useful |
|---|---|---|
| `namespace` | `xnat-ingest`, `xnat-upload`, `observability`, `kube-system` | Coarse-grained filter |
| `app` | `xnat-ingest`, `orthanc`, `prometheus`, … | Single-service filter |
| `component` | `group`, `assign`, `upload`, `dicom-receiver` | Distinguish pods within the same app |
| `cluster` | `mgmt` | Single node — one value |
| `level` | `INFO`, `WARN`, `ERROR` | Severity filter (only set on JSON-formatted logs) |

Example LogQL queries you can paste into Explore:

```logql
# All upload_completed events in the last 1h:
{namespace="xnat-upload", component="upload"}
  | json | event="upload_completed"

# Completed uploads per hour (table panel):
count_over_time({namespace="xnat-upload", component="upload"}
  | json | event="upload_completed" [1h])

# Anything containing "401" anywhere in the upload pod:
{namespace="xnat-upload"} |~ "(?i)\\b401\\b"
```

JSON parsing: our event-shaped logs (group, assign, upload, kube-prometheus
operator, etc.) all use `level`, `logger`, `message` / `event` keys. `| json` extracts
every JSON field as a label you can match on. Raw text logs use `|~ "regex"`
instead.

### 2c. Read the existing rules as templates

Every rule already on this cluster is a perfectly valid copy-paste base:

```bash
ls manifests/01-management/observability/alerts/    # Prometheus, by severity
sed -n '1,30p' manifests/01-management/observability/loki-ruler-rules.yaml  # Loki
```

Pick one whose shape matches your case and adapt the `expr` / `for` /
`labels` / `annotations`.

---

## Step 3 — Write the rule

### Prometheus rules — `manifests/01-management/observability/alerts/*.yaml`

One file per severity (`critical.yaml`, `warning.yaml`, `info.yaml`).
Append a new entry under the existing `groups:` block. Minimal example:

```yaml
- alert: DataVolumeNearlyFull
  # the node's data PVC (or any observability PVC) is over 85% full.
  # /data filling up means staging + Orthanc storage will soon stall.
  expr: |
    (
      kubelet_volume_stats_used_bytes
      / kubelet_volume_stats_capacity_bytes
    ) > 0.85
  for: 10m      # debounce — must be true for 10 minutes before firing
  labels:
    severity: warning
  annotations:
    summary: "A persistent volume is over 85% full"
    description: |
      PVC {{ $labels.persistentvolumeclaim }} is {{ $value | humanizePercentage }}
      full. Expand the disk or clear the backlog.
```

These files are applied directly by `kubectl apply -f <dir>` in step
`02d`. The kube-prometheus-stack operator picks them up via the
`PrometheusRule` CRD watcher (annotations + labels matter — keep the
existing file structure).

### Loki ruler rules — `manifests/01-management/observability/loki-ruler-rules.yaml`

One big ConfigMap with multiple rule groups inside its `data:` block.
Append a new group at the end. Minimal example:

```yaml
- name: ais-edge-orthanc-info
  interval: 1m
  rules:
    - alert: FirstDICOMReceivedToday
      # Day-start sanity check: did Orthanc receive anything in the past hour?
      # If it did, fire informational alert so the operator sees a sign of life.
      expr: |
        sum by (cluster) (
          count_over_time({namespace="xnat-ingest", app="orthanc"}
            |~ "(?i)new stored instance" [1h])
        ) > 0
      for: 0s
      labels:
        severity: info
        source: loki-ruler
      annotations:
        summary: "Edge {{ $labels.cluster }} received DICOMs in the last hour"
        description: "First sign-of-life check for the edge ingest path."
```

LogQL primer:
| Operator | Meaning |
|---|---|
| `{namespace="x"}` | Stream selector. Matches all logs with this label. |
| `|= "literal"` | Contains substring (case-sensitive) |
| `|~ "regex"` | Matches PCRE regex (case-insensitive with `(?i)` prefix) |
| `\| json` | Parses each log line as JSON; subsequent stages can match on extracted fields |
| `\| field="value"` | After `\| json`, filter by extracted field value |
| `count_over_time(<selector> [Nm])` | Count matching lines in last N minutes |
| `rate(<selector> [Ns])` | Matching lines per second over the last N seconds |
| `sum by (label) (<query>)` | Aggregate across the named label |

### Per-alert routing override

By default Alertmanager routes by severity. To send a specific alert
to a different receiver regardless of severity, add a matcher block in
`manifests/01-management/observability/alertmanager-config.yaml.tpl`:

```yaml
route:
  ...
  routes:
    - matchers:
        - alertname = "MyNewAlert"
      receiver: email-primary
      continue: false
    # … existing routes follow
```

Order matters — Alertmanager walks top-to-bottom and stops at the first
match (when `continue: false`).

---

## Step 4 — Apply

```bash
bash scripts/02d-install-observability.sh
```

The script is idempotent: it re-renders the Alertmanager Secret + Loki
ruler ConfigMap and reloads the running pods. Re-running with no
changes is a no-op. With changes, Prometheus + Loki reload their
rule configs without a restart (operator-watched).

To verify the new rule is loaded:

```bash
# Prometheus rules:
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090/rules — every loaded rule + its current state

# Loki rules:
kubectl -n observability exec loki-0 -c loki -- /bin/sh -c \
  'wget -qO- http://localhost:3100/loki/api/v1/rules'

# Alertmanager routes:
kubectl -n observability port-forward svc/alertmanager-operated 9093:9093
# http://localhost:9093/#/status — shows the active config + receivers
```

---

## Step 5 — Trigger + observe

Easiest end-to-end test path:

1. **Cause the condition.** For pipeline alerts, run a drop test
   (POST a DICOM to Orthanc via REST). For metric alerts, drive the
   metric (delete a pod to flip its readiness, fill a disk, etc.).
2. **Watch Alertmanager fire.**
   ```
   kubectl -n observability port-forward svc/alertmanager-operated 9093:9093
   ```
   The **Alerts** tab shows every firing alert with all its labels.
3. **Confirm delivery.** Check the inbox / Slack channel. If nothing
   arrives, the chain to investigate is:
   - Alertmanager UI shows the alert firing? → yes, problem is downstream
   - Alertmanager logs: `kubectl -n observability logs alertmanager-kube-prometheus-stack-alertmanager-0 -c alertmanager`
   - SMTP-specific: most "no email" issues are App-Password rot, SPF/DKIM
     rejection, or `ALERT_SMTP_REQUIRE_TLS=false` against a TLS-only server.

### Silencing during testing

Don't want every prior firing alert to spam during debugging:

```bash
# Open Alertmanager UI → "New Silence" → matchers + duration
# Or via amtool:
amtool silence add --alertmanager.url=http://localhost:9093 \
  alertname=MyNewAlert --duration=1h --comment="testing"
```

---

## Step 6 — Common patterns cheat sheet

### "Alert when X happens"
```yaml
expr: |
  sum (rate({namespace="X"} |= "literal" [1m])) > 0
for: 0s
```

### "Alert when X stops happening" (heartbeat / dead-man's switch)
```yaml
expr: |
  absent(rate({namespace="X"} |= "heartbeat-line" [10m]))
for: 5m
```

### "Alert when X rate exceeds Y"
```yaml
expr: |
  sum by (cluster) (
    rate({namespace="X"} |= "error" [5m])
  ) > Y
for: 5m
```

### "Alert when X happened AND Y didn't happen in the same window"
```yaml
expr: |
  (sum by (cluster) (count_over_time({namespace="X"} |= "fail" [15m])) > 0)
  and ignoring (cluster)
  (sum by (cluster) (count_over_time({namespace="X"} |= "success" [15m])) == 0)
for: 15m
```

### "Alert when a metric crosses a threshold"
```yaml
expr: |
  node_filesystem_avail_bytes{mountpoint="/data"} /
  node_filesystem_size_bytes{mountpoint="/data"} < 0.15
for: 10m
```

### "Alert when a deployment has no ready replicas"
```yaml
expr: |
  kube_deployment_status_replicas_ready{deployment=~"orthanc|xnat-ingest-.*"} < 1
for: 5m
```

---

## Where things live (quick map)

| File | What's in it |
|---|---|
| `config/management.env` | `ALERT_*` env vars (email address, SMTP, Slack webhook) |
| `manifests/01-management/observability/alertmanager-config.yaml.tpl` | Routes + receivers + inhibit rules |
| `manifests/01-management/observability/alerts/critical.yaml` | Prometheus rules for `severity: critical` |
| `manifests/01-management/observability/alerts/warning.yaml` | Prometheus rules for `severity: warning` |
| `manifests/01-management/observability/alerts/info.yaml` | Prometheus rules for `severity: info` |
| `manifests/01-management/observability/loki-ruler-rules.yaml` | Every log-derived alert (one ConfigMap, multiple rule groups) |
| `manifests/01-management/observability/kube-prometheus-stack-values.yaml.tpl` | Stack-wide Prometheus tuning (retention, scrape intervals) |
| `manifests/01-management/observability/loki-values.yaml.tpl` | Loki tuning (ruler eval interval, retention, filesystem storage) |
| `scripts/02d-install-observability.sh` | The idempotent applier for everything in this directory |
