# Prometheus

## Overview

[Prometheus](https://prometheus.io/) is the de-facto standard time-series
database and monitoring toolkit. It pulls metrics from HTTP `/metrics`
endpoints on a schedule, stores them locally, evaluates alerting and
recording rules, and exposes a query language (PromQL) used by Grafana
and Alertmanager.

## Role in this stack

The metrics layer of the observability stack. On the single node Prometheus can
scrape every pod directly (there is no konnectivity boundary). It scrapes:
- **kube-state-metrics** — pod restarts, deployment status, PVC capacity
- **node-exporter** — node CPU / memory / disk / network
- **kubelet** (cAdvisor on `:10250/metrics/cadvisor`) — container CPU /
  memory / network
- **Loki** (`:3100/metrics`) — its own internal health

It evaluates the `PrometheusRule` files in
`manifests/01-management/observability/alerts/` and pushes firing alerts to
Alertmanager. Pipeline-event alerts (upload failures, invalid sessions, backlog)
are evaluated by the Loki ruler over the JSON log stream instead — see
[`alerting-architecture.md`](../alerting-architecture.md).

## What Prometheus has access to

- **Cluster API** via its ServiceAccount (read access, mainly to
  resolve Service / Endpoint / Pod targets and discover scrape jobs)
- **Outbound HTTP scraping** to ClusterIP services and pod IPs
- **A persistent volume (20Gi default)** for the TSDB
- Reads `Secret`/`ConfigMap` values referenced by ServiceMonitors
- **NO host filesystem, NO hostNetwork**

## Where it runs

- Cluster: the single-node cluster (every pod is scraped directly — no
  konnectivity boundary)
- Namespace: `observability`
- Workload: StatefulSet `prometheus-kube-prometheus-stack-prometheus-0`
  (single replica, managed by the prometheus-operator)
- Service: `kube-prometheus-stack-prometheus.observability.svc:9090`
- Browser access via Grafana datasource OR `kubectl port-forward`

## Configuration

| File | Purpose |
|---|---|
| `manifests/01-management/observability/kube-prometheus-stack-values.yaml.tpl` | retention, scrape interval, storage size, selector labels |
| `manifests/01-management/observability/alerts/critical.yaml` | 4 critical alerts |
| `manifests/01-management/observability/alerts/warning.yaml` | 9 warning alerts |
| `manifests/01-management/observability/alerts/info.yaml` | 3 info alerts |
| Per-component: ServiceMonitor / PodMonitor objects (released alongside Service definitions) | tell Prometheus what to scrape |

The selector labels work by **opt-in**: Prometheus only scrapes
ServiceMonitors / PodMonitors / PrometheusRules with label
`release=kube-prometheus-stack`. We ensure all our manifests carry
that label so they're auto-discovered.

## Operations

```bash
# Pod state
kubectl -n observability get pod -l app.kubernetes.io/name=prometheus

# Reach the UI (default no auth — ClusterIP only, port-forward)
kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090
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
- **Operator-managed** — kube-prometheus-stack handles upgrades,
  certificate rotation, ServiceMonitor reconciliation

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| Local PV fills up | Prometheus stops ingesting; alerts stop firing | 30-day retention is the safety valve; resize PVC if needed |
| Prometheus pod crashes | Metrics gap; alerts cannot fire | Pod auto-restarts; gap visible in Grafana |
| Scrape target slow / unreachable | That target's metrics go stale | Prometheus marks the target down; KPS dashboard shows it |
| Cardinality explosion | RAM spike, eventual OOM | We deliberately keep label set tight; quotas via `--enable-feature=cardinality-mitigation` if needed |
| Operator misconfiguration | Wrong alerts/dashboards / no scrape | Operator logs surface this loudly |

## Replacements / future

- **VictoriaMetrics** — Prometheus-compatible TSDB with better compression
  and ingest throughput. Considered but not deployed
- **Datadog / New Relic** — managed alternatives with their own agents.
  Drop Prometheus and run Vector or a vendor agent as the scraper

## Future enhancements

- Recording rules to pre-compute the heaviest dashboard queries
- Remote write to a long-term store for retention beyond the local PV window
- Alertmanager → PagerDuty / Opsgenie webhook for after-hours paging
