# Loki

## Overview

[Loki](https://grafana.com/oss/loki/) is a log aggregation system designed
to be horizontally scalable, cheap to operate, and tightly integrated with
Grafana. It indexes a small set of labels (not the log content) and stores
the raw log lines as gzipped chunks in object storage. Queries use a
PromQL-like language called LogQL.

## Role in this stack

Loki is the **central log store**. Every Vector pod (mgmt + each edge child
cluster) pushes its collected log lines to Loki over HTTPS. Operators
query the data through Grafana's "Explore" view to follow a session's
journey, debug a failing edge, or audit who uploaded what when.

## What Loki has access to

- **In-cluster network** — accepts pushes from Vector, queries from Grafana
- **SeaweedFS S3 API** via the in-cluster Service URL
  `http://<release>-seaweedfs.<release-namespace>.svc.cluster.local:8333` —
  built by `mgmt.s3InternalEndpoint` in `charts/mgmt/templates/_helpers.tpl`,
  so with the installer's defaults (`MGMT_RELEASE=mgmt`, `MGMT_NS=ais-mgmt`
  in `install.sh`) it resolves to
  `http://mgmt-seaweedfs.ais-mgmt.svc.cluster.local:8333`. Plain http on
  purpose: it never leaves the cluster, and it avoids every edge of the
  custom-CA path. Uses a scoped IAM identity `loki-writer` that can only
  read/list/write/tag objects in the `logs-bucket`, and deliberately cannot
  see the ingest buckets — the log store has no business holding a key that
  reads imaging data.
- **That identity is not a ConfigMap.** A plaintext `s3-config` ConfigMap is
  precisely the bug the old imperative installer shipped (every edge's S3
  secret key readable by anything with configmap read; see the header of
  `charts/mgmt/templates/seaweedfs.yaml`). A Helm template cannot read a
  Secret's contents, so the chart cannot render `s3.json` at all — which is
  the point. The identity document is assembled *inside* the pod by the
  `build-s3-identities` init container from the per-identity Secrets
  projected in by name, and lands in a tmpfs `emptyDir{medium: Memory}`
  volume that merely happens to still be *named* `s3-config`. The chart's
  bucket hook Job (`<release>-seaweedfs-buckets`) is create-only and does
  nothing but create buckets — it never writes credentials.
- **A persistent volume (20Gi default)** for the TSDB index
  (`loki.loki.schemaConfig` pins `store: tsdb`, `schema: v13`,
  `index: {prefix: loki_index_, period: 24h}` — small, just label → chunk-id
  mappings) and for the compactor's local delete-request store. Size is
  `loki.singleBinary.persistence.size` in `charts/mgmt/values.yaml`, echoed
  by `observability.loki.persistenceSize`. The PVC carries
  `helm.sh/resource-policy: keep` **and** `enableStatefulSetAutoDeletePVC:
  false`: the annotation governs Helm only, and without the second flag the
  StatefulSet controller itself deletes the PVC when it is scaled to zero or
  removed.
- **NO host filesystem access** — runs as a regular pod on the cluster
  network with no hostPath mounts and no hostNetwork

## Where it runs

- Cluster: management cluster only
- Namespace: `ais-mgmt` — the release namespace (`MGMT_NS` in `install.sh`).
  There is no separate `observability` namespace: the observability stack is
  a set of pinned subcharts of `charts/mgmt` and renders into whatever
  namespace the release is installed in.
- Workload: StatefulSet `mgmt-loki` (single replica, monolithic mode)
- Service: `mgmt-loki.ais-mgmt.svc.cluster.local:3100` (ClusterIP)
- The name `mgmt-loki` comes from `loki.fullnameOverride` in
  `charts/mgmt/values.yaml`, and it is **pinned and load-bearing**: the
  `vector.sinks.loki.endpoint` block is subchart-literal, so Helm never
  templates it and it cannot follow `.Release.Name`. `_helpers.tpl` fails the
  render if the Vector endpoint names any other Service or namespace, and
  `templates/observability.yaml` computes the push Ingress backend the same
  way — so a rename cannot silently leave Vector retrying a dead address.
- External: nginx-ingress route `https://loki.aisedge.local:443` for
  Vector pods on edges to push to (TLS-terminated, signed by ais-edge-ca)

## Configuration

| File | Purpose |
|---|---|
| `charts/mgmt/values.yaml` (`loki:`) | helm chart values; deployment mode, S3 backend, retention |
| `charts/mgmt/templates/observability.yaml` | Ingress for `loki.aisedge.local`, `loki-tls` Certificate |
| `sites/<site>/values.yaml` | `hostnames.loki`, `seaweedfs.buckets.logs`, `observability.loki.*` (retention lives in the chart's `loki:` block) |
| `sites/<site>/secrets.enc.yaml` | the `loki-s3-credentials` Secret — `access-key`, `secret-key`; named by `observability.loki.s3SecretRef` |

Key tuning knobs in the values file:
- `deploymentMode: SingleBinary` — one pod runs all roles. Switch to
  `Distributed` (separate `read`/`write`/`backend` deployments) when
  ingest exceeds ~50 GB/day.
- `loki.loki.limits_config.retention_period` — a literal in
  `charts/mgmt/values.yaml` (`30d`, marked "THE one place Loki retention is
  set"). The compactor enforces it by deleting old chunks from S3. Override
  it only under `loki.loki.limits_config` in `sites/<site>/values.yaml`;
  there is no `OBSERVABILITY_RETENTION_DAYS` variable any more. Setting
  retention under `dataPolicy.telemetry.loki` is a **hard render failure**
  (`_helpers.tpl`) rather than a silent no-op, because Helm cannot template a
  subchart's values and a key that is read, trusted and ignored is worse than
  no key at all.
- `commonConfig.replication_factor: 1` — single-replica is fine for our
  single mgmt node. Bump to 3 if you go HA.

## Operations

```bash
# Pod state
kubectl -n ais-mgmt get pod -l app.kubernetes.io/name=loki

# Logs
kubectl -n ais-mgmt logs -l app.kubernetes.io/name=loki

# Inspect what's in the bucket (admin-side mc alias). There is no fixed
# "seaweedadmin" user: the admin identity is whatever you put in the
# `seaweedfs-admin` Secret (`access-key` / `secret-key`), which is the same
# Secret the bucket-creation hook uses.
kubectl -n ais-mgmt port-forward svc/mgmt-seaweedfs 8333:8333 &
AK=$(kubectl -n ais-mgmt get secret seaweedfs-admin -o jsonpath='{.data.access-key}' | base64 -d)
SK=$(kubectl -n ais-mgmt get secret seaweedfs-admin -o jsonpath='{.data.secret-key}' | base64 -d)
mc alias set seaweed-admin http://localhost:8333 "$AK" "$SK"
mc ls --recursive seaweed-admin/logs-bucket/ | head

# Query from the CLI. Prefer the in-cluster Service: the public
# loki.aisedge.local Ingress demands a CLIENT certificate
# (auth-tls-verify-client: "on" plus an auth-tls-match-cn pinned to the
# names in `edges`), and nginx's ssl_verify_client is a SERVER-block
# directive — so it covers the whole hostname, queries as well as pushes.
# A CA certificate alone will not get you in.
kubectl -n ais-mgmt port-forward svc/mgmt-loki 3100:3100 &
curl -sG http://localhost:3100/loki/api/v1/query \
  --data-urlencode 'query={cluster="edge-dev"}'

# Through the Ingress instead (logcli — install with `go install ...logcli`):
# you need an edge's client keypair, not just the trust anchor. It is issued
# on the management cluster as the `<edge>-loki-client` Secret and carried to
# the site by cert-sync.
logcli --addr=https://loki.aisedge.local --tls-skip-verify=false \
  --ca-cert=ais-edge-ca.crt \
  --cert=edge-dev-tls.crt --key=edge-dev-tls.key \
  query '{cluster="edge-dev"}'
```

## Benefits (why we chose Loki over alternatives)

- **Cheap storage** — chunks live in object storage we already operate
  (SeaweedFS), so adding logs doesn't require new infrastructure
- **Label-based indexing** — the index is tiny (~1% of log volume),
  meaning low memory and disk overhead at scale
- **Tight Grafana integration** — same UI as our metrics dashboards;
  operators don't context-switch
- **Single binary deploys** — one container in monolithic mode keeps the
  operational footprint small
- **Same vendor as Grafana / Prometheus / Mimir / Tempo** — coherent
  stack with shared semantics (LogQL ↔ PromQL)

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| SeaweedFS down | Loki cannot persist new chunks; ingester buffers in memory until OOM | SeaweedFSDown alert; fast restart of SeaweedFS bounces pipelines back |
| logs-bucket disk full on SeaweedFS | New writes fail; old logs may be unreadable until compactor frees space | Retention is set in days; SeaweedFSDiskFull alert at 80% |
| Index PV corruption | Loki may need to be reinitialised; chunks themselves remain in S3 | Persistent volume is small (20Gi, TSDB index only); reinitialise + re-run reads from S3. Note the PVC survives `helm uninstall` and StatefulSet deletion (`resource-policy: keep` + `enableStatefulSetAutoDeletePVC: false`), so a deliberate reinitialise means deleting it by hand |
| Loki pod crash | Logs queued in Vector's disk buffer get held until Loki recovers | Vector handles backpressure; replay continues automatically |
| Edge client key leak | An attacker could push fake logs (would need network reachability) | The push Ingress requires a client certificate signed by ais-edge-ca whose CN is one of the sites in `edges`. Keys are per-edge and cert-manager replaces them every 90 days with `rotationPolicy: Always`; revoke sooner by deleting the `<edge>-loki-client` Secret (cert-manager reissues) or by removing the site from `edges` and upgrading, which drops it from `auth-tls-match-cn` |
| Label cardinality explosion | Stream count grows unbounded → memory / cost | Vector strips high-cardinality fields before pushing (we explicitly DO NOT label `session` for example, since each session is unique) |

### Why `compactor.delete_request_store` is `filesystem`, not `s3`

`s3` builds the delete store from `storage_config.aws` — a different config
path from the `common.storage.s3` block `loki.storage` renders into, which
the Loki chart never populates. The compactor then resolves an empty bucket
name and Loki exits 1 at startup:

```
init compactor: failed to init delete store: failed to get s3 object:
... api error NoSuchBucket: The specified bucket does not exist
```

which reads as "the bucket was never created" and is not — `aws s3api
get-object` with Loki's own credentials returns `NoSuchKey` against that same
bucket while Loki keeps reporting `NoSuchBucket`.

Setting `storage_config.aws` directly does not fix it either: the chart
treats that as taking manual control and blanks
`common.storage.s3.bucketnames` in response (its `_helpers.tpl` only fills
the bucket name when `storage_config.aws` is unset), so chunks and the index
lose their bucket instead. **Verified both ways on a live cluster.**

This deployment runs SingleBinary with a persistent PVC at `/var/loki`, so
the delete-request store has the same durability as the rest of Loki's local
state and does not need S3 at all — only chunks and the index do. A
distributed Loki would need the S3 form, and would then need both config
blocks kept in step by hand.

## Replacements / future

- **Mimir-style scale-out** — when ingest exceeds ~50 GB/day or queries
  span multi-cluster, switch the `deploymentMode` to `Distributed` and
  scale `read`/`write`/`backend` independently
- **Elasticsearch / OpenSearch** — full-text search over log content;
  trades cheap storage for richer query power. Use if compliance requires
  free-text audit on every line. Loki is sufficient for our pipeline-event
  oriented queries
- **CloudWatch Logs / Datadog / Splunk** — managed alternatives. Drop
  Loki, run a Vector sink for the SaaS API. Useful if the operations
  team already pays for one. We avoid them by default for cost and
  data-residency reasons (DICOM-related events stay on UQ infra)

## Future enhancements

- Recording rules for common LogQL queries (e.g. uploads-per-cluster) so
  Grafana panels render faster
- LogQL → PrometheusRule for additional log-derived alerts that don't
  fit Vector's `log_to_metric` (string-pattern alerts)
- Multi-tenant mode with per-edge tenant IDs (currently we use a single
  tenant and label-scope by `cluster=`)
