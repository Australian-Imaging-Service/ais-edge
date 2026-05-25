# GCP install (GKE)

> Status: **untested, design complete**. Same shape as AWS — GKE bundles
> its own cloud-controller-manager, so step 01b auto-skips and the install
> runs unchanged with `CLOUD_PROVIDER=gcp`.

## TL;DR

```bash
gcloud container clusters create ais-edge-mgmt \
  --region=australia-southeast1 \
  --num-nodes=2 \
  --machine-type=e2-standard-2 \
  --release-channel=stable
gcloud compute addresses create ais-edge-lb \
  --region=australia-southeast1   # reserves a static regional IP
# Edit config/management.env (CLOUD_PROVIDER=gcp, INSTALL_MODE=existing, etc.)
./install.sh -y
```

## Prerequisites

1. GCP project with billing enabled + the following APIs:
   - Kubernetes Engine API
   - Compute Engine API
   - Cloud DNS API (if you want managed DNS)
2. `gcloud` CLI authenticated:
   ```bash
   gcloud auth login
   gcloud auth application-default login    # populates ADC
   gcloud config set project <your-project>
   ```
3. `kubectl`, `helm` v3.

## Step 1 — Create the GKE cluster

```bash
gcloud container clusters create ais-edge-mgmt \
  --region=australia-southeast1 \
  --num-nodes=2 \
  --machine-type=e2-standard-2 \
  --release-channel=stable \
  --workload-pool=<your-project>.svc.id.goog   # enables Workload Identity
```

Takes ~5-7 min. Workload Identity is GCP's IAM-for-pods (similar to AWS
IRSA) — useful later if you want pods to call GCP APIs directly.

```bash
gcloud container clusters get-credentials ais-edge-mgmt \
  --region=australia-southeast1
kubectl get nodes
```

## Step 2 — Reserve a static regional IP

```bash
gcloud compute addresses create ais-edge-lb \
  --region=australia-southeast1
gcloud compute addresses describe ais-edge-lb \
  --region=australia-southeast1 \
  --format='value(address)'
# Returns the IP, e.g. 34.x.y.z
```

This is what `LB_PUBLIC_IP` will be set to; the K8s Service of type
LoadBalancer attaches this IP to the auto-provisioned GCP network LB.

## Step 3 — DNS

**Dev** (no DNS to register):
```bash
INTERNAL_DOMAIN="dev.<ip-with-dashes>.nip.io"
```

**Prod** (Cloud DNS):
```bash
gcloud dns managed-zones create aisedge \
  --dns-name=aisedge.example.com. \
  --description="AIS Edge prod"
# Add A records pointing *.aisedge.example.com → 34.x.y.z
```

## Step 4 — Config

`config/management.env`:

```bash
export CLOUD_PROVIDER="gcp"
export CLOUD_CREDENTIALS_FILE=""       # gcloud ADC is auto-discovered
export INSTALL_MODE="existing"         # we're using GKE
export INSTALL_TOPOLOGY="cloud"
export LB_PUBLIC_IP="34.x.y.z"         # the reserved static IP
export INTERNAL_DOMAIN="aisedge.example.com"
export CERT_ISSUER="letsencrypt-prod"
export DNS_PROVIDER="clouddns"         # for cert-manager DNS-01
```

## Step 5 — Run install.sh

```bash
./install.sh -y
```

| Step | What happens on GCP |
|---|---|
| 01  | Skipped (`INSTALL_MODE=existing`) |
| 01b | Skipped (`CLOUD_PROVIDER=gcp` → managed K8s) |
| 02–04, 02d | Standard |
| 02c | nginx-ingress → GCP creates a regional Network LB with your static IP |
| 05–07c | Standard edge setup; edges hit the LB hostname over public DNS+443 |

## Step 6 — Verify

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller
# EXTERNAL-IP should equal your reserved static IP

curl -v https://loki.aisedge.example.com/ready
# Expect 200 with a valid Let's Encrypt cert
```

## Cost ballpark (Sydney region, 2026)

| Item | Approx monthly |
|---|---|
| GKE Autopilot cluster fee | $0 (waived) |
| 2 × e2-standard-2 nodes | ~$110 |
| 1 × regional Network LB | ~$22 |
| 100 GB pd-standard PD | ~$4 |
| Static IP (used) | $0 (free when attached) |
| **Total** | **~$140/mo** |

(Or use GKE Standard mode if you want to pin node specs — slightly more
expensive but predictable.)

## Workload Identity for cert-manager DNS-01

To let cert-manager call Cloud DNS:

```bash
# 1. Create a GCP service account
gcloud iam service-accounts create cert-manager-dns01 \
  --project=<your-project>

# 2. Grant Cloud DNS admin
gcloud projects add-iam-policy-binding <your-project> \
  --member="serviceAccount:cert-manager-dns01@<your-project>.iam.gserviceaccount.com" \
  --role="roles/dns.admin"

# 3. Bind to the cert-manager k8s ServiceAccount
gcloud iam service-accounts add-iam-policy-binding \
  cert-manager-dns01@<your-project>.iam.gserviceaccount.com \
  --member="serviceAccount:<your-project>.svc.id.goog[cert-manager/cert-manager]" \
  --role="roles/iam.workloadIdentityUser"

# 4. Annotate the cert-manager ServiceAccount
kubectl annotate serviceaccount -n cert-manager cert-manager \
  iam.gke.io/gcp-service-account=cert-manager-dns01@<your-project>.iam.gserviceaccount.com
```

No secret files anywhere — cert-manager pulls a short-lived GCP token from
the metadata server.

## Common gotchas

- **GKE Autopilot vs Standard**: Autopilot doesn't let you SSH to nodes or
  install DaemonSets that need host access. Most of our edge setup runs on
  the edge k0s clusters (which we control), so Autopilot is fine for the
  mgmt cluster. Just confirm nginx-ingress + cert-manager are pod-only and
  don't need hostPath / hostNetwork.
- **Regional vs zonal LBs**: GCP regional Network LBs default to TCP/UDP
  pass-through, which is what we want for SNI passthrough at ingress-nginx.
- **Pricing surprises**: Cloud Storage egress out of GCP to non-GCP XNAT
  targets is the biggest cost driver, not the cluster itself.
