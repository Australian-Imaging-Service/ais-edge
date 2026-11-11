# Mimir (future option, not currently deployed)

## Overview

[Grafana Mimir](https://grafana.com/oss/mimir/) is a Prometheus-API-
compatible time-series database with horizontal scaling, multi-tenancy,
and S3-backed storage. Same query language (PromQL) and ingest
protocol (Prometheus remote_write) as Prometheus, but designed for
multi-cluster + long-retention deployments.

## Why this doc exists if Mimir isn't deployed

This is a future design reference, reviewed on 2026-11-10. Mimir is not
a dependency or workload in this repository. The original sketch date is not
recorded. Keep the design questions below, but do not apply its illustrative
YAML as a tested installation recipe. A Mimir chart version has not been
selected, and its rendered behavior is not verified (2026-11-10).
We currently use **vanilla Prometheus** with 15-day local-PV retention
because:
- The design assumed one management cluster and a small edge fleet. Actual
  TSDB size depends on active series, sample interval and retention; current
  fleet size and capacity are not verified (2026-11-10).
- Local PV is simpler than running a distributed system
- Mimir adds 6+ pod kinds (querier, query-frontend, ingester,
  store-gateway, compactor, distributor); operational overhead

The 15 days is `kube-prometheus-stack.prometheus.prometheusSpec.retention`
(`charts/mgmt/values.yaml` (`kube-prometheus-stack.prometheus.prometheusSpec.retention`), "THE one place Prometheus retention is set")
on a 20Gi `local-path` PVC (`charts/mgmt/values.yaml`, `observability.prometheus.persistenceSize`), `charts/mgmt/values.yaml` (`kube-prometheus-stack.prometheus.prometheusSpec.storageSpec`). Don't confuse it with the 30d at
`charts/mgmt/values.yaml` (`loki.loki.limits_config.retention_period`), which is **Loki's** `retention_period` for logs
— the two stores are sized and retained separately on purpose, because log
volume and metric volume grow at different rates.

Evaluate a remote metrics store when these requirements arise. These are
design triggers, not measured limits that require Mimir at a fixed size:
- Retention requirements exceed what the measured local capacity can hold.
  Three months is six times the configured 15-day interval, but this does not
  itself establish a disk-size or performance limit for Prometheus.
- Multi-cluster: each child cluster pushes its metrics to a central
  store (today edge reporter observations arrive as logs in Loki, not as
  remote-written Prometheus metrics)
- Multi-tenant: different teams need isolated query namespaces
- Need horizontal query scale-out for big LTS analytics

## What Mimir would do in this stack

A future integration could move long-term metrics storage to Mimir while
Prometheus continues scraping and sending samples with `remote_write`.
Adding `remoteWrite` alone does not make Prometheus scraper-only: its local
TSDB and rule evaluation continue unless separately changed. Grafana's
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
  alongside `ingest` and `logs` (`charts/mgmt/values.yaml`, `seaweedfs.buckets`), with a
  `mimir-writer` identity scoped to it only. There is no `scripts/03-*` to
  edit any more: S3 identities are assembled **inside the pod** by the
  `build-s3-identities` init container from projected Secrets
  (`charts/mgmt/templates/seaweedfs.yaml`, `build-s3-identities`), so adding one means an
  `emit 'mimir-writer' "$SRC/mimir" '["Read:metrics-bucket",…]'` line there
  plus a `mimirS3SecretRef` alongside `observability.loki.s3SecretRef`
  (`charts/mgmt/values.yaml`, `observability.loki.s3SecretRef`). The init container refuses to start on a
  blank or duplicated access key, so a half-added identity fails loudly
  rather than 403-ing days later.
- **No direct cluster API** — receives metrics via remote_write from
  Prometheus
- A persistent volume (per component) for transient state

## Where it would run

- Namespace: `ais-mgmt` — the management release's namespace
  (`install.sh`, `MGMT_NS`), alongside Loki. There is no `observability` namespace;
  that was the pre-chart shell installer's, and the charts put every mgmt
  workload in `.Release.Namespace`
- Workloads: 6+ StatefulSets/Deployments depending on the deployment
  mode (monolithic or microservices). Upstream selects Mimir targets with
  `-target`; the `mimir-distributed` chart targets microservices. Loki
  `deploymentMode` values are not a verified Mimir chart interface
- Image: `grafana/mimir`
- Helm chart: `grafana/mimir-distributed`, vendored into
  `charts/mgmt/charts/` and pinned in `Chart.yaml` the way Loki,
  kube-prometheus-stack, ingress-nginx, cert-manager and Vector already are

## Configuration sketch

A new `mimir:` block in `charts/mgmt/values.yaml` would mirror the `loki:`
one at `charts/mgmt/values.yaml` (`loki`). This subchart is configured inline in that file, not from a
template file. There are no `*-values.yaml.tpl` files left in the repo.

One trap inherited from that block, recorded at
`charts/mgmt/values.yaml` (`SUBCHART VALUES`): **Helm does not template `values.yaml`**.
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
  # Historical sketch only: deploymentMode: SingleBinary was copied from Loki.
  # Do not enable it as a Mimir chart setting. Select the actual chart version
  # and its supported topology before constructing a renderable values file.

  mimir:
    structuredConfig:
      blocks_storage:
        backend: s3
        s3:
          # Same shape as the Loki sink: the in-cluster SeaweedFS Service is
          # <release>-seaweedfs in the release namespace, plain http because
          # this uses the cluster network; it can cross nodes on a larger cluster.
          # Assess network trust or use TLS when the deployment requires it.
          endpoint: mgmt-seaweedfs.ais-mgmt.svc.cluster.local:8333
          bucket_name: metrics-bucket
          # Expanded by Mimir at startup, never by Helm, so the key never
          # lands in a rendered manifest or in git — as with LOKI_S3_*.
          access_key_id: "${MIMIR_S3_ACCESS_KEY}"
          secret_access_key: "${MIMIR_S3_SECRET_KEY}"
          insecure: true

  minio: { enabled: false }

# Then under the existing `kube-prometheus-stack:` key in the same file
# (charts/mgmt/values.yaml (`kube-prometheus-stack`)):
kube-prometheus-stack:
  prometheus:
    prometheusSpec:
      remoteWrite:
        - url: http://mgmt-mimir-distributor.ais-mgmt.svc.cluster.local:8080/api/v1/push
```

This is not a verified drop-in migration. PromQL compatibility helps reuse
queries, but datasource UIDs, tenant headers, rule evaluation, recording rules,
external labels, historical data and remote-write delivery all need a cutover
plan. Test the actual dashboards and alert inputs against the chosen version
before shortening local retention. A new remote-write endpoint does not
automatically backfill the old TSDB.

## Benefits over plain Prometheus

- **Horizontal scaling** — separate components scale independently
- **Long-term storage** in object store; the local PV is just for
  the recent ingester window
- **Multi-tenancy** — built-in tenant header support
- **Storage efficiency must be measured.** Both systems store compressed
  time series. Relative compression, query speed and resource cost for this
  fleet are not verified (2026-11-10). Use representative cardinality and
  retention in any comparison.
- **Continuity at scale** — Cortex / Thanos / Mimir is the
  well-trodden step up from Prometheus alone

## Risks of switching

| Risk | Impact | Mitigation |
|---|---|---|
| More moving parts | More operational load | Select a supported Mimir topology and chart version. Upstream documents monolithic `-target=all` and microservices targets; the Loki `SingleBinary` value in the old sketch is not a tested Mimir configuration |
| Object-store dependency | Reads and block uploads can fail or accumulate when SeaweedFS is unavailable | Exact ingestion buffering and outage tolerance depend on the selected Mimir architecture and version. Test these before migration; an object-store outage does not imply every incoming sample is immediately refused |
| Migration window | Need to dual-write or accept a gap | Run both for at least one full local-retention window (15 days today) before shortening `prometheusSpec.retention` |
| Larger memory footprint | Bigger nodes / requests | Sizing guide on grafana.com/docs/mimir |

## When NOT to use Mimir

- Single cluster, single team, retention around today's 15 days (or anything
  a single 20Gi PV holds) → vanilla Prometheus is simpler
- Cost-sensitive deployments without a measured budget for the additional
  services. The older 4 GB estimate is not verified (2026-11-10) and is not a
  sizing recommendation for any selected Mimir release.
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
8. Add a dated Operations section with the selected chart, rendered settings,
   validation results and rollback procedure. This future-design page has no
   implemented Operations section yet.
