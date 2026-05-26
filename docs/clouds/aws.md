# AWS install (EKS)

> Status: **untested in CI, design complete**. The codebase has all the
> abstractions to support AWS without modifications, but the only
> end-to-end install validated so far is OpenStack/Nectar — see
> [openstack-nectar.md](openstack-nectar.md). This page is the AWS path
> written for someone new to AWS.

## TL;DR

```bash
eksctl create cluster --name ais-edge-mgmt --region ap-southeast-2 --managed
aws ec2 allocate-address --domain vpc                         # returns ElasticIP
# Edit config/management.env with CLOUD_PROVIDER=aws, INSTALL_MODE=existing,
# LB_PUBLIC_IP=<eip>, INTERNAL_DOMAIN=<your zone or nip.io>
./install.sh -y
```

That's it. EKS bundles its own cloud-controller-manager so the OCCM step
01b auto-skips. The rest of the install runs unchanged.

## Prerequisites

1. **AWS account + IAM user with**:
   - EKS cluster create/manage
   - EC2: VPC, subnets, security groups, Elastic IP
   - IAM: roles for EKS node groups, RBAC bindings
   - ELB: NLB create/manage (for the K8s Service type=LoadBalancer)
2. **CLI tools**:
   - `aws` v2.x — `aws configure` once, the SDK chain finds creds in
     `~/.aws/credentials` automatically.
   - `eksctl` — easiest cluster creator.
   - `kubectl` (matched to EKS version).
   - `helm` v3.
3. A **DNS zone** you own (Route 53 makes life easy) OR a willingness to
   use nip.io for dev.

## Step 1 — Create the EKS cluster

```bash
eksctl create cluster \
  --name ais-edge-mgmt \
  --region ap-southeast-2 \
  --nodegroup-name workers \
  --nodes 2 \
  --node-type t3.large \
  --managed \
  --with-oidc
```

Takes ~15 minutes. When done:

```bash
aws eks update-kubeconfig --region ap-southeast-2 --name ais-edge-mgmt
kubectl get nodes   # 2 nodes Ready
```

The cluster ships with:
- Built-in cloud-controller-manager (handles Service type=LoadBalancer → NLB)
- EBS CSI driver (storage class `gp2` is default — works for SeaweedFS)
- VPC CNI (so cross-AZ pod-to-pod networking just works)

## Step 2 — Pre-allocate an Elastic IP

```bash
aws ec2 allocate-address --domain vpc --region ap-southeast-2
# Returns:
# {
#   "PublicIp": "13.x.y.z",
#   "AllocationId": "eipalloc-..."
# }
```

`PublicIp` is what edges + DNS will point at. Note it.

## Step 3 — Set DNS (or use nip.io for dev)

**Dev** (no DNS to register):
```bash
INTERNAL_DOMAIN="dev.<eip-with-dashes>.nip.io"
# e.g. dev.13-x-y-z.nip.io
```

**Prod** (Route 53 hosted zone you own):
```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id <your-zone-id> \
  --change-batch '{
    "Changes": [{
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "*.aisedge.example.com",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [{ "Value": "<the EIP>" }]
      }
    }]
  }'
```

## Step 4 — Config

`config/management.env`:

```bash
export CLOUD_PROVIDER="aws"
export CLOUD_CREDENTIALS_FILE=""    # SDK chain reads ~/.aws/credentials
export INSTALL_MODE="existing"      # we're using EKS, not fresh-installing k0s
export INSTALL_TOPOLOGY="cloud"
export LB_PUBLIC_IP="<your Elastic IP>"
export INTERNAL_DOMAIN="aisedge.example.com"   # or .<eip>.nip.io for dev
export CERT_ISSUER="letsencrypt-prod"          # AWS + real DNS = real LE certs
export DNS_PROVIDER="route53"                  # for cert-manager DNS-01
# Plus an aws-route53-credentials Secret in cert-manager namespace
# (see manifests/01-management/dns01-solvers/)
```

`config/edge-nodes.env`: same as on-prem, one entry per edge VM. Edges
don't need to be in AWS — they reach the mgmt cluster via the LB hostname
over public DNS + :443. Most often they're on-prem at the clinic site.

## Step 5 — Run install.sh

```bash
./install.sh -y
```

What happens per step:

| Step | OpenStack behavior | AWS behavior |
|---|---|---|
| 01  | Installs k0s on the mgmt VM | **Skipped** (`INSTALL_MODE=existing`) |
| 01b | Installs OCCM helm chart | **Skipped** (EKS has CCM built in) |
| 02  | cert-manager + k0smotron | Same |
| 02b | Bootstrap self-signed CA | Same — or skip if `CERT_ISSUER=letsencrypt-prod` |
| 02c | nginx-ingress as `Service type=LoadBalancer` | EKS provisions an AWS **NLB**, attaches your Elastic IP |
| 03–04 | SeaweedFS + XNAT upload | Same |
| 05–07c | Edge clusters, workers, ingest, Orthanc | Same — edges reach mgmt via NLB:443 |

## Step 6 — Verify

```bash
# Wait for the NLB to be ready (usually ~2 min on AWS)
kubectl -n ingress-nginx get svc ingress-nginx-controller
# EXTERNAL-IP should be your Elastic IP

# DNS resolves to the EIP
getent hosts loki.aisedge.example.com

# TLS handshake
curl -v https://loki.aisedge.example.com/ready
# Expect 200 + valid Let's Encrypt cert
```

Then run a drop test the same way as OpenStack (parent
`docs/cloud-deployment.md`).

## Cost ballpark (Sydney region, 2026)

| Item | Approx monthly |
|---|---|
| EKS control plane | ~$73 |
| 2 × t3.large worker | ~$120 |
| 1 × Elastic IP (allocated, attached) | $0 |
| Network LB | ~$22 |
| 100 GB EBS gp3 | ~$10 |
| **Total** | **~$225/mo** |

(Excludes DICOM volume — egress to your XNAT target adds up if you're
shipping millions of instances.)

## Things you'll need to change if you self-host on EC2 (not EKS)

The default codebase assumes managed-K8s (EKS). If you go bare EC2:

1. Set `CLOUD_PROVIDER=aws_self_managed` (you'll need to add this branch
   to `install.sh` and to `01b-install-cloud-controller.sh`).
2. Install `cloud-provider-aws` via helm in step 01b instead of skipping.
3. Set `--cloud-provider=external` on kubelet so nodes get a `providerID`.

This is ~30 lines of code, isolated to two files (the case statements in
`install.sh` and `01b`). The pattern was designed to make this a
single-commit addition.

## Common gotchas

- **NLB target groups**: AWS NLB by default uses IP-mode targets — the
  ingress-nginx chart's `aws-load-balancer-type: "nlb"` annotation already
  handles this, no extra config.
- **Service type=LoadBalancer and the Elastic IP**: the AWS LB controller
  matches your pre-allocated EIP if the `loadbalancerIP` field is set in
  the Service spec. Some AWS LB controller versions require an annotation
  instead — check `kubectl describe svc ingress-nginx-controller` if the
  LB doesn't pick up your EIP.
- **Route 53 + cert-manager DNS-01**: needs an IAM role with
  `route53:GetChange` + `route53:ChangeResourceRecordSets`. Use IRSA
  (IAM Roles for Service Accounts) — annotate the cert-manager
  ServiceAccount with the role ARN.
