# Loki

## Overview

[Loki](https://grafana.com/oss/loki/) is a log aggregation system designed
to be horizontally scalable, cheap to operate, and tightly integrated with
Grafana. It indexes a small set of labels (not the log content) and stores
the raw log lines as gzipped chunks in object storage. Queries use a
PromQL-like language called LogQL.

## Role in this stack

Loki is the **log store** for the single node. The Vector DaemonSet tails every
pod's stdout and pushes the collected log lines to the in-cluster Loki Service.
Operators query the data through Grafana's "Explore" view to follow a session's
journey, debug the pipeline, or audit who uploaded what when.

## What Loki has access to

- **In-cluster network** — accepts pushes from Vector, queries from Grafana
- **Local filesystem storage on a PVC** — chunks and index live on a
  PersistentVolume (backed by the node's local-path StorageClass). This is the
  single-binary standard; there is **no S3 / object store** in tier-1.
- **NO hostNetwork, no hostPath** beyond the PVC — runs as a regular pod

## Where it runs

- Cluster: the single-node cluster
- Namespace: `observability`
- Workload: StatefulSet `loki` (single replica, single-binary mode)
- Service: `loki.observability.svc.cluster.local:3100` (ClusterIP)
- No external ingress — Vector pushes to the ClusterIP Service directly (no
  443/SNI/TLS hop).

## Configuration

| File | Purpose |
|---|---|
| `manifests/01-management/observability/loki-values.yaml.tpl` | helm chart values; single-binary mode, filesystem storage, retention |
| `config/management.env` | `OBSERVABILITY_RETENTION_DAYS` |

Key tuning knobs in the values file:
- `deploymentMode: SingleBinary` — one pod runs all roles, backed by a local PVC.
- `storage.type: filesystem` — chunks + index on the PVC; no object store.
- `limits_config.retention_period` — set from `OBSERVABILITY_RETENTION_DAYS`. The
  compactor enforces it by deleting old chunks from the PVC. Retention is
  ultimately disk-bound on the node.
- `commonConfig.replication_factor: 1` — single replica is correct for a single
  node.

## Operations

```bash
# Pod state
kubectl -n observability get pod -l app.kubernetes.io/name=loki

# Logs
kubectl -n observability logs -l app.kubernetes.io/name=loki

# Query from CLI (logcli) via port-forward — install with `go install ...logcli`
kubectl -n observability port-forward svc/loki 3100:3100 &
logcli --addr=http://localhost:3100 query '{namespace="xnat-ingest"}'

# Disk usage of the Loki PVC (retention is disk-bound)
kubectl -n observability exec statefulset/loki -c loki -- df -h /var/loki
```

## Benefits (why we chose Loki over alternatives)

- **Cheap, simple storage** — chunks live on the node's local PVC; no object
  store to run or back up on a single-node appliance
- **Label-based indexing** — the index is tiny (~1% of log volume),
  meaning low memory and disk overhead
- **Tight Grafana integration** — same UI as our metrics dashboards;
  operators don't context-switch
- **Single binary deploys** — one container keeps the operational footprint small
- **Same vendor as Grafana / Prometheus** — coherent stack with shared semantics
  (LogQL ↔ PromQL)

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| Loki PVC disk full | New writes fail; old logs may be unreadable until the compactor frees space | Retention is set in days (`OBSERVABILITY_RETENTION_DAYS`); size the node's disk accordingly |
| Loki pod crash | Logs queued in Vector's buffer are held until Loki recovers | Vector handles backpressure; replay continues automatically |
| PVC corruption | Loki may need reinitialising; historical logs on the PVC may be lost | Back up the PVC if long-term log retention matters |
| Label cardinality explosion | Stream count grows unbounded → memory / cost | Vector strips high-cardinality fields before pushing (we explicitly DO NOT label `session`, since each session is unique) |

## Replacements / future

- **Object-storage backend** — if this ever grows into a multi-node deployment,
  switch `storage.type` to a real object store and `deploymentMode` to
  `Distributed`. Not needed for a single node.
- **Elasticsearch / OpenSearch** — full-text search over log content;
  trades cheap storage for richer query power. Loki is sufficient for our
  pipeline-event oriented queries.
- **CloudWatch Logs / Datadog / Splunk** — managed alternatives. Drop Loki, run
  a Vector sink for the SaaS API. We avoid them by default for cost and
  data-residency reasons (DICOM-related events stay on-node).

## Future enhancements

- Recording rules for common LogQL queries (e.g. uploads-per-hour) so Grafana
  panels render faster
- LogQL → PrometheusRule for additional log-derived alerts (string-pattern
  alerts)
