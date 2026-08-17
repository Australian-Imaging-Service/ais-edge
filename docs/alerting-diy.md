# DIY — adding your own alert rules

The "I want a new alert tomorrow" recipe. Assumes the mgmt chart is installed
with `observability.enabled: true` (the default). For the *why* of the
Prometheus/Loki split, see [`alerting-architecture.md`](alerting-architecture.md).

## TL;DR

| Question | Answer |
|---|---|
| Where do I find metrics I could alert on? | Prometheus UI → Graph tab; Grafana → Explore → `Prometheus` |
| Where do I find log streams I could alert on? | Grafana → Explore → `Loki` → **Log labels** picker |
| Where does the new rule go? | `charts/mgmt/files/prometheus-rules/*.yaml` (Prometheus) or `charts/mgmt/files/loki-ruler-rules.yaml` (Loki) |
| How do I apply? | `helm upgrade mgmt charts/mgmt -n ais-mgmt -f sites/<site>/values.yaml` |
| How do I route to a different receiver? | Add a route in `charts/mgmt/files/alertmanager-config.yaml`, then upgrade |

---

## Step 1 — Pick the right rule engine

```
Is the thing you want to alert on …

  ┌─ already a Prometheus metric? (CPU, memory, kube_node_status,
  │  cert-manager certificate expiry, etc.)
  │     → Prometheus rule.
  │
  ├─ a JSON log line from xnat-ingest / s3-uploader / Orthanc /
  │  kube-prometheus components?
  │     → Loki ruler rule.
  │
  └─ raw text emitted somewhere?
        → Loki, with `|~ regex` instead of `| json | field=value`.
```

Why the split: mgmt's Prometheus cannot scrape edge pods (the konnectivity
tunnel is one-way), but every edge pod's logs already reach Loki via Vector.
Pipeline-event alerts live in Loki; K8s-resource-state alerts live in
Prometheus.

---

## Step 2 — Discover what to alert on

### 2a. Find Prometheus metrics

```bash
kubectl -n ais-mgmt port-forward svc/mgmt-kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090 → Graph tab, or Status → Targets
```

```bash
# grep metric names by pattern
curl -s 'http://localhost:9090/api/v1/label/__name__/values' \
  | jq -r '.data[]' | grep -i seaweed
```

Already shipped: `kube_*` (kube-state-metrics), `container_*` (the kubelet's
cAdvisor, `kubelet: {enabled: true}`), `certmanager_*` (cert-manager, via the
ServiceMonitor in `charts/mgmt/templates/cert-manager-monitoring.yaml`),
`SeaweedFS_*` (SeaweedFS's own exporter, via the ServiceMonitor in
`charts/mgmt/templates/observability.yaml`), `loki_*` (the Loki subchart's
`monitoring.serviceMonitor`), and `up` — the single most useful metric in the
stack.

Three things you are likely to reach for are **not** here, and each has already
cost someone an alert that could never fire:

| Reached for | Reality |
|---|---|
| `node_*` | node-exporter is off on purpose — `prometheus-node-exporter: {enabled: false}` and `nodeExporter: {enabled: false}` in `charts/mgmt/values.yaml`, "host metrics off, matching the edges". For pod-level CPU/memory use the cAdvisor `container_*` series instead. |
| `nginx_ingress_controller_*` | The pinned ingress-nginx 4.15.1 ships `controller.metrics.enabled: false`, and the `ingress-nginx:` block in `charts/mgmt/values.yaml` does not override it — nothing scrapes the controller, so there are no request/latency series and no ServiceMonitor for them. |
| `cert_manager_*`, `seaweedfs_*` | Right exporters, wrong spelling. cert-manager's prefix is `certmanager_` (no underscore after `cert`) and SeaweedFS's is capitalised `SeaweedFS_`. PromQL is case-sensitive, so a misspelt name selects nothing and the rule is green for life. |

Also absent by choice: `defaultRules: {create: false}`, so **none** of
kube-prometheus-stack's own alert pack is installed. `KubePodCrashLooping`,
`KubeletDown` and friends are not quietly covering you; the nine Prometheus
alerts in `charts/mgmt/files/prometheus-rules/` are all there is.

Before you trust a new expression, run `scripts/check-alert-inputs.sh` — it
exists for exactly this class of mistake. It extracts every metric name the
shipped rules reference and asks the LIVE Prometheus whether each one has any
series (`--strict` to exit non-zero in CI). promtool unit tests cannot catch
this: they supply the series themselves, so they prove the logic and say
nothing about whether the metric exists in our cluster.

### 2b. Find Loki streams

```bash
kubectl -n ais-mgmt port-forward svc/mgmt-grafana 3000:80
# Explore → data source: Loki → Log labels picker
```

| Label | Example values | Why useful |
|---|---|---|
| `namespace` | `xnat-ingest`, `xnat-upload`, `ais-mgmt`, `cert-manager` | Coarse filter |
| `app` | `xnat-ingest`, `orthanc`, `seaweedfs`, `vector` | Per-service filter |
| `component` | `group`, `assign`, `s3-uploader`, `upload` | Distinguish pods in the same app |
| `cluster` | `mgmt`, `edge-dev`, … | Distinguish sites — see the CAUTION below |
| `level` | `INFO`, `WARN`, `ERROR` | JSON-formatted logs only |

```logql
# upload_completed events on every edge, last 1h
{namespace="xnat-ingest", component="s3-uploader"} | json | event="upload_completed"

# grouped by cluster (table panel)
sum by (cluster) (
  count_over_time({namespace="xnat-ingest", component="s3-uploader"}
    | json | event="upload_completed" [1h])
)
```

`| json` extracts every field as a matchable label. Text-only logs use
`|~ "regex"` instead.

### 2c. Copy an existing rule as a template

```bash
ls charts/mgmt/files/prometheus-rules/         # by severity
sed -n '1,40p' charts/mgmt/files/loki-ruler-rules.yaml
```

---

## Step 3 — Write the rule

### Prometheus — `charts/mgmt/files/prometheus-rules/{critical,warning,info,cert-sync}.yaml`

```yaml
- alert: SeaweedFSS3ErrorRate
  expr: |
    sum(rate(SeaweedFS_s3_request_total{code=~"5.."}[5m])) > 0.5
  for: 5m
  labels: {severity: warning}
  annotations:
    summary: "SeaweedFS S3 is returning many 5xx responses"
```

Two things about that expression are deliberate, and copying either one wrong
is the usual way a new rule ends up permanently green:

- **`SeaweedFS_`, capitalised.** It is the exporter's own spelling and PromQL
  is case-sensitive. Check any metric name against a live Prometheus (§2a, or
  `scripts/check-alert-inputs.sh`) before committing the rule.
- **No `sum by (cluster)`.** *Nothing in mgmt Prometheus carries a `cluster`
  label* — not KSM, not cert-manager, not SeaweedFS, and the rules here never
  set one statically. `charts/mgmt/files/alertmanager-config.yaml` says so at
  length, in the comment on the inhibit rules that used to key on it. `by
  (cluster)` therefore collapses to a single empty-labelled series: harmless
  here, but it silently defeats any per-site grouping you thought you were
  getting. Grouping per site is a **Loki**-side idea — Vector sets `cluster` on
  log streams, so the LogQL rules below can and do use it.

Rendered into a `PrometheusRule` object; the operator picks it up via CRD
watch, no restart needed. `scripts/ci/promtool.sh` globs `*.yaml` in that
directory, runs `promtool check rules` over each, and runs any test in
`charts/mgmt/files/prometheus-rules/tests/` — add a test alongside a new rule.
Splitting by severity is a convention, not a requirement: `cert-sync.yaml` is a
fourth file grouped by *subject* instead, because its two alerts
(`CertSyncStale`, `CertSyncNeverSucceeded`) are one mechanism at two
severities and are easier to reason about together.

### Loki — `charts/mgmt/files/loki-ruler-rules.yaml`

```yaml
- name: ais-edge-example
  interval: 1m
  rules:
    - alert: FirstDICOMReceivedToday
      expr: |
        sum by (cluster) (count_over_time(
          {namespace="xnat-ingest", app="orthanc"} |~ "(?i)new stored instance" [1h])) > 0
      for: 0s
      labels: {severity: info, source: loki-ruler}
      annotations:
        summary: "Edge {{ $labels.cluster }} received DICOMs in the last hour"
```

LogQL primer:

| Operator | Meaning |
|---|---|
| `{namespace="x"}` | Stream selector |
| `\|= "literal"` | Contains substring |
| `\|~ "regex"` | Matches regex (`(?i)` for case-insensitive) |
| `\| json` | Parse JSON; fields become matchable labels |
| `count_over_time(<sel> [Nm])` | Line count in the last N minutes |
| `sum by (label) (<query>)` | Aggregate across a label |

> **CAUTION — absence needs `unless`, not `== 0`.** An empty LogQL result is
> EMPTY, not a series carrying `0`. `X and (Y == 0)` is silent in exactly the
> case it should fire. Use `X unless on (cluster) Y` — see
> `XNATUploadFailingForAllSessions` for the pattern. `scripts/ci/promtool.sh`
> rejects `== 0` and unlabelled `ignoring(...)` joins in this file.

> **CAUTION — pin every join to `on (cluster[, session])`.** `ignoring
> (cluster)` matches series across sites: one edge's failures can be paired
> with a different edge's successes. Always name what the join is keyed on.

### Per-alert routing override

`charts/mgmt/files/alertmanager-config.yaml`:

```yaml
route:
  routes:
    - matchers: [alertname = "MyNewAlert"]
      receiver: email-primary
      continue: false
    # existing routes follow
```

Alertmanager walks top-to-bottom and stops at the first match when
`continue: false`.

---

## Step 4 — Apply

```bash
helm upgrade mgmt charts/mgmt -n ais-mgmt -f sites/<site>/values.yaml
```

Prometheus and Loki reload rule configs without a restart (operator-watched).

```bash
# Prometheus rules + state
kubectl -n ais-mgmt port-forward svc/mgmt-kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090/rules

# Loki rules — no shell in the container; port-forward and curl instead
kubectl -n ais-mgmt port-forward svc/mgmt-loki 3100:3100 &
curl -s http://localhost:3100/loki/api/v1/rules

# Alertmanager routes
kubectl -n ais-mgmt port-forward svc/mgmt-kube-prometheus-stack-alertmanager 9093:9093
# http://localhost:9093/#/status
```

---

## Step 5 — Trigger + observe

1. **Cause the condition** — a drop test for pipeline alerts, or drive the
   metric directly (delete a pod, fill a disk) for K8s-level ones.
2. **Watch it fire** in the Alertmanager UI (port-forward above), Alerts tab.
3. **Confirm delivery.** If nothing arrives:
   - Alertmanager UI shows it firing? If not, the problem is upstream (rule
     never fired) — check `/rules` for its state.
   - `kubectl -n ais-mgmt logs sts/alertmanager-mgmt-kube-prometheus-stack-alertmanager -c alertmanager`
   - SMTP: most silent failures are an App-Password issue, or
     `smtpRequireTLS: false` against a TLS-only relay.

### Silencing during testing

```bash
kubectl -n ais-mgmt port-forward svc/mgmt-kube-prometheus-stack-alertmanager 9093:9093
amtool silence add --alertmanager.url=http://localhost:9093 \
  alertname=MyNewAlert --duration=1h --comment="testing"
```

---

## Step 6 — Common patterns

**Alert when X happens:**
```yaml
expr: sum (rate({namespace="X"} |= "literal" [1m])) > 0
for: 0s
```

**Alert when X stops happening (dead-man's switch):**
```yaml
expr: absent(rate({namespace="X"} |= "heartbeat-line" [10m]))
for: 5m
```

**Alert when X happened and Y did not, same window — the CORRECT form:**
```yaml
expr: |
  (sum by (cluster) (count_over_time({namespace="X"} |= "fail" [15m])) > 0)
  unless on (cluster)
  (sum by (cluster) (count_over_time({namespace="X"} |= "success" [15m])) > 0)
for: 15m
```
See the CAUTION in Step 3 for why `and ignoring (...) == 0` is wrong here.

**Cert expiring soon:**
```yaml
# certmanager_, NOT cert_manager_ — the exporter's prefix has no underscore
# after "cert". The misspelt version selects nothing and never fires.
expr: (certmanager_certificate_expiration_timestamp_seconds - time()) / 86400 < 14
for: 1h
```
The shipped `CertificateExpiringSoon` (`prometheus-rules/warning.yaml`) is the
same expression at 60 days; copy it rather than this snippet if you want the
label and annotation wiring too.

---

## Where things live

| File | What's in it |
|---|---|
| `sites/<site>/secrets.enc.yaml` | `alertmanager-smtp` Secret; SMTP host/port live in `values.yaml` under `observability.alerting` |
| `charts/mgmt/files/alertmanager-config.yaml` | Routes, receivers, inhibit rules |
| `charts/mgmt/files/alertmanager-slack-receivers.yaml` | Slack receivers, spliced in only when a webhook Secret exists |
| `charts/mgmt/files/prometheus-rules/{critical,warning,info}.yaml` | Prometheus rules, by severity |
| `charts/mgmt/files/prometheus-rules/cert-sync.yaml` | `CertSyncStale` + `CertSyncNeverSucceeded` — grouped by subject rather than severity, because they are one mechanism at two severities. `promtool.sh` globs `*.yaml` here, so a new file needs no wiring |
| `charts/mgmt/files/prometheus-rules/tests/*.yaml` | promtool unit tests — one per rule file, `cert-sync_test.yaml` included |
| `charts/mgmt/files/loki-ruler-rules.yaml` | Every log-derived alert |
| `charts/mgmt/values.yaml` | Retention, scrape interval, storage size |
