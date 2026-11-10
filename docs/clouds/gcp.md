# GCP install (GKE)

**Review status, 2026-11-10:** the cloud topology is implemented in the current
charts and installer. The provider provisioning commands below are retained
from the earlier design; a complete deployment with these exact commands and
current provider defaults is **not verified (2026-11-10)**. Do not read a
historical commissioning result as certification of this recipe. Start from
`sites/example-cloud/values.yaml`, supply the complete site Secrets and edge
configuration, and use [cloud-deployment.md](../cloud-deployment.md) for the
repository's current interface. The short snippets below are overrides, not
complete installable site files.

> Historical GKE design, date not recorded. The cloud chart path exists;
> a full GKE run is not verified (2026-11-10). `installMode: existing`
> verifies a cluster rather than installing k0s, but it does not supply the
> provider identity, storage, quota or workload compatibility decisions.

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

## Which ingress shape, and what the pre-flight checks

GKE supports LoadBalancer Services. Choose a TCP passthrough service and
verify its assigned address, target health and access controls. Provider
support does not validate the complete site or guarantee immediate readiness.

```yaml
ingress-nginx:
  controller:
    hostNetwork: false
    dnsPolicy: ClusterFirst
    service:
      type: LoadBalancer
      loadBalancerIP: "<your static regional IP>"
```

If you would rather front the cluster with a balancer you build and manage
yourself, `NodePort` is also supported when you manage the balancer. Set it explicitly:
the chart requires a cloud ingress override, and its inherited on-prem
ClusterIP/hostNetwork values are not a working NodePort default:

```yaml
    service:
      type: NodePort
      nodePorts:            # pin ports used by your externally managed pool
        http: 30080         # a recreated Service can otherwise receive new ports
        https: 30443
```

The cloud preflight runs **after prerequisite installation**, before site
Secrets and the management release. It is not an all-or-nothing dry run:

* On the **NodePort** path it resolves the first address for `domain.internal`
  and compares it with `domain.mgmtNodeIP`. It does not probe every service
  hostname, listener, backend or certificate.
* On the **LoadBalancer** path it counts pod names containing
  `cloud-controller-manager`, then checks the uninitialized node taint. It
  does not check those pods' readiness, and it does not run the NodePort DNS
  checks. Managed control planes or a separately named AWS Load Balancer
  Controller may work while failing this heuristic.

`SKIP_CLOUD_PREFLIGHT=1` skips these checks only. Use it only after independently
verifying DNS, controller behavior, TCP forwarding and node readiness. It does
not waive chart validation or establish that the provider setup is correct.

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

Historical duration: ~5-7 minutes; not verified (2026-11-10). Workload
Identity configures pod access to Google APIs, but its node-pool and
ServiceAccount requirements still need verification. For a regional cluster,
check the total node count across zones; `--num-nodes=2` is not a two-node
capacity or cost guarantee for the whole region.

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
look for a top-level `ingressNginx.loadBalancerIP` key — it used to exist,
was read by no template, and has been removed rather than wired. The address
belongs under the subchart key; Helm passes those values to the dependency.
Unrelated parent policy keys are not automatically translated.)
GKE supports `spec.loadBalancerIP` for IPv4 and also a version-dependent
resource-name annotation. Verify regional and network-tier constraints in the
[provider Service parameter reference](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/service-load-balancer-parameters).

## Step 3 — DNS

**Dev** (no DNS to register) — set this as `domain.internal` in Step 4:
```yaml
domain:
  internal: dev.<ip-with-dashes>.nip.io
```
Note that nip.io cannot satisfy a DNS-01 challenge, so a nip.io domain means
staying on the internal `ais-edge-ca` issuer rather than Let's Encrypt
(`charts/mgmt/values.yaml`).

**Prod** (Cloud DNS):
```bash
gcloud dns managed-zones create aisedge \
  --dns-name=aisedge.example.com. \
  --description="AIS Edge prod"
# Add A records pointing *.aisedge.example.com → 34.x.y.z
```

## Step 4 — Config

Use the management node address for `domain.mgmtNodeIP`, not the public
load-balancer address. Public service names belong under `domain.internal`
and must resolve through the selected LB. Also override the four explicit
`local-path` observability StorageClass settings for a managed cluster if that
class does not exist there: Prometheus and Alertmanager `storageSpec`, Grafana
`persistence.storageClassName`, and Loki `singleBinary.persistence.storageClass`.
A default cloud StorageClass does not override an explicit `local-path` name.

`sites/<site>/values.yaml` is **YAML**, not a shell env file — `install.sh`
parses it with `yaml.safe_load` (`install.sh`) and reads dotted paths
out of it. Shell `export` lines here are not config; they are a parse error.
The same file is passed to both charts, so what you write below is also what
`helm` sees.

```yaml
topology: cloud            # install.sh ; skips the on-prem /etc/hosts writes
installMode: existing      # install.sh ; GKE already runs; do not install k0s

domain:
  internal: aisedge.example.com     # or dev.<ip-with-dashes>.nip.io for dev
  mgmtNodeIP: "10.x.y.z"            # required (install.sh, no default) ;
                                    # a node IP inside the GKE cluster

certManager:
  enabled: false                    # leave false: install.sh step 2/7 installs
                                    # cert-manager itself, before this chart
  issuer: letsencrypt-prod          # anything prefixed letsencrypt- takes the
                                    # ACME path (charts/mgmt/templates/cert-issuers.yaml)
  acme:
    email: ops@example.com          # required by this chart for ACME
    server: https://acme-v02.api.letsencrypt.org/directory
    dns01Solver:                    # passed through VERBATIM into
      cloudDNS:                     # solvers[0].dns01 (charts/mgmt/templates/cert-issuers.yaml),
        project: <your-project>     # so it must be a shape cert-manager knows.
                                    # No serviceAccountSecretRef: Workload
                                    # Identity supplies the token (see below).

# The chart ships the ON-PREM ingress shape and expects cloud sites to override
# it here; consult the CAUTION at charts/mgmt/values.yaml. All three lines
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
this repo, see the route53 example at `scripts/ci/values.sh`; it uses the same
shape, different provider key.

## Step 5 — Run install.sh

```bash
./install.sh -y <site>
```

`install.sh` is a **seven-step** installer and prints `1/7` … `7/7` as it goes.
The old per-script numbering (`01b`, `02c`, `02d`, `07c`) is gone: steps 4 and 7
are Helm installs that replaced what used to be scripts 02b/02c/02d/03/04/07/
07b/07c (`install.sh`).

| Step | What happens on GCP |
|---|---|
| 1/7 k0s management cluster | Skipped ; `installMode: existing`; `scripts/01-install-k0s.sh` just verifies the GKE cluster answers and warns if there is no default StorageClass, then exits 0 |
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
# service.type ClusterIP (charts/mgmt/values.yaml).

curl -v --cert <edge-loki-client.crt> --key <edge-loki-client.key> \
  https://loki.aisedge.example.com/ready
# Expect 200 with an admitted client certificate and valid server trust.
# With the internal issuer, also pass --cacert <ais-edge-ca.crt>.
```

## Cost ballpark (Sydney region, 2026)

**Historical estimates, 2026; calculation date not recorded.** Every amount
and the total in this table is **not verified (2026-11-10)** and must not be
used as a current quote. Recalculate the selected cluster mode, region,
instance count, public addresses, storage, backups and network transfer with
the provider before provisioning. No prices in the table are deployment gates.

| Item | Approx monthly |
|---|---|
| GKE Autopilot cluster fee | $0 (waived) |
| 2 × e2-standard-2 nodes | ~$110 |
| 1 × regional Network LB | ~$22 |
| 100 GB pd-standard PD | ~$4 |
| Static IP (used) | $0 (free when attached) |
| **Total** | **~$140/mo** |

The creation command above uses GKE Standard, so the table's Autopilot row
was inconsistent even as an estimate. Cluster fees, node counts and public IP
charges need recalculation for the chosen mode; relative price is unverified.

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

With Workload Identity configured correctly, cert-manager can obtain a
short-lived token without a static service-account key file. This is not a
claim that the entire deployment has no secret files. Verify DNS challenge
permissions and token acquisition before relying on automatic renewal.

## Common gotchas

- **GKE Autopilot vs Standard**: this management chart includes Vector hostPath
  reads and a writable host checkpoint directory, plus storage defaults that
  require review. Do not assume Autopilot compatibility because ingress and
  cert-manager are pod workloads. The example cluster command uses Standard;
  Autopilot support is not verified (2026-11-10).

- **Regional vs zonal LBs**: GCP regional Network LBs default to TCP/UDP
  pass-through, which is what we want for SNI passthrough at ingress-nginx.
- **Pricing surprises**: Cloud Storage egress out of GCP to non-GCP XNAT
  targets can be material. Its share of the bill depends on traffic volume,
region and network path; the largest cost driver is not verified (2026-11-10).
