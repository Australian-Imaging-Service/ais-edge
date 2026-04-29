# Prometheus

## Overview

[Prometheus](https://prometheus.io/) is the de-facto standard time-series
database and monitoring toolkit. It pulls metrics from HTTP `/metrics`
endpoints on a schedule, stores them locally, evaluates alerting and
recording rules, and exposes a query language (PromQL) used by Grafana
and Alertmanager.

## Role in this stack

The metrics layer of the observability stack. Prometheus scrapes:
- **SeaweedFS** master/volume/filer/s3 metrics (ports 9324–9327)
- **nginx-ingress controller** (`:10254/metrics`) — request rates per host
- **cert-manager** (`:9402/metrics`) — certificate expiry, renewal events
- **kube-state-metrics** — pod restarts, deployment status, PVC capacity
- **Loki** (`:3100/metrics`) — its own internal health
- **Vector** (`:9598/metrics`) — `ais_pipeline_events_total{event,cluster,…}`
  derived from log lines
- **kubelet** (cAdvisor on `:10250/metrics/cadvisor`) — container CPU /
  memory / network

It evaluates the `PrometheusRule` files in
`manifests/01-management/observability/alerts/` every 30s and pushes
firing alerts to Alertmanager.

## What Prometheus has access to

- **Cluster API** via its ServiceAccount (read access, mainly to
  resolve Service / Endpoint / Pod targets and discover scrape jobs)
- **Outbound HTTP scraping** to ClusterIP services and pod IPs
- **A persistent volume (20Gi default)** for the TSDB
- Reads `Secret`/`ConfigMap` values referenced by ServiceMonitors
- **NO host filesystem, NO hostNetwork**

## Where it runs

- Cluster: management cluster only (edges are scraped indirectly via
  Vector turning logs into metrics, since Prometheus does not scrape
  across the konnectivity boundary)
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

- **Mimir** — see [`mimir.md`](mimir.md). Same wire protocol, but
  horizontally scalable with object-storage backend. Drop-in once we
  outgrow local PV
- **VictoriaMetrics** — Prometheus-compatible TSDB with better compression
  and ingest throughput. Considered but not deployed
- **Datadog / New Relic** — managed alternatives with their own agents.
  Drop Prometheus and run Vector or DataDog-Agent as the scraper

## Future enhancements

- Recording rules to pre-compute the heaviest dashboard queries
- Remote write to Mimir for long-term retention (>30 days) when we
  outgrow local PV
- Alertmanager → PagerDuty / Opsgenie webhook for after-hours paging
- A scrape job for the k0s API server's `/metrics` (currently disabled
  in `kube-prometheus-stack` values because k0smotron doesn't expose it
  through a stable Service name; revisit when it does)
