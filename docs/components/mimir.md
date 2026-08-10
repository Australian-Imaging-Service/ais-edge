# Mimir (future option, not currently deployed)

## Overview

[Grafana Mimir](https://grafana.com/oss/mimir/) is a Prometheus-API-
compatible time-series database with horizontal scaling, multi-tenancy,
and S3-backed storage. Same query language (PromQL) and ingest
protocol (Prometheus remote_write) as Prometheus, but designed for
multi-cluster + long-retention deployments.

## Why this doc exists if Mimir isn't deployed

The user explicitly asked us to document Mimir as a future option.
We currently use **vanilla Prometheus** with 30-day local-PV retention
because:
- Single management cluster, single-digit edges → small TSDB
- Local PV is simpler than running a distributed system
- Mimir adds 6+ pod kinds (querier, query-frontend, ingester,
  store-gateway, compactor, distributor); operational overhead

Switch to Mimir when any of these become true:
- Retention requirements exceed ~3 months (TSDB grows beyond a single PV)
- Multi-cluster: each child cluster pushes its metrics to a central
  store (today we'd push edge metrics through Loki only)
- Multi-tenant: different teams need isolated query namespaces
- Need horizontal query scale-out for big LTS analytics

## What Mimir would do in this stack

Replace the kube-prometheus-stack-bundled Prometheus's role as the
**metrics store** while Prometheus continues as a **scraper-only**
process that uses `remote_write` to push samples to Mimir. Grafana's
data source becomes Mimir instead of Prometheus.

```
                                        Today
   Prometheus (scrape + store + query) ──► Grafana

                                        With Mimir
   Prometheus (scrape only, remote_write) ──► Mimir (store + query) ──► Grafana
                                                ↳ S3 (SeaweedFS metrics-bucket)
```

## What Mimir would have access to

- **Object storage** for chunks + index — would use a SeaweedFS
  `metrics-bucket` (we'd add a `mimir-writer` IAM identity to script 03)
- **No direct cluster API** — receives metrics via remote_write from
  Prometheus
- A persistent volume (per component) for transient state

## Where it would run

- Namespace: `observability` (alongside Loki)
- Workloads: 6+ StatefulSets/Deployments depending on the deployment
  mode (`SingleBinary` or `Distributed`)
- Image: `grafana/mimir`
- Helm chart: `grafana/mimir-distributed`

## Configuration sketch

A new `mimir-values.yaml.tpl` would mirror the Loki one:

```yaml
deploymentMode: SingleBinary    # then Distributed when scale demands

mimir:
  structuredConfig:
    blocks_storage:
      backend: s3
      s3:
        endpoint: seaweedfs.seaweedfs.svc.cluster.local:8333
        bucket_name: metrics-bucket
        access_key_id: "${MIMIR_S3_ACCESS_KEY}"
        secret_access_key: "${MIMIR_S3_SECRET_KEY}"
        insecure: true

minio: { enabled: false }

# Then in kube-prometheus-stack-values.yaml.tpl:
prometheus:
  prometheusSpec:
    remoteWrite:
      - url: http://mimir-distributor.observability.svc.cluster.local:8080/api/v1/push
```

The migration from Prometheus-only to Prometheus+Mimir is **drop-in**:
the chart values gain a `remoteWrite` block and Grafana's data source
points at Mimir. No alert / dashboard changes (PromQL is identical).

## Benefits over plain Prometheus

- **Horizontal scaling** — separate components scale independently
- **Long-term storage** in object store; the local PV is just for
  the recent ingester window
- **Multi-tenancy** — built-in tenant header support
- **Better compression** — chunked + indexed storage is more efficient
  than Prometheus' TSDB at scale
- **Continuity at scale** — Cortex / Thanos / Mimir is the
  well-trodden step up from Prometheus alone

## Risks of switching

| Risk | Impact | Mitigation |
|---|---|---|
| More moving parts | More operational load | Start in `SingleBinary` mode (one pod); switch to `Distributed` later |
| Object-store dependency | If SeaweedFS down, Mimir can't ingest | Same pattern as Loki today |
| Migration window | Need to dual-write or accept a gap | Run both for 30 days, then drop local Prometheus retention |
| Larger memory footprint | Bigger nodes / requests | Sizing guide on grafana.com/docs/mimir |

## When NOT to use Mimir

- Single cluster, single team, < 30-day retention → vanilla Prometheus is simpler
- Cost-sensitive deployments where adding 4 GB+ of pods is too much
- Sites with no S3 (SeaweedFS removes this constraint)

## Replacements / future

- **VictoriaMetrics** — alternative scaled TSDB with better single-node
  performance; same Prometheus-compatible ingest. Worth comparing if
  Mimir's complexity feels too high
- **Thanos** — older alternative from the same ecosystem; same
  approach (object-storage backend), different implementation
- **Managed Prometheus** (AMP, GCP Managed Prometheus, Grafana Cloud
  Metrics) — drop the self-host story entirely; trades data residency
  for operational simplicity

## Migration checklist (when the time comes)

1. Add `metrics-bucket` + `mimir-writer` identity to script 03
2. Drop in `mimir-values.yaml.tpl`
3. Helm install `grafana/mimir-distributed` to `observability`
4. Add `remoteWrite` to the kube-prometheus-stack values
5. Update Grafana datasource to point at Mimir
6. (Optional) reduce local Prometheus retention to a few hours; Mimir
   becomes the long-term store
7. Verify dashboards still render (PromQL unchanged)
8. Document the cutover in this file's "Operations" section
