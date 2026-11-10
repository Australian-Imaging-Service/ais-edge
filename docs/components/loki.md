# Loki

## Overview

[Loki](https://grafana.com/oss/loki/) is a log aggregation system designed
to be horizontally scalable, cheap to operate, and tightly integrated with
Grafana. It indexes a small set of labels (not the log content) and stores
the raw log lines as compressed chunks, here on a local PVC. The chunk encoding is a Loki setting; Vector's HTTP gzip compression does not establish the stored chunk format. Queries use a PromQL-like language called LogQL.

## Role in this stack

Loki is the **log store** for the single node. The Vector DaemonSet tails every
pod's stdout and pushes the collected log lines to the in-cluster Loki Service.
Operators query the data through Grafana's "Explore" view to follow a session's
journey, debug the pipeline, or audit who uploaded what when.

Loki is a **vendored subchart of `charts/edge`**, not a separate release:
`loki` 7.1.0 (Loki 3.6.8), shipped as
[`charts/edge/charts/loki-7.1.0.tgz`](../../charts/edge/charts/) and gated on
`observability.stack.enabled`. There is no `helm repo add` and no
`helm dependency update` at install time — a hospital appliance must not need a
working path to `grafana.github.io` in order to reinstall.

**`observability.stack.enabled` is not `observability.enabled`.** The first
decides whether this node *hosts* a log store (plus Prometheus, Alertmanager and
Grafana); the second only decides whether Vector runs. On a tier-2 edge Vector is
on and the stack is off, because the logs are pushed to a Loki in the management
cluster. Both are false by default.

## What Loki has access to

- **In-cluster network** — accepts pushes from Vector, queries from Grafana,
  and pushes ruler alerts to Alertmanager
- **Local filesystem storage on a PVC** — chunks, index and the compactor's
  working directory live under `/var/loki` on a PersistentVolume (the node's
  `local-path` StorageClass). This is the single-binary standard; there is
  **no S3 / object store** in tier-1.
- **NO hostNetwork, no hostPath** beyond the PVC — runs as a regular pod

## Where it runs

- Cluster: the single-node cluster
- Namespace: the release namespace — **`xnat-ingest`**, the same namespace as
  the pipeline. There is no separate `observability` namespace; the whole
  appliance is one release in one namespace.
- Workload: StatefulSet `ais-loki` (single replica, single-binary mode).
  Containers: `loki` and `loki-sc-rules` (the rules sidecar, below).
- Service: `ais-loki.xnat-ingest.svc.cluster.local:3100` (ClusterIP; `9095` is
  gRPC)
- No external ingress — Vector pushes to the ClusterIP Service directly over
  plain http (no 443/SNI/TLS hop).

**`ais-loki` is a pinned name, not the release name.** `loki.fullnameOverride`
is set in `charts/edge/values.yaml` because the `edge.lokiEndpoint` helper in
[`charts/edge/templates/_helpers.tpl`](../../charts/edge/templates/_helpers.tpl)
constructs Vector's `LOKI_ENDPOINT` as
`http://ais-loki.<namespace>.svc.cluster.local:3100` from outside the subchart,
where `.Release.Name` is not a name it can rely on. Drop the override and a
release called anything other than `ais` leaves Vector retrying an address that
never resolves — which looks exactly like a quiet site.

## Configuration

Everything lives in `sites/<site>/values.yaml`. Loki's own settings sit under
the **top-level `loki:` key**, which Helm passes through to the subchart;
`install.sh` uses `-f sites/<site>/values.yaml` and no `--set`, so anything not
in that file is the chart default from
[`charts/edge/values.yaml`](../../charts/edge/values.yaml).

| Values path | What it does |
|---|---|
| `observability.stack.enabled` | Gates the `loki` and `kube-prometheus-stack` dependencies (the `condition:` in `Chart.yaml`). **Must keep a default of `false`** — Helm treats a dependency whose condition path does not resolve as ENABLED, so the key existing and being false is what keeps a tier-2 edge rendering as before |
| `loki.deploymentMode: SingleBinary` | One pod runs all roles, backed by a local PVC. `backend`/`read`/`write` are set to 0 replicas |
| `loki.loki.storage.type: filesystem` and `schemaConfig[].object_store: filesystem` | Chunks + index on the PVC. No `bucketNames`, no credentials, nothing to back up in an object store |
| `loki.loki.limits_config.retention_period` | **THE retention knob** (`30d` by default). The compactor enforces it by deleting old chunks from the PVC — `compactor.retention_enabled: true`, `delete_request_store: filesystem` |
| `loki.singleBinary.persistence.size` / `.storageClass` | **THE PVC size** (`20Gi` on `local-path`). Retention is ultimately disk-bound on the node |
| `loki.loki.commonConfig.replication_factor: 1` | Single replica is correct for a single node |
| `loki.loki.auth_enabled: false` | One node, no tenants, no ingress |
| `loki.loki.rulerConfig` | The ruler — see below |
| `loki.chunksCache` / `resultsCache` / `lokiCanary` / `gateway` / `test` | All `enabled: false`. One node, one replica: nothing to cache or distribute |

**Historical dead-key audit, date not recorded; current disposition checked
2026-11-10.** `observability.stack.retentionDays` and
`observability.stack.lokiStorage.*` were removed from the defaults because no
consumer used them. Do not restore them or keep a duplicate setting in sync.
Use `loki.loki.limits_config.retention_period` and
`loki.singleBinary.persistence.*`. `scripts/ci/values-consumers.sh` still audits
only `dataPolicy.*`; it does not prove that an arbitrary site override works.
Inspect the rendered Loki ConfigMap and PVC when changing retention or storage.

### The ruler

`loki.loki.rulerConfig` turns on Loki's ruler, which evaluates the **LogQL
pipeline alerts** (Prometheus handles the K8s-state alerts). Two details it is
easy to get wrong, both of which fail silently:

- `alertmanager_url` must name the Alertmanager the `kube-prometheus-stack`
  subchart actually creates, which follows *its* `fullnameOverride` — so
  `http://ais-kps-alertmanager.<namespace>.svc.cluster.local:9093`, not
  `<release>-kube-prometheus-stack-alertmanager`. This has been wrong once: the
  ruler pushed to a name that does not resolve, and every LogQL alert never
  fired while Loki, the rules and the dashboards all looked healthy.
- The ruler now reads `/rules`; the `loki-sc-rules` sidecar watches
  ConfigMaps labelled `loki_rule` and writes under `/rules/fake` for the
  single tenant. Both containers mount the same rules volume. A historical
  `/etc/loki/rules` mismatch, date not recorded, is fixed in the current values.
  Check loaded rules after a change; a running pod alone does not prove evaluation.

`charts/edge` now ships **21 LogQL alert rules** in
`charts/edge/files/loki-ruler-rules.yaml`, loaded by a labelled ConfigMap from
`templates/observability.yaml` when the stack is enabled. Additional site rules
can use the same label and namespace. See
[`docs/alerting-diy.md`](../alerting-diy.md).

### Grafana does not get a Loki datasource automatically

`kube-prometheus-stack` provisions only Prometheus and Alertmanager
(ConfigMap `ais-kps-grafana-datasource`). To query logs in Explore, add Loki —
either in the Grafana UI, or in `sites/<site>/values.yaml`:

```yaml
kube-prometheus-stack:
  grafana:
    additionalDataSources:
      - name: Loki
        type: loki
        uid: loki
        access: proxy
        url: http://ais-loki.xnat-ingest.svc.cluster.local:3100
```

## Operations

```bash
# Pod state
kubectl -n xnat-ingest get pod -l app.kubernetes.io/name=loki

# Logs
kubectl -n xnat-ingest logs statefulset/ais-loki -c loki

# Query from CLI (logcli) via port-forward — install with `go install ...logcli`
kubectl -n xnat-ingest port-forward svc/ais-loki 3100:3100 &
logcli --addr=http://localhost:3100 query '{namespace="xnat-ingest"}'

# Disk usage of the Loki PVC (retention is disk-bound)
kubectl -n xnat-ingest exec statefulset/ais-loki -c loki -- df -h /var/loki

# Is Vector actually pointed at this Service?
kubectl -n xnat-ingest get ds -l app=vector \
  -o jsonpath='{.items[0].spec.template.spec.containers[0].env[?(@.name=="LOKI_ENDPOINT")].value}'
```

## Benefits (why we chose Loki over alternatives)

- **Cheap, simple storage** — chunks live on the node's local PVC; no object
  store to run or back up on a single-node appliance
- **Label-based indexing**: log content is not indexed as full text. The earlier
  ~1% size estimate is not verified (2026-11-10). Measure local index, WAL and
  compactor storage against the actual stream cardinality and retention.
- **Tight Grafana integration** — same UI as our metrics dashboards;
  operators don't context-switch
- **Single binary deploys** — one container keeps the operational footprint small
- **Grafana integration**: logs and metrics share a UI. Prometheus is a
  separate project, and its PromQL rules cannot directly evaluate Loki LogQL.

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| Loki PVC disk full | New writes fail; old logs may be unreadable until the compactor frees space | Set `loki.loki.limits_config.retention_period` and size `loki.singleBinary.persistence.size` against the node's disk |
| Loki pod crash | Vector applies backpressure while its default memory buffer fills; a Vector restart or a long log rotation gap can lose pending data | No persistent sink buffer is configured. Check post-recovery log continuity; checkpoints alone do not preserve queued events. |
| `helm uninstall`, or scaling the StatefulSet to zero | The rendered Loki StatefulSet uses Delete for both claim-retention actions, and its claim template has no Helm keep annotation | The PVC CI check explicitly exempts these observability object names. This is a current retention choice, not a missing render case. Logs may contain identifiers or sensitive errors and historical events do not regenerate. Back up required logs and choose an explicit retention policy before destructive maintenance. Imaging PVC retention is checked separately. |
| PVC corruption | Loki may need reinitialising; historical logs on the PVC may be lost | Back up the PVC if long-term log retention matters |
| Label cardinality explosion | Stream count grows unbounded → memory / cost | Vector promotes only `cluster`, `namespace`, `pod`, `container`, `node`, `app`, `component`, `level` to stream labels and sets `remove_label_fields: true`. We explicitly DO NOT label `session`, since each session is unique — it stays a JSON field in the body, reached with `\| json \| session="..."` |

## Replacements / future

- **Object-storage backend** — if this ever grows into a multi-node deployment,
  switch `storage.type` to a real object store and `deploymentMode` to
  `Distributed`. Not needed for a single node. (This is the one genuine
  divergence from the management-side Loki, which keeps chunks in SeaweedFS
  over S3.)
- **Elasticsearch / OpenSearch** — full-text search over log content;
  trades cheap storage for richer query power. Loki is sufficient for our
  pipeline-event oriented queries.
- **CloudWatch Logs / Datadog / Splunk** — managed alternatives. Drop Loki, run
  a Vector sink for the SaaS API. We avoid them by default for cost and
  data-residency reasons (DICOM-related events stay on-node).

## Future enhancements

- Recording rules for common LogQL queries (e.g. uploads-per-hour) so Grafana
  panels render faster
- Additional LogQL alerts belong in Loki ruler files. A PrometheusRule
  evaluates PromQL, so it cannot execute LogQL directly. A future recording-rule
  path would first export numeric series to a metrics backend.
