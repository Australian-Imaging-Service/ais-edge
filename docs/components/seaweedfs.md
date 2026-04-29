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
- Image: `chrislusf/seaweedfs:3.99` (last 3.x stable; pinned to avoid
  the 4.18/4.19 filer memory regression)
- Service: `seaweedfs.seaweedfs.svc.cluster.local` (ClusterIP only)
- External: nginx-ingress route `https://seaweedfs.aisedge.local:443`
  (TLS-terminated, signed by ais-edge-ca)
- Metrics Service: `seaweedfs-metrics.seaweedfs.svc:9324`

## Configuration

| File | Purpose |
|---|---|
| `manifests/01-management/seaweedfs.yaml.tpl` | Deployment, ClusterIP Service, metrics Service, hostPath volume |
| `manifests/01-management/seaweedfs-tls-cert.yaml.tpl` | server cert (Certificate signed by ais-edge-ca-issuer) |
| `manifests/01-management/seaweedfs-ingress.yaml.tpl` | nginx Ingress for `seaweedfs.aisedge.local` |
| `scripts/03-deploy-seaweedfs.sh` | renders s3.json from EDGE_NODES + Loki creds, applies all of the above, creates `ingest-bucket` and `logs-bucket` |
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
bash scripts/03-deploy-seaweedfs.sh
# (idempotent — recomputes the config-hash annotation, rolls the pod)
```

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
| 4.x filer memory regression | Memory growth | We pin to 3.99 explicitly; revisit when 4.x is stable |

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
  against the 3.99 metrics format)
- Replication: 3-master HA with Raft, separate volume/filer/s3
  deployments
