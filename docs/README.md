# AIS Edge (Tier-1) — Component Documentation

Per-component reference. The top-level [`README.md`](../README.md) covers the
**system as a whole** (single-node architecture, install, network, security
model). The files in this folder are deeper dives into individual components:
what each one does, what it has access to, why we chose it, what its failure modes
are, and how to operate or replace it.

The pages are written so they can be read by engineers AND consumed by
automated agents tracking the system over time. Each follows a consistent
structure (Overview → Role → Access → How it runs → Configuration →
Operations → Risks → Replacements / Future).

This is the **tier-1, single-node** deployment: one k0s cluster runs the whole
pipeline (Orthanc + xnat-ingest + optional observability). There is no k0smotron,
no child cluster, no SeaweedFS/S3, no nginx-ingress, and no cert-manager.

## Components

### Data plane

- [`orthanc.md`](components/orthanc.md) — DICOM SCP on the node; runs
  the deid Lua hook before xnat-ingest sees the data
- [`xnat-ingest.md`](components/xnat-ingest.md) — DICOM sort + upload pods

### Observability stack (optional, install via `scripts/02d-...`)

- [`loki.md`](components/loki.md) — log store (local filesystem storage)
- [`prometheus.md`](components/prometheus.md) — metrics store
- [`grafana.md`](components/grafana.md) — dashboards UI (NodePort)
- [`alertmanager.md`](components/alertmanager.md) — alert routing
- [`vector.md`](components/vector.md) — log shipper DaemonSet
- [`kube-state-metrics.md`](components/kube-state-metrics.md) — K8s
  object state metrics

### System-level references

- [`alerting-architecture.md`](alerting-architecture.md) — why pipeline-event
  alerts live in the Loki ruler (LogQL over JSON events) while K8s-level
  alerts stay in Prometheus.
- [`alerting-diy.md`](alerting-diy.md) — recipe for adding your own
  alert rules: how to discover metrics + log streams, where to put the
  rule file, copy-paste patterns for common alert shapes, how to route
  to a specific receiver, how to verify + silence during testing.
- [`dashboards.md`](dashboards.md) — every Grafana panel, its query,
  what it measures, and the JSON pipeline-event schema that backs the
  panels. Read this before changing any dashboard panel.
- [`cai-lfs3-deployment-plan.md`](cai-lfs3-deployment-plan.md) — planning notes
  (out of scope for the tier-1 pipeline).
- [`zip-metadata-extraction-xnat-plan.md`](zip-metadata-extraction-xnat-plan.md) —
  planning notes (out of scope for the tier-1 pipeline).

## How to add a new component doc

1. Copy any existing file in `components/` as a template
2. Fill in the standard sections (don't skip them — agents look for them)
3. Add a one-line entry under the appropriate section above

Keep these files **factual and current**. If something changes in the
codebase, update the doc in the same commit.
