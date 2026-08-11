# Prometheus

## Overview

[Prometheus](https://prometheus.io/) is the de-facto standard time-series
database and monitoring toolkit. It pulls metrics from HTTP `/metrics`
endpoints on a schedule, stores them locally, evaluates alerting and
recording rules, and exposes a query language (PromQL) used by Grafana
and Alertmanager.

## Role in this stack

The metrics half of the optional local observability stack. It exists only when
`observability.stack.enabled: true` in `sites/<site>/values.yaml` — that key gates
the vendored `kube-prometheus-stack` dependency in `charts/edge/Chart.yaml`. Do not
confuse it with `observability.enabled`, which is a separate, older switch meaning
only "run Vector".

On the single node Prometheus scrapes every target directly (there is no
konnectivity boundary). What it actually scrapes comes entirely from the
ServiceMonitors kube-prometheus-stack ships:

- **kube-state-metrics** (`<release>-kube-state-metrics`) — pod restarts,
  Deployment/DaemonSet status, PVC capacity
- **kubelet**, including cAdvisor — container CPU / memory / network, plus
  `kubelet_volume_stats_*` for PVC fill
- **kube-apiserver** and **CoreDNS**
- **the stack's own components** — `ais-kps-prometheus`, `ais-kps-alertmanager`,
  `ais-kps-operator`, `<release>-grafana`

What it deliberately does *not* scrape matters as much:

- **`nodeExporter`, `kubeControllerManager`, `kubeScheduler`, `kubeProxy` and
  `kubeEtcd` are disabled.** Those targets do not exist on a single k0s node, and
  left on each one contributes a permanently-firing "target down" alert — an
  Alertmanager that is always red trains operators to ignore it. The cost is that
  there is no node-level CPU / memory / **disk** metric at all: the node-exporter
  mixin rules load but never have series behind them. Disk pressure on the
  pipeline volumes is reported by the data-policy DaemonSet as a JSON log field
  (`stage_report.free_pct`), and `EdgeDiskLow` is therefore a **Loki ruler** alert,
  not a Prometheus one.
- **Loki.** The `loki` subchart's ServiceMonitor is not enabled, so `ais-loki`'s
  own `/metrics` is not collected.
- **The pipeline pods.** Orthanc, group-orthanc, assign, upload and data-policy
  expose no `/metrics` endpoint; their telemetry is the JSON event stream Vector
  ships to Loki. Prometheus therefore sees the pipeline only as Kubernetes object
  state, through kube-state-metrics.

It evaluates **two** sets of `PrometheusRule` objects. First, the ones
**kube-prometheus-stack itself ships** — the `KubeNodeNotReady` /
`KubePodCrashLooping` / `KubePodNotReady` / `KubePersistentVolumeFillingUp`
families. Second, three that **`charts/edge` adds itself**, rendered by
[`charts/edge/templates/observability.yaml`](../../charts/edge/templates/observability.yaml),
which emits one `PrometheusRule` per file in `charts/edge/files/prometheus-rules/`
— one object per severity, matching how the rules are authored, so the object
names are the same at every site:

| Object | Source file | Alerts |
|---|---|---|
| `ais-edge-critical` | `files/prometheus-rules/critical.yaml` | `KubernetesAPIServerDown`, `NodeNotReady` |
| `ais-edge-warning` | `files/prometheus-rules/warning.yaml` | `IngestPodCrashLoop` |
| `ais-edge-info` | `files/prometheus-rules/info.yaml` | `NodeCountChanged` |

Those files are **bare `groups:` fragments**, not whole manifests: the template
supplies `apiVersion` / `kind` / `metadata` and injects the namespace from
`namespace` in the site values. That indirection is deliberate — an earlier copy
hardcoded `namespace: observability`, which does not exist on the consolidated
single node. They are rendered inside the same `observability.stack.enabled`
gate as Prometheus itself, so a site without the stack has neither the evaluator
nor the rules.

They deliberately carry **no `release` label**, which only works because
`ruleSelector` is empty here (see Configuration below). That coupling is
enforced at render time rather than left to a comment: `observability.yaml`
fails the template outright unless
`kube-prometheus-stack.prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues`
is `false`, because with it true Prometheus would select only rules labelled
`release=<release>` and would load none of these — silently, with no error
anywhere, which is the one failure this stack cannot afford.

Firing alerts from both sets are pushed to `ais-kps-alertmanager`, which the
Prometheus object names explicitly. Pipeline-event alerts (upload
failures, invalid sessions, backlog, disk) are LogQL over the JSON log stream and
are evaluated by the Loki ruler instead — see
[`alerting-architecture.md`](../alerting-architecture.md) for the split, and
[`alerting-diy.md`](../alerting-diy.md) for adding rules to either engine.

## What Prometheus has access to

- **Cluster API** via ServiceAccount `ais-kps-prometheus`: `get`/`list`/`watch` on
  nodes, `nodes/metrics`, services, endpoints, endpointslices, pods and ingresses,
  plus `GET` on the `/metrics` and `/metrics/cadvisor` non-resource URLs. It has
  **no Secret or ConfigMap access** — the prometheus-operator reads those and
  writes the finished scrape config into a Secret that Prometheus mounts
- **Outbound HTTP scraping** to ClusterIP services and pod IPs
- **A persistent volume (20Gi, `local-path`)** for the TSDB
- **NO host filesystem, NO hostNetwork** (`hostNetwork: false` in the rendered
  Prometheus object)

## Where it runs

- Cluster: the single node (every pod is scraped directly — no konnectivity
  boundary)
- Namespace: **`xnat-ingest`**, the same namespace as the pipeline. There is no
  separate `observability` namespace on tier-1: one node, one release, one
  namespace
- Workload: `Prometheus` object `ais-kps-prometheus` (one replica), which the
  prometheus-operator turns into StatefulSet `prometheus-ais-kps-prometheus`.
  The name comes from `kube-prometheus-stack.fullnameOverride: ais-kps` in
  `charts/edge/values.yaml`, not from the release name — so it is identical at
  every site
- Image: `quay.io/prometheus/prometheus:v3.13.1-distroless`, from the vendored
  `charts/edge/charts/kube-prometheus-stack-87.19.2.tgz`. Pinned and vendored on
  purpose: a hospital appliance must not need a working path to
  `prometheus-community.github.io` in order to reinstall
- Service: `ais-kps-prometheus.xnat-ingest.svc:9090` (ClusterIP)
- Browser access via the Grafana datasource (provisioned as the default, pointing
  at `http://ais-kps-prometheus.xnat-ingest:9090/`) or `kubectl port-forward`.
  There is no ingress and no NodePort for Prometheus — Grafana is the only piece
  of the stack reachable from off the node

## Configuration

| Where | Purpose |
|---|---|
| `charts/edge/values.yaml`, the `kube-prometheus-stack:` block | **The live settings**: `fullnameOverride`, retention (`prometheus.prometheusSpec.retention: 30d`), the TSDB PVC (`storageSpec`, 20Gi on `local-path`), the disabled exporters, the selector behaviour |
| `sites/<site>/values.yaml`, `observability.stack.enabled` | whether Prometheus exists at all |
| `sites/<site>/values.yaml`, a `kube-prometheus-stack:` block | per-site overrides of anything above — the site file is merged over the chart defaults like any Helm values file |
| Per-component `ServiceMonitor` / `PodMonitor` / `PrometheusRule` objects | tell Prometheus what to scrape and what to evaluate |
| `charts/edge/files/prometheus-rules/{critical,warning,info}.yaml` | this chart's own alert rules, as bare `groups:` fragments. Edit these, not a rendered manifest — `observability.yaml` globs the directory, so a new severity file becomes a new `ais-edge-<name>` object with no template change |

`observability.stack.retentionDays` and `observability.stack.prometheus.*` are the
*intended* site-level surface and are **not yet consumed by any template**.
Changing them alone changes nothing; set retention and PVC size in the
`kube-prometheus-stack:` block, in the site file if it is site-specific.

The subchart's usual label opt-in is switched off:

```yaml
# charts/edge/values.yaml — kube-prometheus-stack.prometheus.prometheusSpec
ruleSelectorNilUsesHelmValues: false
serviceMonitorSelectorNilUsesHelmValues: false
```

which renders `ruleSelector: {}` and `serviceMonitorSelector: {}` with empty
namespace selectors, so Prometheus picks up **every** `PrometheusRule` and
`ServiceMonitor` in the cluster whatever labels they carry. On a node running one
release that is what you want: a rule you add is evaluated without having to
remember a label. Note the asymmetry — `PodMonitor`, `Probe` and `ScrapeConfig`
still select on `release: <release name>` (the release is the site name), so those
three *do* need the label, and a `PodMonitor` without it is silently ignored.

## Operations

```bash
# Pod state
kubectl -n xnat-ingest get pod -l app.kubernetes.io/name=prometheus

# Reach the UI (no auth — ClusterIP only, port-forward)
kubectl -n xnat-ingest port-forward svc/ais-kps-prometheus 9090:9090
xdg-open http://localhost:9090/targets       # see what's being scraped
xdg-open http://localhost:9090/alerts        # see firing/pending alerts
xdg-open http://localhost:9090/rules         # see all loaded rules

# What labels exist on a metric (cardinality check)
curl -s 'http://localhost:9090/api/v1/labels' | jq

# TSDB status
curl -s 'http://localhost:9090/api/v1/status/tsdb' | jq
```

## Benefits

- **Industry standard** — rich ecosystem, every CNCF project ships with
  metrics in Prometheus exposition format
- **Pull model** — scrape failures are visible (target listed as down),
  unlike push systems where missing data could mean either "agent died"
  or "nothing happening"
- **Powerful query language** (PromQL) for derived metrics, alerts,
  and recording rules
- **Operator-managed** — kube-prometheus-stack handles the StatefulSet, its own
  admission-webhook certificates, and ServiceMonitor / PrometheusRule
  reconciliation

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| TSDB PVC fills up | Prometheus stops ingesting; alerts stop firing | 30-day retention is the safety valve; grow `prometheusSpec.storageSpec` past 20Gi if needed. `local-path` puts it under `/opt/local-path-provisioner` on the node — a different path from `/data`, but the same physical disk unless `/data` is its own mount |
| Prometheus pod crashes | Metrics gap; K8s-state alerts cannot fire. Pipeline alerts are unaffected — they run in the Loki ruler | Pod auto-restarts; gap visible in Grafana |
| Scrape target slow / unreachable | That target's metrics go stale | Prometheus marks the target down; the KPS dashboards show it |
| Cardinality explosion | RAM spike, eventual OOM | We deliberately keep the label set tight; cap a noisy target with `sampleLimit` / `labelLimit` on its ServiceMonitor |
| A rule is added but never evaluated | Silent — no alert ever fires, and everything looks healthy | `PrometheusRule` and `ServiceMonitor` need no label here, but `PodMonitor`/`Probe`/`ScrapeConfig` do. Check `/rules` and `/targets` after adding either |
| Operator misconfiguration | Wrong alerts/dashboards / no scrape | Operator logs surface this loudly |

## Replacements / future

- **VictoriaMetrics** — Prometheus-compatible TSDB with better compression
  and ingest throughput. Considered but not deployed
- **Datadog / New Relic** — managed alternatives with their own agents.
  Drop Prometheus and run Vector or a vendor agent as the scraper

## Future enhancements

- Wire `observability.stack.retentionDays` and `observability.stack.prometheus.*`
  through to the subchart so the site file is the single surface, instead of the
  site file and the `kube-prometheus-stack:` block having to agree
- A node-level disk/CPU signal that does not require node-exporter's full target
  set, so disk exhaustion is a metric as well as a log line
- Recording rules to pre-compute the heaviest dashboard queries
- Remote write to a long-term store for retention beyond the local PV window
- Alertmanager → PagerDuty / Opsgenie webhook for after-hours paging
