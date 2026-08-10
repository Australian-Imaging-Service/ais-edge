# DIY — adding your own alert rules

This page is the "I want a new alert tomorrow" recipe. It assumes the
observability stack is installed — `observability.stack.enabled: true` in
`sites/<site>/values.yaml`, which is what turns on the `kube-prometheus-stack`
and `loki` subcharts of `charts/edge`. For the *why* of the two-tier split
between Prometheus and Loki, see
[`alerting-architecture.md`](alerting-architecture.md).

Everything runs in ONE namespace, `xnat-ingest`, on the one node. There is no
`observability` namespace and no management cluster to reach. `ais-kps` and
`ais-loki` are `fullnameOverride`s pinned in `charts/edge/values.yaml`, not
names derived from the release, so these object names are the same at every
site:

| Component | Object |
|---|---|
| Prometheus | `svc/ais-kps-prometheus:9090` |
| Alertmanager | `svc/ais-kps-alertmanager:9093` |
| Loki | `svc/ais-loki:3100`, `sts/ais-loki` |
| Grafana | `svc/<release>-grafana`, NodePort → `http://<nodeIP>:30030` |

`<release>` is the site name you passed to `./install.sh`.

## TL;DR

Five questions, each with a fast answer:

| Question | Answer |
|---|---|
| Where do I find metrics I could alert on? | Prometheus UI → Graph tab; Grafana → Explore → `Prometheus` data source |
| Where do I find log streams I could alert on? | Query Loki directly on `svc/ais-loki:3100`, or add the Loki data source to Grafana (§2b) |
| Where does the new rule file go? | A `PrometheusRule` object (Prometheus) OR a ConfigMap labelled `loki_rule` (Loki) — both in `xnat-ingest` |
| How do I apply? | `kubectl apply -f` for either. Values changes: `./install.sh <site>` |
| How do I send to a different inbox / Slack channel? | Add a route + receiver under `kube-prometheus-stack.alertmanager.config` in your site file; re-run `./install.sh <site>` |

---

## Step 1 — Pick the right rule engine

Decision tree:

```
Is the thing you want to alert on …

  ┌─ already a Prometheus metric? (kube_* pod/deployment state,
  │  kubelet_volume_stats_*, container_memory_*, up, …)
  │     → Prometheus rule. See "Prometheus rules" below.
  │
  ├─ a JSON log line emitted by group-orthanc / assign / upload /
  │  Orthanc's de-id hook / data-policy?
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
kubectl -n xnat-ingest port-forward svc/ais-kps-prometheus 9090:9090
# Open http://localhost:9090 in a browser
```

Useful pages:
- **Status → Targets** — every endpoint Prometheus is scraping. Click one
  to see the full label set + a sample of metric names.
- **Graph** tab — start typing a metric name; auto-complete shows every
  matching metric the stack knows about.

Quick-find from CLI:
```bash
kubectl -n xnat-ingest port-forward svc/ais-kps-prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/label/__name__/values' \
  | jq -r '.data[]' | grep -i volume
```

**What is actually scraped on a single k0s node** — shorter than a normal
cluster, and the gaps matter:
- All `kube_*` from kube-state-metrics (pod, node, deployment, PVC, …)
- Kubelet + cAdvisor: `kubelet_volume_stats_*`, `container_memory_*`,
  `container_cpu_*`
- `apiserver_*`, CoreDNS, and the stack's own self-metrics (Prometheus,
  Alertmanager, Grafana, the operator)
- `up` (per-target liveness — single most useful metric in the stack)

**No `node_*`.** `nodeExporter`, `kubeControllerManager`, `kubeScheduler`,
`kubeProxy` and `kubeEtcd` are all disabled in `charts/edge/values.yaml`: on a
single k0s node those endpoints either do not exist or are not reachable, and
left enabled they produce permanently-firing "target down" alerts, which trains
operators to ignore Alertmanager entirely.

> CAUTION: kube-prometheus-stack still ships its node-exporter *rules* —
> `NodeFilesystemAlmostOutOfSpace` and friends are loaded, visible on
> `/rules`, and permanently green. They select `node_filesystem_*` series that
> nothing produces here, so they can never fire. Do not read their green state
> as "the disk is fine". On tier-1 the disk signal comes from the data-policy
> DaemonSet's own log lines (§2b) and from `kubelet_volume_stats_*` for those
> PVCs the kubelet can measure.

**No `loki_*` either** — the Loki subchart's ServiceMonitor is not enabled, so
Loki is a log store here, not a scrape target.

### 2b. Find Loki streams + content

There is **no Loki data source in Grafana by default**: the stack only
provisions Prometheus and Alertmanager. Add it in your site file if you want to
use Explore, then re-run `./install.sh <site>`:

```yaml
kube-prometheus-stack:
  grafana:
    additionalDataSources:
      - name: Loki
        type: loki
        uid: loki
        access: proxy
        url: http://ais-loki.xnat-ingest.svc.cluster.local:3100
```

Grafana is on the NodePort — `http://<nodeIP>:30030`, no port-forward needed.
The admin password is generated by the chart unless you have wired
`grafana-admin-credentials` in; read the Secret the pod actually mounts:

```bash
kubectl -n xnat-ingest get secret <release>-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

Or skip Grafana entirely and query Loki over its own API, which is the same
thing the ruler evaluates against:

```bash
kubectl -n xnat-ingest port-forward svc/ais-loki 3100:3100
curl -s localhost:3100/loki/api/v1/labels | jq -r '.data[]'
curl -sG localhost:3100/loki/api/v1/query_range \
  --data-urlencode 'query={app="xnat-ingest", component="upload"}' \
  --data-urlencode 'limit=20' | jq -r '.data.result[].values[][1]'
```

The stream labels come from `charts/edge/files/vector-local.yaml` — Vector
promotes exactly these and nothing else, so these are the only labels a rule
can select on:

| Label | Example values | Why useful |
|---|---|---|
| `namespace` | `xnat-ingest`, `kube-system` | Coarse-grained filter. One node, so nearly everything you care about is `xnat-ingest` |
| `app` | `xnat-ingest`, `orthanc`, `data-policy`, `vector` | Single-service filter |
| `component` | `group`, `assign`, `upload`, `dicom-receiver`, `data-policy` | Distinguish pods within the same app — this is the one you usually want |
| `cluster` | `tier1-example` | Your `clusterLabel`. One value on tier-1, but rules carry it so a fleet's alerts stay distinguishable |
| `pod` / `container` / `node` | `t1-upload-…` | Narrow to one replica |
| `level` | `INFO`, `WARN`, `ERROR` | Severity filter (only set on JSON-formatted logs) |

Note that `namespace` no longer separates ingest from upload: on one node both
are in `xnat-ingest`. Use `component` instead.

Example LogQL queries:

```logql
# Everything the direct uploader has said in the last hour:
{app="xnat-ingest", component="upload"}

# Free disk on each declared data-policy stage:
{component="data-policy"} | json | event="stage_report"

# De-identified instances, with project and calling AET:
{app="orthanc"} | json | event="instance_deidentified"

# Anything containing "401" anywhere in the pipeline:
{namespace="xnat-ingest"} |~ "(?i)\\b401\\b"
```

JSON parsing: `| json` extracts every JSON field as a label you can match on.
Which fields exist depends on the emitter, and they are not uniform — Orthanc's
de-id hook and data-policy emit a real `event` key, while group/assign/upload
emit `level`/`logger`/`message` and put the detail inside `message`. See
[`observability-integration.md`](observability-integration.md) for the exact
per-component schema before you write a matcher; it is the difference between a
rule that fires and one that silently never can.

### 2c. Read the rules already loaded as templates

The stock kube-prometheus-stack rule set is installed and is a perfectly valid
copy-paste base:

```bash
kubectl -n xnat-ingest get prometheusrules
kubectl -n xnat-ingest get prometheusrule ais-kps-kubernetes-apps -o yaml | head -40

# Everything the Loki ruler has actually loaded:
kubectl -n xnat-ingest port-forward svc/ais-loki 3100:3100
curl -s localhost:3100/loki/api/v1/rules
```

Pick one whose shape matches your case and adapt the `expr` / `for` /
`labels` / `annotations`.

---

## Step 3 — Write the rule

### Prometheus rules — a `PrometheusRule` object

The Prometheus CR is rendered with `ruleSelector: {}` and
`ruleNamespaceSelector: {}` — because `ruleSelectorNilUsesHelmValues: false` is
set in `charts/edge/values.yaml`, it selects **every** `PrometheusRule` in
**every** namespace. So a rule needs no release label and no Helm involvement;
`kubectl apply` is enough.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: ais-edge-local
  namespace: xnat-ingest
spec:
  groups:
    - name: ais-edge-storage
      rules:
        - alert: DataVolumeNearlyFull
          # A PVC is over 85% full. /data filling up means staging + Orthanc
          # storage will soon stall.
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

The prometheus-operator watches the CRD and reloads Prometheus in place — no
restart, no `helm upgrade`. If you want the rule to be part of the release
instead of a hand-applied object, put the same YAML in your own file and apply
it from your site's runbook; `charts/edge` does not template rules for you.

### Loki ruler rules — a ConfigMap labelled `loki_rule`

The Loki subchart runs a `loki-sc-rules` sidecar next to `ais-loki` (kiwigrid
k8s-sidecar, `METHOD=WATCH`, `LABEL=loki_rule`). It watches ConfigMaps and
Secrets in the namespace carrying that label and writes each key as a file into
the sidecar's folder, which the `loki` container mounts at the same path.

> CAUTION, and this one is silent: as shipped the two halves do not agree.
> The sidecar writes into `/rules`, while `loki.loki.rulerConfig.storage.local.directory`
> is `/etc/loki/rules` — a path nothing mounts. Loki starts happily, the rules
> API returns an empty set, and no LogQL alert ever fires. Loki's local rule
> store also expects one sub-directory per tenant, and with `auth_enabled: false`
> the only tenant is `fake`. Align both in your site file before you rely on
> anything below:
>
> ```yaml
> loki:
>   sidecar:
>     rules:
>       folder: /rules/fake     # <ruler directory>/<tenant>
>   loki:
>     rulerConfig:
>       storage:
>         local:
>           directory: /rules
> ```

The rule itself is an ordinary Loki rule group:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ais-edge-loki-rules
  namespace: xnat-ingest
  labels:
    loki_rule: "1"        # what the sidecar selects on
data:
  ais-edge-orthanc.yaml: |
    groups:
      - name: ais-edge-orthanc-info
        interval: 1m
        rules:
          - alert: FirstDICOMReceivedToday
            # Day-start sanity check: did Orthanc de-identify anything in the
            # past hour? If it did, fire an informational alert so the operator
            # sees a sign of life.
            expr: |
              sum by (cluster) (
                count_over_time({app="orthanc"}
                  | json | event="instance_deidentified" [1h])
              ) > 0
            for: 0s
            labels:
              severity: info
              source: loki-ruler
            annotations:
              summary: "Edge {{ $labels.cluster }} received DICOMs in the last hour"
              description: "First sign-of-life check for the edge ingest path."
```

The ruler pushes what fires to
`http://ais-kps-alertmanager.<namespace>.svc.cluster.local:9093` — set in
`loki.loki.rulerConfig.alertmanager_url` in `charts/edge/values.yaml`. That
name follows the kube-prometheus-stack `fullnameOverride`, not the release
name; it has been wrong before, and the symptom was every LogQL alert
evaluating correctly and being posted to a hostname that does not resolve,
while Loki, the rules and the dashboards all looked healthy.

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

### Routing and receivers

Alertmanager belongs to the kube-prometheus-stack subchart, so its routing is
overridden from the same site file as everything else — there is no separate
alertmanager config file to render any more.

Where a site RECORDS its mail facts is `observability.stack.alerting.*` in
`sites/<site>/values.yaml`: `emailTo`, `emailFrom`, `smtpHost`, `smtpPort`,
`smtpUsername`, `requireTLS`. The password is never one of them — it lives in
the `alertmanager-smtp` Secret in `sites/<site>/secrets.enc.yaml` (keys
`username`, `password`), encrypted, and reaches the pod as a mounted file.

> CAUTION: the shipped default is kube-prometheus-stack's own config, whose
> route ends at `receiver: "null"`. A null receiver accepts every alert and
> delivers nothing, and there is no error anywhere — Alertmanager shows the
> alert firing and the inbox stays empty. Check what the release actually
> rendered before believing an alert is deliverable:
>
> ```bash
> kubectl -n xnat-ingest get secret alertmanager-ais-kps-alertmanager \
>   -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d
> ```

To state routes and receivers explicitly, put them in `sites/<site>/values.yaml`.
`alertmanagerSpec.secrets` is what mounts the SMTP Secret into the pod, at
`/etc/alertmanager/secrets/<secret name>/<key>`; without it the
`auth_password_file` below points at nothing:

```yaml
kube-prometheus-stack:
  alertmanager:
    alertmanagerSpec:
      secrets:
        - alertmanager-smtp
    config:
      route:
        group_by: [namespace, alertname]
        group_wait: 30s
        group_interval: 5m
        repeat_interval: 12h
        receiver: email-primary
        routes:
          # Order matters — Alertmanager walks top-to-bottom and stops at the
          # first match unless the route sets `continue: true`.
          - matchers: ['alertname = "Watchdog"']
            receiver: "null"
          - matchers: ['alertname = "MyNewAlert"']
            receiver: email-primary
      receivers:
        - name: "null"
        - name: email-primary
          email_configs:
            - to: ops@example.org
              from: ais-edge-alerts@example.org
              smarthost: smtp.example.org:587
              auth_username: ais-edge
              auth_password_file: /etc/alertmanager/secrets/alertmanager-smtp/password
              require_tls: true
```

---

## Step 4 — Apply

A rule object is applied on its own; anything that lives in the site file goes
through the installer, whose third step is the `helm upgrade --install`:

```bash
kubectl apply -f my-prometheus-rule.yaml     # PrometheusRule
kubectl apply -f my-loki-rules-configmap.yaml # Loki ConfigMap

./install.sh <site>          # values changes: alerting, retention, data sources
```

`install.sh` is idempotent and step-wise — it re-runs `helm upgrade --install`
with `sites/<site>/values.yaml`, so re-running with no changes is a no-op.
Neither rule path needs a restart: the prometheus-operator reloads Prometheus
when a `PrometheusRule` changes, and the sidecar rewrites the rule file within
seconds of the ConfigMap changing, which the ruler picks up on its next
evaluation.

To verify the new rule is loaded:

```bash
# Prometheus rules:
kubectl -n xnat-ingest port-forward svc/ais-kps-prometheus 9090:9090
# http://localhost:9090/rules — every loaded rule + its current state

# Loki rules — and the sidecar that had to deliver them:
kubectl -n xnat-ingest port-forward svc/ais-loki 3100:3100
curl -s localhost:3100/loki/api/v1/rules
kubectl -n xnat-ingest logs sts/ais-loki -c loki-sc-rules | tail -20

# Alertmanager routes:
kubectl -n xnat-ingest port-forward svc/ais-kps-alertmanager 9093:9093
# http://localhost:9093/#/status — shows the active config + receivers
```

An empty `/loki/api/v1/rules` with a sidecar log that says it wrote the file is
the directory mismatch from Step 3, not a bad rule.

---

## Step 5 — Trigger + observe

Easiest end-to-end test path:

1. **Cause the condition.** For pipeline alerts, run a drop test
   (POST a DICOM to Orthanc via REST — `kubectl -n xnat-ingest port-forward
   svc/<release>-orthanc 8042:8042`, then `curl -X POST
   http://localhost:8042/instances --data-binary @file.dcm`). For metric
   alerts, drive the metric (delete a pod to flip its readiness, fill a disk).
2. **Watch Alertmanager fire.**
   ```
   kubectl -n xnat-ingest port-forward svc/ais-kps-alertmanager 9093:9093
   ```
   The **Alerts** tab shows every firing alert with all its labels.
3. **Confirm delivery.** Check the inbox / Slack channel. If nothing
   arrives, the chain to investigate is:
   - Alertmanager UI shows the alert firing? → yes, problem is downstream
   - Is the route reaching a real receiver, or the default `"null"`? (§3)
   - Alertmanager logs:
     `kubectl -n xnat-ingest logs -l app.kubernetes.io/name=alertmanager -c alertmanager`
   - SMTP-specific: most "no email" issues are App-Password rot, SPF/DKIM
     rejection, or `require_tls: false` against a TLS-only server. For Gmail the
     password must be an App Password — a 2FA account rejects the account
     password with `535 BadCredentials`, and the only symptom is alerts that
     never arrive.

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
  sum (rate({namespace="xnat-ingest"} |= "literal" [1m])) > 0
for: 0s
```

### "Alert when X stops happening" (heartbeat / dead-man's switch)
```yaml
# absent_over_time, not PromQL's absent() — the Loki ruler speaks LogQL and
# will reject the rule at load time, which shows up as the rule simply not
# being in /loki/api/v1/rules.
expr: |
  absent_over_time({app="xnat-ingest", component="upload"}
    |= "Successfully uploaded" [10m])
for: 5m
```

### "Alert when X rate exceeds Y"
```yaml
expr: |
  sum by (cluster) (
    rate({namespace="xnat-ingest"} |= "error" [5m])
  ) > Y
for: 5m
```

### "Alert when X happened AND Y didn't happen in the same window"
```yaml
expr: |
  (sum by (cluster) (count_over_time({namespace="xnat-ingest"} |= "fail" [15m])) > 0)
  and ignoring (cluster)
  (sum by (cluster) (count_over_time({namespace="xnat-ingest"} |= "success" [15m])) == 0)
for: 15m
```

### "Alert when the node is running out of disk"
There is no node-exporter here, so this is a LogQL rule over the data-policy
DaemonSet's `stage_report` events — one per declared stage, per pass, carrying
`free_pct` and (where the stage declares one) its own `min_free_pct` on the
same line, so the reading and the threshold it was judged against are never
separated:

```yaml
expr: |
  sum by (cluster, stage) (
    last_over_time({component="data-policy"}
      | json | event="stage_report" | unwrap free_pct [10m])
  ) < 10
for: 10m
```

Stage names come from `dataPolicy` in the site file: `originals.facilityBackup`,
`originals.quarantine`, `derived.orthancStorage`, `derived.grouped`,
`derived.assigned`. The facility backup is the one that matters most — it is
the only copy of the identifiable originals, and nothing else on this node will
notice it filling up.

### "Alert when a PVC is filling up"
```yaml
expr: |
  kubelet_volume_stats_available_bytes /
  kubelet_volume_stats_capacity_bytes < 0.15
for: 10m
```

### "Alert when a deployment has no ready replicas"
```yaml
expr: |
  kube_deployment_status_replicas_ready{namespace="xnat-ingest"} < 1
for: 5m
```

---

## Where things live (quick map)

| File | What's in it |
|---|---|
| `sites/<site>/values.yaml` | `observability.stack.alerting.*` (inbox, sender, SMTP host/port/user), `observability.stack.grafana.nodePort`, `observability.stack.retentionDays`, and any `kube-prometheus-stack:` / `loki:` overrides you add |
| `sites/<site>/secrets.enc.yaml` | SOPS-encrypted. Secret `alertmanager-smtp` (`username`, `password`) and `grafana-admin-credentials` (`admin-user`, `admin-password`), both in `xnat-ingest` |
| `charts/edge/values.yaml` → `kube-prometheus-stack:` | `fullnameOverride: ais-kps`, Prometheus retention + storage, Alertmanager storage, and the exporters disabled because they do not exist on one k0s node |
| `charts/edge/values.yaml` → `loki:` | `fullnameOverride: ais-loki`, SingleBinary, filesystem storage on a PVC, retention, and `rulerConfig` including `alertmanager_url` |
| `charts/edge/Chart.yaml` | The two subchart pins and `condition: observability.stack.enabled` |
| `charts/edge/charts/*.tgz` | The vendored charts themselves — kube-prometheus-stack 87.19.2, loki 7.1.0. Nothing is fetched at install time |
| `charts/edge/files/vector-local.yaml` | The Loki stream labels every LogQL rule selects on. Change a label name here and every rule that used it stops matching, silently |
| `scripts/site-secrets.sh` | `edit` / `encrypt` / `apply` for the SMTP and Grafana Secrets |
| `./install.sh <site>` | Step 3 re-runs `helm upgrade --install`, which is how any values change reaches the cluster |
