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

Every component below is installed by **one chart**, `charts/edge`, and
configured by **one file per site**, `sites/<site>/values.yaml` (scaffold it from
`sites/example-single/` with `scripts/site-secrets.sh new <name> single`).
Credentials are never in that file: they live SOPS-encrypted in
`sites/<site>/secrets.enc.yaml` and are referenced by Secret name. So when a page
below names a setting, it names a **values path** — there is no second,
env-var-shaped configuration to keep in step with it.

## Components

### Data plane

- [`orthanc.md`](components/orthanc.md) — DICOM SCP on the node; runs
  the deid Lua hook before xnat-ingest sees the data
- [`xnat-ingest.md`](components/xnat-ingest.md) — group-orthanc + assign + upload pods

### Observability stack (optional)

Gated on `observability.stack.enabled` in `sites/<site>/values.yaml`, which
defaults to **false**. Do not confuse it with `observability.enabled`, a separate
and older switch that only means "run Vector". With the stack on,
`kube-prometheus-stack` 87.19.2 and `loki` 7.1.0 install as **subcharts of
`charts/edge`** — pinned and vendored as `charts/edge/charts/*.tgz`, so there is
no `helm repo add` and no dependency fetch at install time (a hospital appliance
must not need a working path to the internet to reinstall). Both carry a
`fullnameOverride`, so the workloads are named `ais-kps-prometheus`,
`ais-kps-alertmanager` and `ais-loki`, not `<release>-...`.

- [`loki.md`](components/loki.md) — log store (SingleBinary, filesystem
  storage on a PVC — there is no object store on a single node)
- [`prometheus.md`](components/prometheus.md) — metrics store
- [`grafana.md`](components/grafana.md) — dashboards UI, on a NodePort at
  `http://<nodeIP>:<observability.stack.grafana.nodePort>` (no ingress on tier-1)
- [`alertmanager.md`](components/alertmanager.md) — alert routing
- [`vector.md`](components/vector.md) — log shipper DaemonSet; a hand-written
  `charts/edge/templates/vector.yaml`, not the Vector subchart
- [`kube-state-metrics.md`](components/kube-state-metrics.md) — K8s
  object state metrics, from the kube-prometheus-stack subchart

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
- [`observability-integration.md`](observability-integration.md) — for a
  platform team swapping the bundled Loki/Prometheus/Grafana/Vector stack for
  their own tooling: the log-event schema, metric list, alert inventory, and
  a component swap matrix (verified ground truth, not aspirational).

## How to add a new component doc

1. Copy any existing file in `components/` as a template
2. Fill in the standard sections (don't skip them — agents look for them)
3. Add a one-line entry under the appropriate section above

Keep these files **factual and current**. If something changes in the
codebase, update the doc in the same commit.
