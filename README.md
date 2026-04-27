# k0s + k0smotron + SeaweedFS — Edge Medical Imaging Ingest

A centrally-managed edge computing system for medical imaging data capture and upload to XNAT.
Part of [NIF FDRI Stream 2](https://github.com/Australian-Imaging-Service).

> **Branch note: this is the `AB_dev` branch using SeaweedFS for S3 storage.**
> The `main` branch uses MinIO. SeaweedFS was adopted on this branch after MinIO's
> open-source repository was archived (Feb 2026). SeaweedFS is Apache 2.0, S3-compatible,
> and lighter on resources than MinIO. The S3 client side (`mc`, `boto3`) is unchanged —
> the storage backend is a swap-in replacement.

## Architecture

```
                Management Node                           Edge Worker(s)
          ┌──────────────────────────┐             ┌──────────────────────────┐
          │  k0s (or existing k8s)   │             │  k0s worker              │
          │                          │             │                          │
          │  k0smotron operator      │             │  xnat-ingest-sort pod    │
          │  ├─ hosted control plane │◄────────────┤  └─ watches /incoming    │
          │  │  (API + etcd + konect)│ konnectivity│     stages DICOMs        │
          │  │                       │  (outbound  │                          │
          │  SeaweedFS (S3 storage)  │   from edge)│  s3-uploader pod         │
          │  ├─ receives staged files│◄────────────┤  └─ mc mirror → SeaweedFS│
          │  │  s3://ingest-bucket/  │  write-only │     (scoped S3 key)      │
          │  │                       │  S3 upload  │                          │
          │  xnat-ingest-upload pod  │             │  Credentials on edge:    │
          │  ├─ reads from SeaweedFS │             │  └─ S3 write-only key    │
          │  └─ uploads to XNAT      │             │                          │
          │     (has XNAT creds)     │             │  Inbound ports: ZERO     │
          │                          │             │  All connections outbound│
          │  Credentials here:       │             │                          │
          │  ├─ XNAT admin creds     │             └──────────────────────────┘
          │  └─ S3 admin creds       │
          └─────────┬────────────────┘
                    │ HTTPS REST API
                    ▼
          ┌──────────────────────────┐
          │  XNAT Server             │
          │ (separate infrastructure)│
          │  xnat.example.com        │
          └──────────────────────────┘
```

## Data Flow

```
1. DICOM files arrive in /data/xnat-ingest/incoming/ on edge worker
         │
         ▼
2. xnat-ingest sort (on edge)
   - Parses DICOM metadata (project, subject, visit, scan)
   - Stages to /data/staging/PROJECT.SUBJECT.VISIT/
   - Deletes from incoming after staging
         │
         ▼
3. s3-uploader (on edge, using `mc mirror`)
   - Reads staged sessions from /data/staging/
   - Mirrors to SeaweedFS at s3://ingest-bucket/staged/ (write-only key)
   - Deletes local copy only after successful upload
   - SeaweedFS (via S3 API) handles multipart upload, checksums, resume on failure
         │
         ▼
4. SeaweedFS (on management node)
   - Stores files under s3://ingest-bucket/staged/<session>/
   - Write-only from edge, full access from management
         │
         ▼
5. xnat-ingest upload (on management node)
   - Reads from s3://ingest-bucket/staged
   - Uploads to XNAT via REST API (XNAT credentials only here)
   - Creates project/subject/session/scan hierarchy in XNAT
   - Verifies checksums after upload
   - Skips sessions already in XNAT (idempotent)
```

## How the S3 Uploader Works

The `s3-uploader` pod runs on the edge worker using the `minio/mc` (MinIO Client) image.
It's a simple shell loop — no custom code:

```bash
# Configure mc with the write-only credentials
mc alias set edge "http://<MGMT_IP>:31090" "<access-key>" "<secret-key>"

# Loop forever, checking every 30 seconds
while true; do
    for session_dir in /data/staging/*/; do
        # Upload entire session directory to SeaweedFS, preserving structure
        mc mirror --overwrite "$session_dir" "edge/ingest-bucket/staged/$session_name/"

        # Delete local copy only after successful upload
        rm -rf "$session_dir"
    done
    sleep 30
done
```

`mc mirror` is like `rsync` for S3. Under the hood it:
- Breaks large files into **multipart chunks** (handles 100GB+ files)
- Uploads chunks in **parallel** for speed
- Verifies **MD5 checksums** after each chunk
- **Retries failed chunks** automatically
- Only transfers **new/changed files** if re-run (delta sync)

The actual protocol is standard HTTP PUT to the S3 API — the same protocol AWS S3 uses.
If SeaweedFS is swapped for AWS S3, the uploader works without changes (just a different endpoint URL).

## Security Model

```
Edge Worker                           Management Node             XNAT
├─ S3 write-only key                  ├─ S3 admin key             ├─ User data
│  (write+list on one bucket only)    ├─ XNAT admin credentials   │
│  (cannot read other sites' data)    │                           │
├─ NO XNAT credentials                │                           │
├─ NO inbound ports                   │                           │
├─ Outbound only:                     │                           │
│  → konnectivity tunnel (:30443)     │                           │
│  → SeaweedFS S3 upload (:31090)     │                           │
```

| If compromised... | Impact |
|--------------------|--------|
| Edge worker | Attacker sees local DICOMs + scoped S3 key. Key can only write to ingest bucket. Cannot read other sites' data. Cannot access XNAT. |
| Edge S3 key | Can write junk to one bucket. Cannot read data. Cannot access XNAT. Cannot impersonate other sites. |
| Management node | Full access — this is your crown jewel. Harden accordingly. |

## Repository Structure

```
k0s-k0smotron-mvp/
├── README.md                              ← You are here
├── install.sh                             ← Main installer (run this)
├── config/
│   ├── management.env.template            ← Management node config (copy to management.env)
│   ├── edge-nodes.env.template            ← Edge nodes config (copy to edge-nodes.env)
│   └── k0s-controller.yaml               ← k0s cluster config
├── manifests/
│   ├── 01-management/                     ← Runs on management cluster
│   │   ├── edge-cluster.yaml.tpl          ← Hosted k0s control plane per edge site
│   │   ├── seaweedfs.yaml.tpl             ← SeaweedFS S3 storage
│   │   └── xnat-upload.yaml.tpl           ← Reads SeaweedFS → uploads to XNAT
│   └── 02-edge/                           ← Runs on edge workers (child cluster)
│       └── xnat-ingest.yaml.tpl           ← Sort + s3-uploader pods
├── scripts/
│   └── uninstall.sh                       ← Tears down everything
└── .gitignore
```

`.tpl` files are manifest templates — placeholders like `{{CLUSTER_NAME}}` are replaced with
values from your config files during installation.

## Prerequisites

- **Management node**: Ubuntu 22.04+, 8GB+ RAM, 100GB+ disk
- **Edge worker(s)**: Ubuntu 22.04+, 4GB+ RAM, 50GB+ disk
- **SSH access**: Key-based SSH from management node to each edge worker
- **XNAT instance**: Accessible via HTTPS with a local service account
- **Outbound internet**: Both management and edge nodes need it (for pulling container images)

## Quick Start

```bash
# 1. Clone this repo on the management node
git clone <repo-url> && cd k0s-k0smotron-mvp

# 2. Configure management node
cp config/management.env.template config/management.env
vim config/management.env   # set MGMT_NODE_IP, XNAT credentials, S3 admin keys

# 3. Configure edge nodes
cp config/edge-nodes.env.template config/edge-nodes.env
vim config/edge-nodes.env   # add your edge nodes to the EDGE_NODES array

# 4. Ensure SSH access to edge nodes
ssh-keygen -t ed25519       # if you don't have a key
ssh-copy-id ubuntu@<edge-ip>

# 5. Install
chmod +x install.sh scripts/*.sh
./install.sh
```

## Installing on an Existing Kubernetes Cluster

If you already have a Kubernetes cluster running (k3s, kubeadm, MicroK8s, etc.):

1. Set `INSTALL_MODE="existing"` in `config/management.env`
2. Ensure `kubectl` is configured and pointing to your cluster (`~/.kube/config`)
3. Ensure a default StorageClass exists (check with `kubectl get sc`)
4. Run `./install.sh` — it will skip k0s installation and use your existing cluster

The installer will deploy k0smotron, SeaweedFS, and the upload pod as regular workloads
on your existing cluster. Everything else works the same.

## Adding More Edge Nodes

Edit `config/edge-nodes.env` and add entries to the `EDGE_NODES` array:

```bash
EDGE_NODES=(
  "edge-uqcai|203.101.230.171|ubuntu|~/.ssh/id_ed25519|uqcai-project|edge-uqcai-key|uqcai-secret"
  "edge-usyd|10.0.1.50|ubuntu|~/.ssh/id_ed25519|usyd-project|edge-usyd-key|usyd-secret"
  "edge-newcastle|10.0.2.50|ubuntu|~/.ssh/id_ed25519|newcastle-project|edge-newcastle-key|newcastle-secret"
)
```

Each edge node gets:
- Its own hosted k0s control plane (separate namespace on management cluster)
- Its own scoped S3 credentials (write+list to ingest bucket only — isolated per site)
- Its own kubeconfig file (`kubeconfig-edge-uqcai`, etc.)
- Its own xnat-ingest pods

Then re-run `./install.sh` — it will skip already-installed components and only set up new nodes.

## Removing a Single Edge Node

To remove one edge site without affecting others:

```bash
# 1. Delete workloads on the edge cluster
kubectl --kubeconfig kubeconfig-edge-uqcai delete namespace xnat-ingest

# 2. Reset the edge worker VM
ssh ubuntu@<edge-ip> "sudo k0s stop && sudo k0s reset"

# 3. Delete the hosted cluster from management
kubectl delete namespace edge-uqcai

# 4. Remove the S3 identity (regenerate s3.json without this edge user)
#    Just remove the entry from edge-nodes.env, then re-run scripts/03-deploy-seaweedfs.sh
#    (it regenerates the SeaweedFS s3.json ConfigMap and rolls the pod)

# 5. Clean up generated files
rm kubeconfig-edge-uqcai join-token-edge-uqcai

# 6. Remove the entry from config/edge-nodes.env
```

## Tested Versions

| Component | Version | Notes |
|-----------|---------|-------|
| Ubuntu | 22.04.5 LTS | Management and edge nodes |
| k0s | v1.35.2+k0s.0 | Both management cluster and edge workers |
| k0smotron | v1.10.4 (stable) | Installed via `kubectl apply` (not Helm) |
| cert-manager | latest | Required by k0smotron for webhook TLS |
| SeaweedFS | 3.99 | `chrislusf/seaweedfs:3.99` (last 3.x stable, avoids 4.18/4.19 filer memory regression — issue #9035) |
| MinIO Client (mc) | latest | `minio/mc:latest` — vendor-neutral S3 client used by edge s3-uploader |
| xnat-ingest | latest | `ghcr.io/australian-imaging-service/xnat-ingest:latest` |
| local-path-provisioner | v0.0.30 | Default StorageClass for etcd PVCs |

To pin specific versions in production, replace `:latest` / `:3.99` tags in the `.tpl`
manifests with explicit versions (e.g. `chrislusf/seaweedfs:3.99-rc1`).

## How the Template System Works

Manifest files ending in `.tpl` contain placeholders like `{{S3_BUCKET}}`.
The `render()` function in `scripts/00-common.sh` performs simple string replacement
at install time — no Helm, no Jinja, no external tools required.

```bash
# Example: what happens when install.sh processes seaweedfs.yaml.tpl
Input:   nodePort: {{S3_NODEPORT}}
Output:  nodePort: 31090
```

Values come from `config/management.env` and `config/edge-nodes.env`. You never edit `.tpl` files.

## S3 Path Structure in SeaweedFS

```
s3://ingest-bucket/
└── staged/
    ├── test-project.patient01.visit01/           ← one directory per session
    │   └── 1.T1w_MPRAGE/                        ← scan ID + description
    │       └── DICOM/                            ← resource type
    │           ├── file1.dcm
    │           ├── file2.dcm
    │           └── MANIFEST.json
    ├── test-project.patient02.visit01/
    │   └── ...
    └── ...
```

The `staged/` prefix separates ingest data from any other bucket contents.
Session directory names follow the format `PROJECT.SUBJECT.VISIT`.

## Edge Data Directory Structure

On each edge worker at `/data/xnat-ingest/`:

```
/data/xnat-ingest/
├── incoming/            ← Drop DICOM files here (from scanner, manual copy, etc.)
├── staging/
│   ├── __build__/       ← Sessions being assembled (don't touch)
│   ├── __invalid__/     ← Sessions with missing/bad metadata (review manually)
│   └── PROJECT.SUBJECT.VISIT/  ← Valid sessions waiting for S3 upload
```

Files flow: `incoming/` → `staging/` → SeaweedFS → eventually deleted from edge after successful S3 upload.

## Health Checks

```bash
# Management cluster health
kubectl get pods -A                              # all pods should be Running
kubectl get nodes                                # management node should be Ready

# Edge cluster health
kubectl --kubeconfig kubeconfig-<name> get nodes  # edge worker should be Ready
kubectl --kubeconfig kubeconfig-<name> get pods -n xnat-ingest  # sort + s3-uploader Running

# SeaweedFS health
curl -s http://<MGMT_IP>:31090/                  # S3 endpoint — should return XML/empty 200
curl -s http://<MGMT_IP>:31091/cluster/status    # master endpoint — should return JSON
curl -s http://<MGMT_IP>:31092/                  # filer endpoint — should return HTML

# SeaweedFS from edge (test connectivity)
ssh ubuntu@<EDGE_IP> "curl -s http://<MGMT_IP>:31090/"

# SeaweedFS bucket contents
mc ls seaweed/ingest-bucket/staged/              # list sessions in bucket

# XNAT connectivity
curl -sk <XNAT_URL>                              # should return HTML

# Check logs for errors
kubectl logs -n xnat-upload -l component=upload --tail=5           # XNAT upload
kubectl --kubeconfig kubeconfig-<name> logs -n xnat-ingest -l component=sort --tail=5
kubectl --kubeconfig kubeconfig-<name> logs -n xnat-ingest -l component=s3-uploader --tail=5
```

## SeaweedFS Master & Filer UIs

SeaweedFS exposes two built-in web UIs for inspecting cluster state. They're read-only;
admin actions go through the S3 API or `weed shell`.

```
Master UI: http://<MGMT_IP>:31091
   Shows cluster topology, volume servers, free capacity, leader election

Filer UI:  http://<MGMT_IP>:31092
   Browse the filesystem layer (objects appear under /buckets/<bucket>/...)
```

For a more familiar S3-style admin experience, use `mc`:

```bash
mc alias set seaweed http://<MGMT_IP>:31090 <admin-key> <admin-secret>
mc ls seaweed/                                    # list buckets
mc ls --recursive seaweed/ingest-bucket/staged/   # list sessions
mc admin info seaweed                             # cluster info
```

## Updating Components

**Update xnat-ingest image:**
```bash
# Edge cluster — restart pods to pull latest image
kubectl --kubeconfig kubeconfig-<name> rollout restart deployment/xnat-ingest-sort -n xnat-ingest
kubectl --kubeconfig kubeconfig-<name> rollout restart deployment/s3-uploader -n xnat-ingest

# Management cluster — restart XNAT upload pod
kubectl rollout restart deployment/xnat-ingest-upload -n xnat-upload
```

**Update SeaweedFS:**
```bash
kubectl rollout restart deployment/seaweedfs -n seaweedfs
```

**Update k0s on edge workers:**
k0s supports in-place upgrades via Autopilot. For manual upgrade:
```bash
ssh ubuntu@<EDGE_IP>
sudo k0s stop
curl -sSLf https://get.k0s.sh | sudo sh    # installs latest
sudo k0s start
```

**Update k0smotron:**
```bash
kubectl apply --server-side=true -f https://docs.k0smotron.io/stable/install.yaml
```

## Backup and Restore

**What to back up:**
- `config/management.env` and `config/edge-nodes.env` — your configuration
- SeaweedFS data (`/data/seaweedfs/` on management node) — staged files in transit
- XNAT — your actual data destination (backed up separately)

**What does NOT need backup:**
- Edge worker data (`/data/xnat-ingest/`) — transient staging area
- k0s/k0smotron state — can be rebuilt from this repo
- Generated files (`kubeconfig-*`, `join-token-*`) — regenerated on install

**Restoring from scratch:**
1. Provision fresh VMs
2. Clone this repo, copy your saved config files
3. Run `./install.sh`

## Known Limitations

- **No TLS on SeaweedFS** — data between edge and SeaweedFS is unencrypted. For production,
  put SeaweedFS behind a reverse proxy with TLS or use SeaweedFS's built-in TLS.
- **No monitoring/alerting** — SeaweedFS disk usage, pod health, and upload failures
  are not automatically monitored. Add Prometheus + Grafana for production
  (SeaweedFS exposes Prometheus metrics on the master and filer).
- **Single management node** — no HA for k0smotron or SeaweedFS. For production,
  split SeaweedFS into separate master/volume/filer/s3 deployments and run 3 masters
  with an external etcd or Consul; see "Scaling SeaweedFS" below.
- **DICOM files with missing AccessionNumber** go to `__invalid__/` — requires manual
  rename. This is an xnat-ingest limitation, not a system issue. Real clinical DICOMs
  will have this field populated.
- **emptyDir persistence for hosted control planes** — etcd data is lost if the
  management node restarts. For production, use a proper StorageClass with persistent volumes.
- **No automatic cleanup of SeaweedFS** — successfully uploaded sessions remain in
  SeaweedFS until manually deleted. Add an S3 lifecycle rule or a cleanup job for
  production.

## Scaling SeaweedFS

The single-pod all-in-one deployment is for the MVP. For production scale-out, split
the SeaweedFS components into separate Deployments/StatefulSets:

| Component | What it does | HA recommendation |
|---|---|---|
| Master | Cluster metadata, leader election | 3 replicas (Raft consensus) |
| Volume server | Stores chunked data | N replicas across nodes; each backed by its own disk |
| Filer | Filesystem layer (required for S3) | 2+ replicas; backed by an external metadata store (Redis/ScyllaDB/Postgres) |
| S3 gateway | S3 API endpoint | 2+ replicas behind a Service / load balancer |

Edge clients (`mc mirror`) don't change — they still talk to the S3 endpoint. The
internal architecture changes; the external API does not.

## XNAT Configuration

Before ingesting data, ensure:

1. **XNAT project exists** — create it in the XNAT web UI before uploading.
   The project ID must match `PROJECT_ID` in `config/edge-nodes.env`.
2. **XNAT user is a local account** — not AAF/OIDC. Create via Administer → Users.
3. **XNAT user has project permissions** — at least Member or Collaborator on the target project.

xnat-ingest authenticates via `POST /data/JSESSION` with username/password and uses the
session token for all subsequent REST API calls.

## Accessing Clusters

```bash
# Management cluster
kubectl get pods -A

# Specific edge cluster
kubectl --kubeconfig kubeconfig-edge-uqcai get pods -n xnat-ingest
kubectl --kubeconfig kubeconfig-edge-usyd get nodes

# Logs
kubectl --kubeconfig kubeconfig-edge-uqcai logs -n xnat-ingest -l component=sort -f
kubectl --kubeconfig kubeconfig-edge-uqcai logs -n xnat-ingest -l component=s3-uploader -f
kubectl logs -n xnat-upload -l component=upload -f   # management upload to XNAT

# SeaweedFS UIs
# Master:  http://<MGMT_NODE_IP>:31091
# Filer:   http://<MGMT_NODE_IP>:31092
```

## Testing

```bash
# Copy a DICOM file to the edge node
scp test.dcm ubuntu@<EDGE_IP>:/data/xnat-ingest/incoming/

# Watch sort pod pick it up
kubectl --kubeconfig kubeconfig-edge-dev logs -n xnat-ingest -l component=sort -f

# If the DICOM has missing metadata (e.g. no AccessionNumber), it goes to __invalid__
# Rename and move it manually:
ssh ubuntu@<EDGE_IP>
cd /data/xnat-ingest/staging
sudo mv __invalid__/<session-dir> ./test-project.subject01.visit01

# Watch s3-uploader push to SeaweedFS
kubectl --kubeconfig kubeconfig-edge-dev logs -n xnat-ingest -l component=s3-uploader -f

# Watch upload to XNAT
kubectl logs -n xnat-upload -l component=upload -f
```

## Failure Scenarios

| Scenario | What happens | Recovery |
|----------|-------------|---------|
| Network drops mid-upload | SeaweedFS S3 multipart — completed chunks saved | mc retries on next loop cycle |
| Edge VM crashes | Files safe in /data/staging/ | k0s auto-starts, pods resume |
| SeaweedFS crashes | Edge uploads fail, files safe on edge | Pod auto-restarts, edge retries |
| Management node crashes | Edge files accumulate locally | Management restarts, edge reconnects |
| XNAT is down | SeaweedFS fills up | XNAT returns, upload pod clears backlog |
| SeaweedFS disk full | Edge uploads fail, files safe on edge | Expand `/data/seaweedfs/` or clear XNAT backlog |

## FAQ

**Q: Can I run k0smotron on my existing k3s/kubeadm cluster?**
Yes. Set `INSTALL_MODE="existing"` in `config/management.env`. k0smotron is just a Kubernetes
operator — it runs on any conformant cluster with cert manager. Edge workers still use k0s.

**Q: Does k0s run on Windows?**
Not natively. Options: WSL2, Hyper-V VM, or Docker Desktop.

**Q: What credentials are stored on the edge?**
Only a scoped SeaweedFS S3 key. It can only PUT/LIST on one bucket. It cannot read other
sites' data, access XNAT, or do anything else. XNAT credentials never leave the management node.

**Q: How does the edge communicate without inbound ports?**
All connections are outbound from the edge:
- Konnectivity tunnel to management node (port 30443) — for cluster management
- S3 upload to SeaweedFS on management node (port 31090) — for data transfer
The management node sends commands back through the konnectivity tunnel (edge-initiated).

**Q: What is konnectivity?**
A reverse tunnel built into Kubernetes. The edge opens an outbound connection to the
management node and keeps it open. kubectl commands flow back through this same connection.
No inbound ports needed on the edge.

**Q: What happens if the SeaweedFS edge key is stolen?**
An attacker can only write junk files to the ingest bucket. They cannot read other sites'
data, cannot access XNAT, and cannot access patient information. The key is easily rotated.

**Q: How do I rotate the SeaweedFS edge credentials?**
1. Generate new credentials in `config/edge-nodes.env` for that edge entry.
2. Re-run `scripts/03-deploy-seaweedfs.sh` — it regenerates `s3.json` from env and
   rolls the SeaweedFS pod via the config-hash annotation. Old credentials become invalid.
3. Re-run `scripts/07-deploy-edge-ingest.sh <entry>` for the affected edge — the K8s
   Secret on the edge cluster is updated and the s3-uploader pod restarts.

**Q: What is a "child cluster" vs "management cluster"?**
The management cluster runs k0smotron and hosts control planes for edge sites.
Each edge site has a "child cluster" — its own Kubernetes cluster whose control plane
runs as pods on the management node, but whose workers are at the edge site.
They have separate kubeconfigs, namespaces, and RBAC.

**Q: Can one edge site have multiple workers?**
Yes. Give multiple machines the same join token and they all join the same child cluster.
Pin specific pods to specific workers using `nodeSelector` in the manifest.

## Troubleshooting

**k0s worker not joining:**
- Check token: `sudo cat /etc/k0s/join-token | head -c 50` (should not be empty)
- Check connectivity: `curl -sk https://<MGMT_IP>:30443/version` (should return JSON)
- Check logs: `sudo journalctl -u k0sworker --no-pager -n 30`
- Note: `k0s status` does NOT work on workers. Use `systemctl is-active k0sworker`.

**Pods stuck in Pending:**
- Check events: `kubectl describe pod <name> -n <namespace>`
- Common cause: no StorageClass (management cluster needs local-path-provisioner)
- Edge pods use hostPath, not PVC — check directory exists on worker

**xnat-ingest sort puts files in __invalid__:**
- The DICOM file is missing required metadata (usually AccessionNumber)
- This is normal for sample files. Rename and move manually for testing.
- With real clinical DICOMs, this won't happen.

**Upload pod can't reach SeaweedFS:**
- Test from edge: `curl -s http://<MGMT_IP>:31090/`
- Check firewall rules on management node
- Check SeaweedFS pod: `kubectl logs -n seaweedfs -l app=seaweedfs`

**Upload pod can't reach XNAT:**
- Test: `curl -sk <XNAT_URL>`
- Check XNAT credentials in management cluster secret
- XNAT project must exist before upload (create in XNAT web UI)

## Using AWS S3 Instead of SeaweedFS

This setup uses self-hosted SeaweedFS by default, but you can swap it for AWS S3 (or any
S3-compatible service like Google Cloud Storage, Backblaze B2, MinIO, Garage, Ceph RGW)
with minimal changes — `mc` and `boto3` speak vanilla S3.

### What Changes

| Component | SeaweedFS (default) | AWS S3 |
|-----------|--------------------|--------|
| Storage server | SeaweedFS pod on management node | AWS managed service |
| Management manifests | `manifests/01-management/seaweedfs.yaml.tpl` deployed | **Not deployed** — skip step 03 |
| Upload pod S3 endpoint | `http://seaweedfs.seaweedfs.svc.cluster.local:8333` | `https://s3.amazonaws.com` (default) |
| Edge S3 endpoint | `http://<MGMT_IP>:31090` | `https://s3.<region>.amazonaws.com` |
| Credentials | SeaweedFS s3.json identities | AWS IAM access keys |

### Step-by-Step

**1. Create AWS resources:**
```bash
# Create an S3 bucket
aws s3 mb s3://my-ingest-bucket --region ap-southeast-2

# Create an IAM user for the edge (write-only)
aws iam create-user --user-name edge-writer
aws iam put-user-policy --user-name edge-writer --policy-name write-only --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect":"Allow","Action":["s3:PutObject","s3:DeleteObject"],"Resource":"arn:aws:s3:::my-ingest-bucket/*"},
    {"Effect":"Allow","Action":["s3:ListBucket","s3:GetBucketLocation"],"Resource":"arn:aws:s3:::my-ingest-bucket"}
  ]
}'
aws iam create-access-key --user-name edge-writer
# → note the AccessKeyId and SecretAccessKey

# Create an IAM user for the management upload pod (read + delete)
aws iam create-user --user-name mgmt-reader
aws iam put-user-policy --user-name mgmt-reader --policy-name read-delete --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect":"Allow","Action":["s3:GetObject","s3:DeleteObject","s3:ListBucket","s3:GetBucketLocation"],"Resource":["arn:aws:s3:::my-ingest-bucket","arn:aws:s3:::my-ingest-bucket/*"]}
  ]
}'
aws iam create-access-key --user-name mgmt-reader
```

**2. Update config files:**

`config/management.env`:
```bash
export S3_BUCKET="my-ingest-bucket"
# These become the management upload pod's AWS credentials:
export S3_ADMIN_ACCESS_KEY="<mgmt-reader-access-key>"
export S3_ADMIN_SECRET_KEY="<mgmt-reader-secret-key>"
```

`config/edge-nodes.env`:
```bash
EDGE_NODES=(
  "edge-uqcai|203.101.230.171|ubuntu|~/.ssh/id_ed25519|uqcai-project|<edge-writer-access-key>|<edge-writer-secret-key>"
)
```

**3. Modify manifests:**

`manifests/01-management/xnat-upload.yaml.tpl` — remove the `AWS_ENDPOINT_URL` env var
(so boto3 defaults to real AWS S3):
```yaml
# DELETE this line:
#   - name: AWS_ENDPOINT_URL
#     value: "http://seaweedfs.seaweedfs.svc.cluster.local:8333"
```

`manifests/02-edge/xnat-ingest.yaml.tpl` — change the s3-uploader endpoint env to AWS S3:
```yaml
# Change the S3_ENDPOINT value to:
value: "https://s3.ap-southeast-2.amazonaws.com"
```

**4. Install — skip step 03 (SeaweedFS):**

When running `./install.sh`, press `s` at step 03 to skip SeaweedFS deployment.
Everything else remains the same.

### Advantages of AWS S3

- No SeaweedFS to manage, monitor, or back up
- Automatic redundancy and durability (11 nines)
- Cross-region replication available
- Pay-per-use (no disk provisioning)
- IAM policies are more granular than SeaweedFS's

### Advantages of SeaweedFS (self-hosted)

- Data never leaves your infrastructure (important for patient data pre-de-identification)
- No cloud costs
- No internet dependency between management and storage
- Full control over data residency and compliance

## Uninstall

```bash
./scripts/uninstall.sh
```

This removes everything: edge workers, SeaweedFS data, hosted clusters, k0smotron, and
optionally k0s itself (if installed fresh).

## Network Ports

| From | To | Port | Purpose |
|------|-----|------|---------|
| Edge | Management | 30443 | k0s API + konnectivity tunnel |
| Edge | Management | 30132 | Konnectivity (additional) |
| Edge | Management | 31090 | SeaweedFS S3 uploads |
| Edge | Management | 31091 | SeaweedFS master UI (admin only) |
| Edge | Management | 31092 | SeaweedFS filer UI (admin only) |
| Management | XNAT | 443 | XNAT REST API uploads |
| Management | Edge | 22 | SSH (initial setup only) |

All edge traffic is **outbound only**.
