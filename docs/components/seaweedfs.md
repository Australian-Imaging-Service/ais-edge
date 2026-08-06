# SeaweedFS

## Overview

[SeaweedFS](https://seaweedfs.com/) is a distributed file/object store with
an S3-compatible API. We use it as the central staging layer between edge
sites and XNAT. Apache 2.0 licensed.

## Role in this stack

The DICOM staging buffer. Edge sites upload session directories via S3
PUT (`mc mirror`) into the `ingest-bucket` `staged/` prefix. The
management-side `xnat-ingest-upload` pod polls the bucket and forwards
new sessions to XNAT. SeaweedFS also stores the observability stack's
logs (Loki writes chunked log data to a separate `logs-bucket`).

## What SeaweedFS has access to

- **hostPath `/data/seaweedfs`** on the management node (Haystack
  volumes + filer leveldb)
- **In-cluster network** (its own Service)
- **No outbound network** — fully passive; only accepts requests
- **S3 IAM identities** in the `s3-config` ConfigMap, scoped per writer:
  - `admin` — full access to everything (used by mgmt mc + upload pod)
  - `<edge-name>` — write+list scoped to `ingest-bucket` only
  - `loki-writer` — read+write+list scoped to `logs-bucket` only

## Where it runs

- Cluster: management cluster only
- Namespace: `seaweedfs`
- Workload: Deployment `seaweedfs` (single replica, all-in-one)
- Image: `chrislusf/seaweedfs:4.34` (was 3.99 — moved off it because 3.99 is
  vulnerable to CVE-2026-54917, CVE-2026-58372 and CVE-2026-55874: three S3
  path traversals that let one site's key read, copy and *delete* across
  another site's bucket. 4.34 is the lowest version clean of all six published
  SeaweedFS advisories. Issue #9035, the 4.18/4.19 filer memory regression the
  old pin avoided, is closed — but see the risk table for #10253, which is not.
  The Iceberg REST Catalog 4.x turns on by default is disabled explicitly with
  `-s3.port.iceberg=0`.)
- Service: `seaweedfs.seaweedfs.svc.cluster.local` (ClusterIP only)
- External: nginx-ingress route `https://seaweedfs.aisedge.local:443`
  (TLS-terminated, signed by ais-edge-ca)
- Metrics Service: `seaweedfs-metrics.seaweedfs.svc:9324`

## Configuration

| File | Purpose |
|---|---|
| `charts/mgmt/templates/seaweedfs.yaml` | Deployment, Service, Certificate, Ingress, bucket-creation hook |
| `charts/mgmt/values.yaml` (`seaweedfs:`) | storage path, per-site bucket toggle, image tag |
| `config/management.env` | `S3_ADMIN_*`, `S3_BUCKET`, `LOGS_BUCKET`, `LOKI_S3_*`, `SEAWEEDFS_HOSTNAME` |

## Operations

```bash
# Pod state
kubectl get pods -n seaweedfs

# In-cluster S3 (admin)
kubectl port-forward -n seaweedfs svc/seaweedfs 8333:8333 &
mc alias set seaweed http://localhost:8333 seaweedadmin <secret>
mc ls seaweed/ingest-bucket/staged/    # see staged sessions

# Master + filer admin UIs
kubectl port-forward -n seaweedfs svc/seaweedfs 9333:9333 &  # master
kubectl port-forward -n seaweedfs svc/seaweedfs 8888:8888 &  # filer

# Re-render s3.json after editing edge-nodes.env
helm upgrade mgmt charts/mgmt -n ais-mgmt -f sites/<site>/values.yaml
# (idempotent — recomputes the config-hash annotation, rolls the pod)
```

### Deletion must go through the filer, never `aws s3 rm`

Measured on SeaweedFS 3.99: `aws s3 rm --recursive` (and `mc rm` before it)
removes the objects but leaves a 0-byte directory entry, which `aws s3 ls`
still reports as `PRE <session>/`. An empty prefix is exactly what makes the
uploader log a bogus success every cycle — switching S3 client does not fix
it, only the filer can remove a directory entry:

```
DELETE http://<filer>:8888/buckets/<bucket>/<prefix>/<session>?recursive=true
```

Measured: returns 204 and the entry is genuinely gone, where the same session
deleted with `aws s3 rm --recursive` still lists. This is why
`charts/mgmt/files/reclaim-staged.sh` deletes through the filer HTTP API and
never shells out to `aws s3 rm`.

## Benefits

- **All-in-one** — master + volume + filer + S3 in a single pod for
  the MVP. No separate components to operate
- **Apache 2.0** — clean licensing
- **S3-compatible** — every S3 client (mc, boto3, AWS SDK) works
- **Cheap on disk** — Haystack format keeps small files efficient
- **Built-in Prometheus metrics** on `:9324`

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| Pod crash | Edge uploads + Loki writes pause | Pod auto-restarts; fast (~10s) |
| `/data/seaweedfs` disk full | Writes fail | `SeaweedFSDiskFull` alert at 80%; retention CronJob (TODO) deletes uploaded sessions |
| Single replica | Window of unavailability during pod restart | Acceptable for staging (edge + xnat-upload retry naturally) |
| `s3-config` ConfigMap drift | Auth fails | Re-running script 03 regenerates it; config-hash annotation rolls the pod |
| Filer memory growth on 4.x | Pod OOMKilled and restarts | Upstream #10253 is still open (steady growth under concurrent load). Bounded here by `resources.limits.memory: 4Gi` — it costs a restart, not the node — and `SeaweedFSDown` fires. Accepted in exchange for closing the cross-bucket traversals; watch `container_memory_working_set_bytes` for the pod |
| aws-cli checksum headers verified only against 3.99 | Uploads rejected | `x-amz-checksum-*` acceptance was measured against 3.99's S3 gateway only. 4.34's `auth_credentials.go` is roughly three times the size of 3.99's; the identity/action semantics we depend on are unchanged, but the checksum path was not re-measured. **Re-measure against 4.34 before trusting it** |

## Replacements / future

- **MinIO** — was the original choice; archived in Feb 2026 → switched
  to SeaweedFS
- **AWS S3** — drop SeaweedFS entirely; point edges + upload pod at
  `s3.<region>.amazonaws.com` with IAM users. Documented in main README.
- **Garage** — Rust-based S3 implementation; lighter than SeaweedFS but
  newer. Considered, not adopted (SeaweedFS' ecosystem is more mature)
- **Multi-replica scale-out** — split master/volume/filer/S3 into
  separate Deployments with 3-master Raft + N volume servers + 2+
  filers behind a Service. Documented in README "Scaling SeaweedFS"

## Future enhancements

- S3 lifecycle rules to auto-delete sessions older than N days from
  `ingest-bucket/staged/` after XNAT confirms
- Dedicated metrics service-monitor (currently the metrics port is
  exposed but Prometheus discovery via ServiceMonitor needs verification
  against the 3.99 metrics format; re-checked on 4.34 — the three
  `SeaweedFS_volumeServer_*` series these read are unchanged, 4.x only adds)
- Replication: 3-master HA with Raft, separate volume/filer/s3
  deployments
