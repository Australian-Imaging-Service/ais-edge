# Prometheus

## Overview

[Prometheus](https://prometheus.io/) is the de-facto standard time-series
database and monitoring toolkit. It pulls metrics from HTTP `/metrics`
endpoints on a schedule, stores them locally, evaluates alerting and
recording rules, and exposes PromQL for queries and rule evaluation. Grafana queries it;
Alertmanager receives evaluated alerts and routes notifications rather than
executing PromQL itself.

## Role in this stack

The metrics layer of the observability stack. Prometheus scrapes:
- **SeaweedFS** (`:9324/metrics`) — one aggregated endpoint, not four.
  `weed server` publishes master + volume + filer + s3 series together on the
  single `-metricsPort` (`charts/mgmt/templates/seaweedfs.yaml`); the
  per-subsystem metrics ports the upstream docs describe belong to the
  standalone `weed master` / `weed volume` commands, not to the combined
  server we run. Fronted by the `<release>-seaweedfs-metrics` Service and
  scraped every 30s by the ServiceMonitor in `observability.yaml`
- **nginx-ingress controller** exposes metrics only if configured in its
  separate installation. A matching ServiceMonitor is not created by the
  management chart. Current ingress scrape coverage is not verified (2026-11-10).
- **cert-manager** (`:9402/metrics`) — certificate expiry, renewal events
- **kube-state-metrics** — pod restarts, deployment status, PVC capacity
- **Loki** (`:3100/metrics`): its self-monitor is enabled in values, but the
  subchart emits it only when the ServiceMonitor API is available at render
  time. A plain `helm template` without that capability omits it. The literal
  monitor label `release: mgmt` must match the Prometheus selector.
- **NOT Vector.** There is no `:9598` scrape job and no
  `ais_pipeline_events_total` series anywhere in the stack. The Vector
  `log_to_metric` transform, the `prometheus_exporter` sink and the Vector
  `Service` were all removed on purpose — see "What we removed" in
  [`../alerting-architecture.md`](../alerting-architecture.md). mgmt Vector
  now ships `service: {enabled: false}` / `serviceMonitor: {enabled: false}`
  (`charts/mgmt/values.yaml`) and the edge DaemonSet
  (`charts/edge/templates/vector.yaml`) renders no Service at all, so there
  is nothing to point a ServiceMonitor at. Pipeline events stay logs and are
  alerted on as logs by the Loki ruler
  (`charts/mgmt/files/loki-ruler-rules.yaml`), which removes one whole metric
  pipeline instead of maintaining two views of the same events
- **kubelet** (cAdvisor on `:10250/metrics/cadvisor`) — container CPU /
  memory / network

It evaluates the `PrometheusRule` files in
`charts/mgmt/files/prometheus-rules/` every 30s and pushes
firing alerts to Alertmanager.

## What Prometheus has access to

- **Cluster API** via its ServiceAccount (read access, mainly to
  resolve Service / Endpoint / Pod targets and discover scrape jobs)
- **Outbound HTTP scraping** to ClusterIP services and pod IPs
- **A persistent volume (20Gi default)** for the TSDB
- The operator reads referenced Secrets/ConfigMaps and prepares mounted
  configuration. The Prometheus ServiceAccount itself has no Secret or
  ConfigMap API read permission in the rendered ClusterRole.
- **NO host filesystem, NO hostNetwork**

## Where it runs

- Cluster: management cluster only. Prometheus does not scrape across the
  konnectivity boundary, and deliberately does not need to — edge signals
  travel as logs (Vector → Loki) and are alerted on there by the Loki ruler,
  rather than being turned back into metrics first. Any rule naming a
  child-cluster object from mgmt Prometheus cannot see that object through
  these local scrapes. Historical unreachable-object rules were removed; the
  surviving rule named `EdgeWorkerDisconnected` actually selects management
  cluster node readiness. It is not proof that an edge worker is disconnected
  ([`../alerting-architecture.md`](../alerting-architecture.md))
- Namespace: `ais-mgmt` — the release namespace, set by `install.sh`
  (`MGMT_NS`). kube-prometheus-stack is a *subchart* of `charts/mgmt` with no
  `namespaceOverride`, so it lands wherever the release does. There is no
  `observability` namespace
- Workload: StatefulSet `prometheus-mgmt-kube-prometheus-stack-prometheus`
  (pod `…-0`, single replica, created by the prometheus-operator — not by
  Helm — from the `Prometheus` CR). Every name here is release-derived: the
  CR is `<release>-kube-prometheus-stack-prometheus` and the operator prefixes
  the StatefulSet with `prometheus-`, so renaming the Helm release renames all
  of them. Do not hardcode these in scripts; look them up by label
- Service: `mgmt-kube-prometheus-stack-prometheus.ais-mgmt.svc:9090`
  (ClusterIP, port name `http-web`)
- Browser access via Grafana datasource OR `kubectl port-forward`

## Configuration

| File | Purpose |
|---|---|
| `charts/mgmt/values.yaml` (`kube-prometheus-stack:`) | retention, scrape interval, storage size |
| `charts/mgmt/files/prometheus-rules/critical.yaml` | critical alerts |
| `charts/mgmt/files/prometheus-rules/warning.yaml` | warning alerts |
| `charts/mgmt/files/prometheus-rules/info.yaml` | info alerts |
| `charts/mgmt/files/prometheus-rules/uploader.yaml` | Six recording rules and two uploader restart/memory alerts; scopes are substituted by the template. |
| `charts/mgmt/files/prometheus-rules/cert-sync.yaml` | per-edge cert-sync staleness (`CertSyncStale`, `CertSyncNeverSucceeded`) |
| `charts/mgmt/files/prometheus-rules/reclaimer.yaml` | per-edge reclaimer health (`ReclaimerNotSucceeding`). Uses namespace, release-prefix and threshold sentinels filled by `observability.yaml`; `uploader.yaml` also uses sentinels; not rendered under `s3Staged.reclaim: never` |
| Per-component: ServiceMonitor / PodMonitor objects (released alongside Service definitions) | tell Prometheus what to scrape |

The rule files are **not** enumerated in any template. `observability.yaml`
renders one `PrometheusRule` per file matched by
`.Files.Glob "files/prometheus-rules/*.yaml"`, so dropping a new file into
that directory ships it and no list has to be kept in sync. Each file has a
promtool unit test beside it in `files/prometheus-rules/tests/`, which is
what checks the synthetic series and timing encoded by the fixtures. Those
tests do not prove that a live scrape emits every required series. Confirm
/rules and /targets plus representative queries after deployment.

The selector labels work by **opt-in**: Prometheus only discovers
ServiceMonitors / PodMonitors / PrometheusRules carrying a `release` label
that matches what the subchart selects. That label is **templated from the
Helm release name**, not the literal `kube-prometheus-stack` — under release
`mgmt` it is `release: mgmt`. Every rule and monitor this chart creates takes
it from the `mgmt.prometheusReleaseLabel` helper
(`charts/mgmt/templates/_helpers.tpl`), and
`observability.prometheusReleaseLabel` in `charts/mgmt/values.yaml` is the
escape hatch for the case where kube-prometheus-stack is a separate release.

The hardcoded `release: kube-prometheus-stack` was deleted on purpose and
must not come back. It was only ever correct under the old imperative
installer's release name; as a subchart it means Prometheus silently loads
none of our rules — no error, no failed render, no pod restart, just an
alerting stack that never fires again. Leaving `ruleSelector` /
`serviceMonitorSelector` empty keeps `*SelectorNilUsesHelmValues` at its
default `true`, which auto-templates `release: <parent release>` and tracks
the helper with nothing to remember. `observability.yaml` additionally
cross-checks the selector against the applied label and `fail`s the render if
the two ever disagree, so this cannot drift back silently.

## Operations

```bash
# Pod state. The label selector is stable across release renames; the
# StatefulSet/pod name is not, so select rather than spell it out.
kubectl -n ais-mgmt get pod -l app.kubernetes.io/name=prometheus

# Reach the UI (default no auth — ClusterIP only, port-forward)
kubectl -n ais-mgmt port-forward svc/mgmt-kube-prometheus-stack-prometheus 9090:9090
xdg-open http://localhost:9090/targets       # see what's being scraped
xdg-open http://localhost:9090/alerts        # see firing/pending alerts
xdg-open http://localhost:9090/rules         # see all loaded rules

# What labels exist on a metric (cardinality check)
curl -s 'http://localhost:9090/api/v1/labels' | jq

# TSDB status
curl -s 'http://localhost:9090/api/v1/status/tsdb' | jq
```

## Benefits

- **Widely adopted**: a broad ecosystem exposes Prometheus metrics.
  Verify each target and its labels; project membership does not guarantee an endpoint.
- **Pull model** — scrape failures are visible (target listed as down),
  unlike push systems where missing data could mean either "agent died"
  or "nothing happening"
- **Powerful query language** (PromQL) for derived metrics, alerts,
  and recording rules
- **Operator-managed** — kube-prometheus-stack handles upgrades,
  certificate rotation, ServiceMonitor reconciliation

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| Local PV fills up | Prometheus stops ingesting; alerts stop firing | 15-day retention on a 20Gi PV is a time bound, not a capacity guarantee. Monitor actual TSDB growth; local-path does not by itself provide in-place PVC expansion. Plan storage migration or capacity changes for the deployed provisioner. Set retention **only** at `kube-prometheus-stack.prometheus.prometheusSpec.retention` ; the chart `fail`s if you try it under `dataPolicy.telemetry`, because Helm cannot template a subchart's values from the parent and the key would change nothing. (Loki's 30d `retention_period` is a separate setting.) |
| Prometheus pod crashes | Metrics gap; alerts cannot fire | Pod auto-restarts; gap visible in Grafana |
| Scrape target slow / unreachable | That target's metrics go stale | Prometheus marks the target down; KPS dashboard shows it |
| Cardinality explosion | RAM spike, eventual OOM | Use supported per-target sampleLimit/labelLimit settings and inspect cardinality. The formerly suggested cardinality-mitigation feature flag is not verified for the pinned image (2026-11-10) and is not an operational instruction. |
| Operator misconfiguration | Wrong alerts/dashboards / no scrape | Inspect operator logs, rejected resources, /targets and /rules. A valid selector that matches nothing may leave no obvious error. |

## Replacements / future

- **Mimir** — see [`mimir.md`](mimir.md). Same wire protocol, but
  horizontally scalable with object-storage backend. It is not a drop-in
  replacement for the scraper and local TSDB; plan remote write, credentials,
  rules, querying, and any history migration separately
- **VictoriaMetrics**: a possible Prometheus-compatible TSDB replacement,
  considered but not deployed. Relative compression and throughput are not
  verified (2026-11-10); benchmark the site workload and required query behavior.
- **Datadog / New Relic** — managed alternatives with their own agents.
  Drop Prometheus and run Vector or DataDog-Agent as the scraper

## Future enhancements

- Recording rules to pre-compute the heaviest dashboard queries
- Remote write to Mimir for long-term retention (anything beyond the 15-day
  local window) when we outgrow local PV
- Alertmanager → PagerDuty / Opsgenie webhook for after-hours paging
- Scrape jobs for the control-plane components that are still switched off.
  The management API server is **already scraped** — `kubeApiServer`,
  `kubelet` and `coreDns` are all `enabled: true` in the
  `kube-prometheus-stack` values. What remains off is `kubeControllerManager`,
  `kubeScheduler` and `kubeProxy`, because k0s either embeds them or does not
  expose them the way upstream assumes, plus `kubeEtcd`, because k0smotron's
  etcd is per child cluster rather than one management-cluster Service to
  point at. Each is worth revisiting individually if k0s/k0smotron start
  publishing a stable endpoint — flipping them on today just adds permanently
  down targets
