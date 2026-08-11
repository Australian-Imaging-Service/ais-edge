# Mimir (future option, not currently deployed)

## Overview

[Grafana Mimir](https://grafana.com/oss/mimir/) is a Prometheus-API-
compatible time-series database with horizontal scaling, multi-tenancy,
and S3-backed storage. Same query language (PromQL) and ingest
protocol (Prometheus remote_write) as Prometheus, but designed for
multi-cluster + long-retention deployments.

## Why this doc exists if Mimir isn't deployed

The user explicitly asked us to document Mimir as a future option.
We currently use **vanilla Prometheus** with 15-day local-PV retention
because:
- Single management cluster, single-digit edges → small TSDB
- Local PV is simpler than running a distributed system
- Mimir adds 6+ pod kinds (querier, query-frontend, ingester,
  store-gateway, compactor, distributor); operational overhead

The 15 days is `kube-prometheus-stack.prometheus.prometheusSpec.retention`
(`charts/mgmt/values.yaml:671`, "THE one place Prometheus retention is set")
on a 20Gi `local-path` PVC (`:581`, `:692`). Don't confuse it with the 30d at
`charts/mgmt/values.yaml:849`, which is **Loki's** `retention_period` for logs
— the two stores are sized and retained separately on purpose, because log
volume and metric volume grow at different rates.

Switch to Mimir when any of these become true:
- Retention requirements exceed ~3 months (TSDB grows beyond a single PV;
  that is a 6× stretch on today's 15 days, not a small bump)
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
  `metrics-bucket`, added as a third entry under `seaweedfs.buckets`
  alongside `ingest` and `logs` (`charts/mgmt/values.yaml:285-289`), with a
  `mimir-writer` identity scoped to it only. There is no `scripts/03-*` to
  edit any more: S3 identities are assembled **inside the pod** by the
  `build-s3-identities` init container from projected Secrets
  (`charts/mgmt/templates/seaweedfs.yaml:150-257`), so adding one means an
  `emit 'mimir-writer' "$SRC/mimir" '["Read:metrics-bucket",…]'` line there
  plus a `mimirS3SecretRef` alongside `observability.loki.s3SecretRef`
  (`charts/mgmt/values.yaml:593`). The init container refuses to start on a
  blank or duplicated access key, so a half-added identity fails loudly
  rather than 403-ing days later.
- **No direct cluster API** — receives metrics via remote_write from
  Prometheus
- A persistent volume (per component) for transient state

## Where it would run

- Namespace: `ais-mgmt` — the management release's namespace
  (`install.sh:121`), alongside Loki. There is no `observability` namespace;
  that was the pre-chart shell installer's, and the charts put every mgmt
  workload in `.Release.Namespace`
- Workloads: 6+ StatefulSets/Deployments depending on the deployment
  mode (`SingleBinary` or `Distributed`)
- Image: `grafana/mimir`
- Helm chart: `grafana/mimir-distributed`, vendored into
  `charts/mgmt/charts/` and pinned in `Chart.yaml` the way Loki,
  kube-prometheus-stack, ingress-nginx, cert-manager and Vector already are

## Configuration sketch

A new `mimir:` block in `charts/mgmt/values.yaml` would mirror the `loki:`
one at `:813-928` — the subchart is configured inline there, not from a
template file. There are no `*-values.yaml.tpl` files left in the repo.

One trap inherited from that block, recorded at
`charts/mgmt/values.yaml:650-661`: **Helm does not template `values.yaml`**.
A subchart value cannot say `{{ .Release.Name }}-something` unless the
subchart itself runs `tpl` over that field. Loki's S3 `endpoint` works only
because the loki chart does; every other cross-reference below is a literal
kept in step by hand, which is why `mgmt-loki` is pinned with
`fullnameOverride` rather than derived. Mimir would need the same treatment.

```yaml
# charts/mgmt/values.yaml, a sibling of the existing `loki:` block
mimir:
  # Pin the name the way loki.fullnameOverride is pinned, so the remote_write
  # URL below (a literal, see above) does not have to track .Release.Name.
  fullnameOverride: mgmt-mimir
  deploymentMode: SingleBinary  # then Distributed when scale demands

  mimir:
    structuredConfig:
      blocks_storage:
        backend: s3
        s3:
          # Same shape as the Loki sink: the in-cluster SeaweedFS Service is
          # <release>-seaweedfs in the release namespace, plain http because
          # the hop never leaves the node.
          endpoint: mgmt-seaweedfs.ais-mgmt.svc.cluster.local:8333
          bucket_name: metrics-bucket
          # Expanded by Mimir at startup, never by Helm, so the key never
          # lands in a rendered manifest or in git — as with LOKI_S3_*.
          access_key_id: "${MIMIR_S3_ACCESS_KEY}"
          secret_access_key: "${MIMIR_S3_SECRET_KEY}"
          insecure: true

  minio: { enabled: false }

# Then under the existing `kube-prometheus-stack:` key in the same file
# (charts/mgmt/values.yaml:663-810):
kube-prometheus-stack:
  prometheus:
    prometheusSpec:
      remoteWrite:
        - url: http://mgmt-mimir-distributor.ais-mgmt.svc.cluster.local:8080/api/v1/push
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
| Migration window | Need to dual-write or accept a gap | Run both for at least one full local-retention window (15 days today) before shortening `prometheusSpec.retention` |
| Larger memory footprint | Bigger nodes / requests | Sizing guide on grafana.com/docs/mimir |

## When NOT to use Mimir

- Single cluster, single team, retention around today's 15 days (or anything
  a single 20Gi PV holds) → vanilla Prometheus is simpler
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

1. Add `metrics-bucket` to `seaweedfs.buckets` and a `mimir-writer` identity
   to the `build-s3-identities` init container in
   `charts/mgmt/templates/seaweedfs.yaml` (there is no `scripts/03-*`), plus
   its credentials Secret in `sites/<site>/secrets.enc.yaml`
2. Vendor `grafana/mimir-distributed` into `charts/mgmt/charts/` and pin it in
   `charts/mgmt/Chart.yaml`, then add the `mimir:` block to
   `charts/mgmt/values.yaml` (there are no `*-values.yaml.tpl` files)
3. `./install.sh -y <site>` — step 4/7 rolls the management release, so Mimir
   arrives in `ais-mgmt` with everything else. No separate `helm install`
4. Add `remoteWrite` under the `kube-prometheus-stack:` key in the same
   values file
5. Update Grafana datasource to point at Mimir
6. (Optional) reduce local Prometheus retention to a few hours; Mimir
   becomes the long-term store
7. Verify dashboards still render (PromQL unchanged)
8. Document the cutover in this file's "Operations" section
