# GCP install (GKE)

> Status: **untested, design complete**. Same shape as AWS — GKE bundles
> its own cloud-controller-manager, so the k0s-install step (1/7) auto-skips
> on `installMode: existing` and the rest of the install runs unchanged.
> There is no cloud-provider switch to set: the installer reads
> `sites/<site>/values.yaml` and the only cloud-specific config is the
> ingress-nginx Service override in Step 4.

## TL;DR

```bash
gcloud container clusters create ais-edge-mgmt \
  --region=australia-southeast1 \
  --num-nodes=2 \
  --machine-type=e2-standard-2 \
  --release-channel=stable
gcloud compute addresses create ais-edge-lb \
  --region=australia-southeast1   # reserves a static regional IP
# Edit sites/<site>/values.yaml (topology: cloud, installMode: existing, etc.)
./install.sh -y <site>          # <site> is a directory under sites/ — required
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

This is the address you pin in Step 4 as
`ingress-nginx.controller.service.loadBalancerIP`; the K8s Service of type
LoadBalancer attaches it to the auto-provisioned GCP network LB. (Do **not**
use the top-level `ingressNginx.loadBalancerIP` key you will see in
`charts/mgmt/values.yaml:555` — no template reads it, so setting it there is
silently inert.)

## Step 3 — DNS

**Dev** (no DNS to register) — set this as `domain.internal` in Step 4:
```yaml
domain:
  internal: dev.<ip-with-dashes>.nip.io
```
Note that nip.io cannot satisfy a DNS-01 challenge, so a nip.io domain means
staying on the internal `ais-edge-ca` issuer rather than Let's Encrypt
(`charts/mgmt/values.yaml:366-370`).

**Prod** (Cloud DNS):
```bash
gcloud dns managed-zones create aisedge \
  --dns-name=aisedge.example.com. \
  --description="AIS Edge prod"
# Add A records pointing *.aisedge.example.com → 34.x.y.z
```

## Step 4 — Config

`sites/<site>/values.yaml` is **YAML**, not a shell env file — `install.sh`
parses it with `yaml.safe_load` (`install.sh:95-113`) and reads dotted paths
out of it. Shell `export` lines here are not config; they are a parse error.
The same file is passed to both charts, so what you write below is also what
`helm` sees.

```yaml
topology: cloud            # install.sh:133 — skips the on-prem /etc/hosts writes
installMode: existing      # install.sh:134 — GKE already runs; do not install k0s

domain:
  internal: aisedge.example.com     # or dev.<ip-with-dashes>.nip.io for dev
  mgmtNodeIP: "10.x.y.z"            # required (install.sh:130, no default) —
                                    # a node IP inside the GKE cluster

certManager:
  enabled: false                    # leave false: install.sh step 2/7 installs
                                    # cert-manager itself, before this chart
  issuer: letsencrypt-prod          # anything prefixed letsencrypt- takes the
                                    # ACME path (cert-issuers.yaml:80)
  acme:
    email: ops@example.com          # omitted from the ClusterIssuer if empty
    server: https://acme-v02.api.letsencrypt.org/directory
    dns01Solver:                    # passed through VERBATIM into
      cloudDNS:                     # solvers[0].dns01 (cert-issuers.yaml:291),
        project: <your-project>     # so it must be a shape cert-manager knows.
                                    # No serviceAccountSecretRef: Workload
                                    # Identity supplies the token (see below).

# The chart ships the ON-PREM ingress shape and expects cloud sites to override
# it here — see the CAUTION at charts/mgmt/values.yaml:511-522. All three lines
# matter: the default binds the host's :443 with hostNetwork and a ClusterIP
# Service, so on GKE no LB is ever provisioned and loadBalancerIP alone is inert.
ingress-nginx:                      # subchart key — hyphenated, exactly this
  controller:
    hostNetwork: false
    dnsPolicy: ClusterFirst         # ClusterFirstWithHostNet only makes sense
                                    # with hostNetwork: true
    service:
      type: LoadBalancer
      loadBalancerIP: "34.x.y.z"    # the static IP reserved in Step 2
```

There is no cloud-provider or credentials key to set. GCP credentials come from
the ambient ADC / Workload Identity chain, and the DNS provider is expressed
solely by which key appears inside `dns01Solver`. For a working solver block in
this repo, see the route53 example at `scripts/ci/values.sh:166-175` — same
shape, different provider key.

## Step 5 — Run install.sh

```bash
./install.sh -y <site>
```

`install.sh` is a **seven-step** installer and prints `1/7` … `7/7` as it goes.
The old per-script numbering (`01b`, `02c`, `02d`, `07c`) is gone: steps 4 and 7
are Helm installs that replaced what used to be scripts 02b/02c/02d/03/04/07/
07b/07c (`install.sh:35`).

| Step | What happens on GCP |
|---|---|
| 1/7 k0s management cluster | Skipped — `installMode: existing`; `scripts/01-install-k0s.sh:8` just verifies the GKE cluster answers and warns if there is no default StorageClass, then exits 0 |
| 2/7 prerequisites: cert-manager CRDs + k0smotron operator | Standard. cert-manager is installed here rather than as a subchart, to break the conversion-webhook ordering loop |
| 3/7 site Secrets (SOPS → cluster) | Standard; skipped if the site has no `secrets.enc.yaml` |
| 4/7 helm: management chart | Installs the ingress-nginx subchart. With the Step 4 override above, GKE provisions a regional Network LB and attaches your reserved static IP |
| 5/7 per edge: child kubeconfig + join token | Standard |
| 6/7 per edge: join the k0s worker over SSH (or build a bootstrap bundle for `join: bundle` edges) | Standard |
| 7/7 per edge: helm: edge chart | Standard; edges hit the LB hostname over public DNS + 443 |

## Step 6 — Verify

```bash
kubectl -n ais-mgmt get svc mgmt-ingress-nginx-controller
# release `mgmt` in namespace `ais-mgmt` — there is no ingress-nginx namespace.
# EXTERNAL-IP should equal your reserved static IP. It stays <none> unless the
# ingress-nginx override from Step 4 is in the site file: the chart default is
# service.type ClusterIP (charts/mgmt/values.yaml:536).

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
