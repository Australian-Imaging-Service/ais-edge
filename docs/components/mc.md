# mc (MinIO Client)

## Overview

[`mc`](https://min.io/docs/minio/linux/reference/minio-mc.html) is the
command-line client for any S3-compatible storage. It's vendor-neutral
despite the "minio" in the name — speaks the same protocol against
SeaweedFS, AWS S3, MinIO, Garage, Ceph RGW, etc.

## Role in this stack

The S3 uploader on every edge worker. We run `mc` inside a tiny
DaemonSet pod (`s3-uploader`) that loops every 30 seconds:
1. Scan `/data/staging/*/` for completed session directories
2. `mc mirror --overwrite` each session into
   `s3://ingest-bucket/staged/<session>/`
3. On success, `rm -rf` the local copy
4. Emit a JSON log line per event

Why not write the upload logic in Python (as part of xnat-ingest)?
Three reasons:
- xnat-ingest's upload command pushes to **XNAT**, not to S3
- mc handles multipart, parallel, resumable uploads natively — no
  point reimplementing
- mc is a thin wrapper; the s3-uploader pod is just `mc` + a 20-line
  shell loop, easy to reason about

## What mc has access to

- **hostPath `/data/xnat-ingest/staging/`** (read + delete after success)
- **Outbound HTTPS** to `https://seaweedfs.aisedge.local:443`
- **Secret `s3-edge-credentials`** — write+list scoped key for the
  edge's specific identity in SeaweedFS
- **Secret `ca-bundle`** mounted at `/root/.mc/certs/CAs/ca.crt` —
  the public ais-edge-ca cert; mc adds it to its trust store and
  verifies the seaweedfs-tls server cert against it

## Where it runs

- Cluster: each edge child cluster
- Namespace: `xnat-ingest`
- Workload: Deployment `s3-uploader` (one replica)
- Image: `minio/mc:latest`
- Hostnames resolved via `hostAliases` (no in-cluster DNS for
  aisedge.local hostnames inside this pod)

## Configuration

The s3-uploader manifest is a single bash loop. It's defined inline
in `manifests/02-edge/xnat-ingest.yaml.tpl` — no external script. Key
env vars:

```yaml
env:
  - name: S3_ENDPOINT       value: https://seaweedfs.aisedge.local
  - name: S3_BUCKET         value: ingest-bucket
  - name: EDGE_NAME         value: <cluster-name>          (for log enrichment)
  - name: S3_ACCESS_KEY     fromSecret: s3-edge-credentials
  - name: S3_SECRET_KEY     fromSecret: s3-edge-credentials
```

The shell loop:
```bash
mc alias set edge "${S3_ENDPOINT}" "${S3_ACCESS_KEY}" "${S3_SECRET_KEY}"
while true; do
  for session in /data/staging/*/; do
    mc --json mirror --overwrite "$session" "edge/${S3_BUCKET}/staged/$(basename "$session")/"
    && rm -rf "$session"
  done
  sleep 30
done
```

(In reality the script also emits structured JSON log lines for
upload_started / upload_completed / upload_failed events that Vector
turns into Prometheus counters.)

## Operations

```bash
# Pod state
KUBECONFIG=kubeconfig-edge-dev kubectl get pods -n xnat-ingest -l component=s3-uploader

# Live JSON logs
KUBECONFIG=kubeconfig-edge-dev kubectl logs -n xnat-ingest \
  -l component=s3-uploader -f | jq

# Inside the pod (interactive debugging)
KUBECONFIG=kubeconfig-edge-dev kubectl exec -it -n xnat-ingest \
  deploy/s3-uploader -- /bin/sh
mc ls edge/ingest-bucket/staged/    # list what's been uploaded

# Test the TLS path to SeaweedFS
KUBECONFIG=kubeconfig-edge-dev kubectl exec -n xnat-ingest \
  deploy/s3-uploader -- mc admin info edge
```

## Benefits

- **Vendor-neutral** — same client works against AWS S3 if we ever
  swap SeaweedFS out
- **Trust model is just a PEM file** — drop ca-bundle Secret in
  `/root/.mc/certs/CAs/`, no env-var tomfoolery
- **`mc --json`** — first-class structured-output mode that Vector
  parses without grok
- **Multipart, parallel, resumable** — handles 100GB+ DICOMs without
  custom logic
- **Tiny image** — `minio/mc` is ~20MB

## Risks and failure modes

| Risk | Impact | Mitigation |
|---|---|---|
| `ca-bundle` Secret missing | TLS verify fails: "x509: cert signed by unknown authority" | Pushed by `07-deploy-edge-ingest.sh`; verifiable with `kubectl exec ... -- mc alias set edge ...` |
| Wrong S3 access key | 403 Forbidden | Each edge has its own scoped identity; rotated by editing `edge-nodes.env` and re-running script 03 |
| Endpoint hostname unresolvable | "no such host" | `hostAliases` injected at pod-spec time |
| Disk full on edge | mc mirror fails with no-space | `/data/xnat-ingest` is the worker's hostPath; size accordingly |
| Deletes the wrong session | Data loss | We only `rm -rf` after `mc mirror` returns success; idempotent re-runs are safe |
| Image image pulled from registry | Edge needs internet to pull `minio/mc:latest` first time | Same as xnat-ingest: in air-gap, pre-import via `ctr` |

## Replacements / future

- **`aws s3 sync`** — same idea, different binary; would need to
  install awscli into a custom image. Less ergonomic
- **`rclone`** — broader provider support, similar feature set. Worth
  considering if we ever need to sync to multiple targets
- **Native xnat-ingest S3 push** — xnat-ingest could write to S3
  directly, removing the mc pod entirely. Currently it only reads
  from S3 (in the upload command); a `--s3-target` flag for the assign
  command is a candidate upstream PR

## Future enhancements

- DICOM SHA256 calculated by mc and stored as object tag — enables
  after-the-fact integrity comparison against XNAT
- Bandwidth limit (`mc mirror --limit-upload 50Mi`) — useful at sites
  with metered links
- Compression of DICOMs before upload (lossless) — DICOMs are usually
  already compressed but small headers add up
