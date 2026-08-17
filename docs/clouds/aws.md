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
# Edit sites/<site>/values.yaml — it is YAML read by install.sh AND passed to
# both Helm releases, not a shell file:
#   topology: cloud
#   installMode: existing
#   domain: {internal: <your zone or nip.io>, mgmtNodeIP: "<the EIP>"}
#   ingress-nginx.controller.service: {type: LoadBalancer, loadBalancerIP: "<the EIP>"}
./install.sh -y <site>          # the site name is a required argument
```

That's it. There is no cloud-controller-manager *step* to skip: `install.sh`
has seven steps and none of them install a CCM anywhere, on any cloud — EKS
ships one already, and on self-managed k0s the OCCM is installed out of band
before the install (`docs/cloud-deployment.md`). What actually keeps the
installer's hands off your EKS cluster is `installMode: existing`, which makes
step 1/7 *verify* the cluster you already have (`kubectl get nodes`, plus a
warning if there is no default StorageClass) instead of installing k0s on it.
The rest of the install runs unchanged.

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

**Dev** (no DNS to register) — this is `domain.internal` in
`sites/<site>/values.yaml`, not an environment variable:
```yaml
domain:
  internal: dev.<eip-with-dashes>.nip.io   # e.g. dev.13-x-y-z.nip.io
```

CAUTION: nip.io and Let's Encrypt are mutually exclusive. You do not own the
nip.io zone, so you cannot write the DNS-01 TXT record it would ask for — which
is why the chart's default issuer is the internal CA rather than ACME with a
fallback. The dev branch here must keep `certManager.issuer: ais-edge-ca` and
skip the ACME block in Step 4. Nothing detects the combination for you: the
render only fails if a `letsencrypt-*` issuer is set with an empty
`dns01Solver`, so a solver that is present but unable to answer for your domain
leaves every Certificate `Pending` and nginx serving its own default cert.

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

`sites/<site>/values.yaml` is **YAML**, not a shell file of `export`s. It is the
one source of truth: `install.sh` reads it with `yaml.safe_load` *and* hands the
same file to both Helm releases, so each fact is stated once. There is no
`CLOUD_PROVIDER`, `CLOUD_CREDENTIALS_FILE`, `LB_PUBLIC_IP` or `DNS_PROVIDER`
anywhere in the codebase — the AWS SDK chain finds `~/.aws/credentials` on its
own, and cert-manager gets its credentials from a Secret you create by hand.

```yaml
# sites/<site>/values.yaml
topology: cloud
installMode: existing          # EKS already exists; do not install k0s here

domain:
  internal: aisedge.example.com    # or dev.<eip-with-dashes>.nip.io for dev
  mgmtNodeIP: "<your Elastic IP>"  # required — the address edges reach mgmt on

certManager:
  issuer: letsencrypt-prod     # AWS + real DNS = real LE certs
  acme:
    email: ops@example.com     # required for any letsencrypt-* issuer
    server: https://acme-v02.api.letsencrypt.org/directory
    # Passed through verbatim into the ClusterIssuer's solvers[0].dns01.
    # DNS-01 only: the ingress runs ssl-passthrough for the k0s API and
    # konnectivity, so HTTP-01 has nothing to terminate at. An empty solver
    # is a render-time failure, not a Pending certificate you have to debug.
    dns01Solver:
      route53:
        region: ap-southeast-2
        accessKeyIDSecretRef:     {name: route53-credentials, key: access-key-id}
        secretAccessKeySecretRef: {name: route53-credentials, key: secret-access-key}

# Cloud override for the ingress. The chart defaults to hostNetwork on the
# node's :443 because on-prem has no cloud controller; on EKS you want the NLB.
ingress-nginx:
  controller:
    hostNetwork: false
    dnsPolicy: ClusterFirst
    service:
      type: LoadBalancer
      loadBalancerIP: "<your Elastic IP>"
```

The `route53-credentials` Secret is created **by hand, before the install**, in
`certManager.clusterResourceNamespace` (default `cert-manager`) — cert-manager
resolves a ClusterIssuer's secret refs only from that one namespace. There is no
`manifests/01-management/dns01-solvers/` directory; `manifests/` holds a single
file, `01-management/edge-cluster.yaml.tpl`. Getting the Secret wrong does not
error: the Certificates simply stay `Pending` and nginx serves its own
self-signed default, which reads as a browser warning rather than a
misconfiguration. If you want to rehearse the plumbing, set
`certManager.issuer: letsencrypt-staging` **and** point `acme.server` at the
staging directory — the chart fails the render if you leave the production URL
in place, because staging exists to test without spending the real rate limit.

The `edges:` list in `sites/<site>/values.yaml`: same as on-prem, one entry per edge VM. Edges
don't need to be in AWS — they reach the mgmt cluster via the LB hostname
over public DNS + :443. Most often they're on-prem at the clinic site.

## Step 5 — Run install.sh

```bash
./install.sh -y <site>
```

The installer has **seven** steps, not the old `01/01b/02/02b/02c/03/04/…`
numbering: steps 4 and 7 are Helm releases that replaced what used to be
scripts `02b/02c/02d/03/04/07/07b/07c` (see the header of `install.sh`). What
happens per step:

| Step | OpenStack behavior | AWS behavior |
|---|---|---|
| 1/7 k0s management cluster | Installs k0s + kubectl/helm/local-path on the mgmt VM | **Skipped** — `installMode: existing` makes `scripts/01-install-k0s.sh` run `kubectl get nodes -o wide`, warn if there is no default StorageClass, and exit 0 |
| 2/7 prerequisites | cert-manager v1.20.3 CRDs + k0smotron v2.0.3 operator, both pinned in `install.sh` | Same. These are prerequisites rather than subcharts because Helm validates a release against the API server before applying any of it, so the CRDs must exist first |
| 3/7 site Secrets | SOPS-decrypts `sites/<site>/secrets.enc.yaml` straight into the cluster, never to disk | Same |
| 4/7 helm: management chart | One release: SeaweedFS, the XNAT uploader, observability, the CA/ClusterIssuers, ingress-nginx and the k0smotron hosted control planes | Same release; the ingress override in the site file makes EKS provision an AWS **NLB** and attach your Elastic IP instead of binding the node's `:443` |
| 5/7 per edge: child kubeconfig + join token | Mints the token once and reuses it, so an upgrade does not re-mint | Same |
| 6/7 per edge: join the worker | Over SSH, or a bootstrap bundle when there is no SSH to that edge | Same — edges reach mgmt via NLB:443 |
| 7/7 per edge: helm: edge chart | Orthanc, de-identification, the pipeline, the S3 uploader and Vector | Same |

## Step 6 — Verify

```bash
# Wait for the NLB to be ready (usually ~2 min on AWS).
# ingress-nginx is a SUBCHART of the mgmt release, so the Service is
# <release>-ingress-nginx-controller in the release namespace — with the
# installer's defaults (MGMT_RELEASE=mgmt, MGMT_NS=ais-mgmt) that is:
kubectl -n ais-mgmt get svc mgmt-ingress-nginx-controller
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

The default codebase assumes managed-K8s (EKS). Self-hosting on EC2 is an
**operator procedure, not a code change**: there is no `CLOUD_PROVIDER`
variable, no provider `case` statement and no
`scripts/01b-install-cloud-controller.sh` — `install.sh` contains no
cloud-controller logic at all, on any cloud. The same is true on OpenStack,
where the OCCM is installed out of band before the install
(`docs/cloud-deployment.md`). So:

1. Build the k0s cluster yourself on the EC2 nodes, with
   `--cloud-provider=external` on the kubelets so each node gets a
   `providerID`. Without it the AWS CCM ignores the node and no
   `Service type=LoadBalancer` is ever satisfied.
2. Install `cloud-provider-aws` yourself (its own Helm chart, with an IAM
   role for the controller) **before** running `./install.sh <site>`, exactly
   as the OpenStack path installs the OCCM plus its `cloud.conf` Secret out
   of band.
3. Then run the install with `installMode: existing` and `topology: cloud` in
   `sites/<site>/values.yaml`, so step 1/7 verifies your cluster instead of
   trying to build one.

Doing it this way is deliberate. A provider `case` statement inside the
installer would be a second source of truth about the cluster — one the charts
cannot see — and every mismatch between it and the site file failed silently
in the previous design. Anything the installer cannot verify from
`sites/<site>/values.yaml` alone belongs outside the installer.

## Common gotchas

- **NLB target groups**: this chart sets **no** `service.beta.kubernetes.io/aws-load-balancer-*`
  annotations. `charts/mgmt/values.yaml` ships the ingress-nginx controller
  Service as `type: ClusterIP` with `hostNetwork: true`, because on-prem has no
  cloud controller to satisfy a LoadBalancer and the chart must not leave :443
  unbound. On AWS you therefore supply the whole cloud shape yourself in
  `sites/<site>/values.yaml` (see Step 4) — `type: LoadBalancer`,
  `hostNetwork: false`, `dnsPolicy: ClusterFirst` — plus any
  `aws-load-balancer-type: "nlb"` / target-mode annotations your AWS
  load-balancer controller needs, under
  `ingress-nginx.controller.service.annotations`. Nothing is "already handled".
- **Service type=LoadBalancer and the Elastic IP**: the AWS LB controller
  matches your pre-allocated EIP if the `loadBalancerIP` field is set in
  the Service spec (`ingress-nginx.controller.service.loadBalancerIP` in the
  site file). Some AWS LB controller versions require an annotation
  instead — check
  `kubectl -n ais-mgmt describe svc mgmt-ingress-nginx-controller` if the
  LB doesn't pick up your EIP.
- **Route 53 + cert-manager DNS-01**: needs an IAM role with
  `route53:GetChange` + `route53:ChangeResourceRecordSets`. Use IRSA
  (IAM Roles for Service Accounts) — annotate the cert-manager
  ServiceAccount with the role ARN.
