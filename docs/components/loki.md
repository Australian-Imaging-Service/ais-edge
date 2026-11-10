# Loki

## Overview

[Loki](https://grafana.com/oss/loki/) is a log aggregation system designed
to be horizontally scalable, cheap to operate, and tightly integrated with
Grafana. It indexes a small set of labels (not the log content) and stores
the raw log lines as compressed chunks in object storage. The chunk encoding is a Loki setting; Vector's HTTP gzip compression does not establish the stored chunk format. Queries use a
PromQL-like language called LogQL.

## Role in this stack

Loki is the **central log store**. Every Vector pod (mgmt + each edge child
cluster) pushes its collected log lines to Loki. Edges use HTTPS with a client
certificate; management Vector uses the in-cluster HTTP Service. Operators
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
  purpose: it uses the cluster network and avoids the external TLS ingress.
  Cluster-internal traffic is not automatically encrypted and can cross hosts
  in a multi-node deployment. Uses a scoped IAM identity `loki-writer` that can only
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
- **A persistent volume (20Gi default)** for the WAL, local working state and TSDB index
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
  another supported mode only after a capacity and migration test. The earlier
  ~50 GB/day trigger is not verified (2026-11-10). `read`/`write`/`backend`
  describe SimpleScalable roles, not the Distributed microservices layout.
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
  single mgmt node. Raising this number alone does not provide HA: replicas,
  storage, placement, ring membership and the failure test must agree.

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

# mc alias set saves credentials in the local mc configuration. Use a protected
# operator account and remove the temporary alias after inspection. The keys
# above also pass through process arguments; use the site credential policy.

# Query from the CLI. Prefer the in-cluster Service: the public
# loki.aisedge.local Ingress demands a CLIENT certificate
# (auth-tls-verify-client: "on" plus an auth-tls-match-cn pinned to the
# names in `edges`), and nginx's ssl_verify_client is a SERVER-block
# directive — so it covers the whole hostname, queries as well as pushes.
# A CA certificate alone will not get you in.
kubectl -n ais-mgmt port-forward svc/mgmt-loki 3100:3100 &
curl -sG http://localhost:3100/loki/api/v1/query_range \
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
- **Label-based indexing**: log content is not indexed as full text. The earlier
  ~1% size estimate is not verified (2026-11-10). Measure local index, WAL and
  compactor storage against the actual stream cardinality and retention.
- **Tight Grafana integration** — same UI as our metrics dashboards;
  operators don't context-switch
- **Single binary deploys** — one container in monolithic mode keeps the
  operational footprint small
- **Grafana ecosystem integration**: Loki, Grafana, Mimir and Tempo share
  integrations. Prometheus is a separate open-source project. LogQL resembles
  PromQL but the query languages and their rule evaluators are not interchangeable.

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| SeaweedFS down | Chunk flushes fail; retry, WAL and memory capacity limit how long ingestion can continue | Investigate SeaweedFSDown and Loki write errors. Recovery time and loss-free outage duration are not verified (2026-11-10); test them with the site workload. |
| logs-bucket disk full on SeaweedFS | New writes fail; old logs may be unreadable until compactor frees space | Retention is set in days; SeaweedFSDiskFull alert at 80% |
| Local PV corruption | Index, WAL or compactor state can be lost even when flushed chunks remain in S3 | Preserve the volume and investigate recovery before deleting anything. The 20Gi PVC holds more than the index. It is configured to survive Helm and StatefulSet deletion; S3 chunks alone do not prove that every accepted log can be recovered. |
| Loki pod crash | The configured Vector sink uses its default memory buffer; pending events can be lost if Vector also restarts | Source checkpoints persist, but they are not an event queue. Long stalls can also outlast kubelet log retention. Verify recent ingestion after recovery; no disk sink buffer is configured. |
| Edge client key leak | A reachable attacker can submit logs and query the shared tenant with an allowed client certificate | The ingress checks the signed certificate and allowed CN, not the submitted cluster label or query scope. Certificates last 90 days and renew 30 days before expiry. Deleting a Secret or renewing it does not revoke the old keypair; remove the CN from ingress admission when isolating a site, and assess trust-anchor replacement if that is insufficient. |

| Label cardinality explosion | Stream count grows unbounded → memory / cost | Vector strips high-cardinality fields before pushing (we explicitly DO NOT label `session` for example, since each session is unique) |

### Why `compactor.delete_request_store` is `filesystem`, not `s3`

**Historical incident, date not recorded; live reproduction not verified
(2026-11-10).** The following failure explains the retained filesystem choice.
The current values select `filesystem` with an explicit root beneath `/var/loki`.
For the chart configuration investigated at the time, `s3` built the delete store from `storage_config.aws` ; a different config
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
lose their bucket instead. **Historically reported as tested both ways on a live cluster; test date and
current-version replay are not verified (2026-11-10).**

This deployment runs SingleBinary with a persistent PVC at `/var/loki`, so
the delete-request store has the same durability as the rest of Loki's local
state and does not need S3 at all — only chunks and the index do. A
distributed Loki would need the S3 form, and would then need both config
blocks kept in step by hand.

## Replacements / future

- **Loki scale-out**: choose a supported object-store deployment mode after
  measuring ingestion, query load and recovery requirements. The old 50 GB/day
  trigger is unverified. SimpleScalable uses `read`/`write`/`backend`; Distributed
  uses individual services. Neither is a one-value migration from this PVC.
- **Elasticsearch / OpenSearch** — full-text search over log content;
  trades cheap storage for richer query power. Use if compliance requires
  free-text audit on every line. Loki is sufficient for our pipeline-event
  oriented queries
- **CloudWatch Logs / Datadog / Splunk** — managed alternatives. Drop
  Loki, run a Vector sink for the SaaS API. Useful if the operations
  team already pays for one. We avoid them by default for cost and
  data-residency reasons (keep DICOM-related events on site-approved infrastructure)

## Future enhancements

- Recording rules for common LogQL queries (e.g. uploads-per-cluster) so
  Grafana panels render faster
- Additional LogQL alerts belong in Loki ruler files. A PrometheusRule
  evaluates PromQL, so it cannot execute LogQL directly. A future recording-rule
  path would first export numeric series to a metrics backend.
- Multi-tenant mode with per-edge tenant IDs (currently we use a single
  tenant and filter by `cluster=`; that filter is not an authorization boundary)

### Delete-request store path

The management chart stores log chunks in S3 and delete requests on the Loki
persistent volume. `compactor.working_directory` holds local compactor work;
it does not set the root of the filesystem object store. Set
`loki.loki.storage_config.filesystem.directory` to `/var/loki/delete-requests`.
Without that root, the default `index/` prefix is relative to the container's
read-only working directory and upload of the delete-request database fails
with `mkdir index: read-only file system`.

The path is under the existing `/var/loki` volume. It keeps the compactor
metadata across restarts without granting writes to the container root. The
tier-1 chart uses filesystem chunk storage, which already supplies
`/var/loki/chunks` as the filesystem root; that configuration needs no change.
See the [Loki storage and compactor configuration](https://grafana.com/docs/loki/latest/configure/).
