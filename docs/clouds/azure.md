# Azure install (AKS)

**Review status, 2026-11-10:** the cloud topology is implemented in the current
charts and installer. The provider provisioning commands below are retained
from the earlier design; a complete deployment with these exact commands and
current provider defaults is **not verified (2026-11-10)**. Do not read a
historical commissioning result as certification of this recipe. Start from
`sites/example-cloud/values.yaml`, supply the complete site Secrets and edge
configuration, and use [cloud-deployment.md](../cloud-deployment.md) for the
repository's current interface. The short snippets below are overrides, not
complete installable site files.

> Historical AKS design, date not recorded. Cloud topology is implemented
> in the current chart. A complete AKS deployment with this guide is not
> verified (2026-11-10); the provider identity and storage setup remain site work.

## TL;DR

```bash
az group create --name ais-edge-rg --location australiaeast
az aks create --resource-group ais-edge-rg --name ais-edge-mgmt \
  --node-count 2 --node-vm-size Standard_D2s_v3 \
  --enable-managed-identity --generate-ssh-keys
az network public-ip create --resource-group ais-edge-rg \
  --name ais-edge-lb-ip --sku Standard --allocation-method Static
# Edit sites/<site>/values.yaml (topology: cloud, installMode: existing, etc.)
./install.sh -y <site>          # the site argument is mandatory (install.sh)
```

## Which ingress shape, and what the pre-flight checks

AKS supports LoadBalancer Services. Verify the cluster identity, selected IP
resource, network policy and Service events; provider support alone does not
prove that this site configuration can allocate its ingress.

```yaml
ingress-nginx:
  controller:
    hostNetwork: false
    dnsPolicy: ClusterFirst
    service:
      type: LoadBalancer
      annotations:
        service.beta.kubernetes.io/azure-pip-name: ais-edge-lb-ip
        service.beta.kubernetes.io/azure-load-balancer-resource-group: ais-edge-rg
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

1. Azure subscription + a resource group:
   ```bash
   az group create --name ais-edge-rg --location australiaeast
   ```
2. `az` CLI authenticated:
   ```bash
   az login
   az account set --subscription <your-subscription>
   ```
3. `kubectl`, `helm` v3.

## Step 1 — Create the AKS cluster

```bash
az aks create \
  --resource-group ais-edge-rg \
  --name ais-edge-mgmt \
  --node-count 2 \
  --node-vm-size Standard_D2s_v3 \
  --enable-managed-identity \
  --generate-ssh-keys
```

Historical duration: ~7-10 minutes; not verified (2026-11-10). Wait for
cluster and node readiness rather than using that estimate as a timeout.

```bash
az aks get-credentials --resource-group ais-edge-rg --name ais-edge-mgmt
kubectl get nodes
```

## Step 2 — Reserve a static public IP

```bash
az network public-ip create \
  --resource-group ais-edge-rg \
  --name ais-edge-lb-ip \
  --sku Standard \
  --allocation-method Static

az network public-ip show \
  --resource-group ais-edge-rg --name ais-edge-lb-ip \
  --query ipAddress -o tsv
# Returns 20.x.y.z
```

The IP may be in the node resource group or another group accessible to the
AKS control-plane identity. The latter needs explicit permissions and the
resource-group annotation. Find the node resource group with:
```bash
az aks show --resource-group ais-edge-rg --name ais-edge-mgmt \
  --query nodeResourceGroup -o tsv
# Returns something like MC_ais-edge-rg_ais-edge-mgmt_australiaeast
```
Either create the public IP there directly, or grant AKS's managed
identity `Network Contributor` on the IP's RG:
```bash
PRINCIPAL_ID=$(az aks show --resource-group ais-edge-rg --name ais-edge-mgmt \
  --query identity.principalId -o tsv)
az role assignment create --assignee $PRINCIPAL_ID \
  --role "Network Contributor" \
  --scope $(az network public-ip show -g ais-edge-rg -n ais-edge-lb-ip --query id -o tsv)
```

## Step 3 — DNS

**Dev**: `domain.internal: dev.<ip-with-dashes>.nip.io` in the site file.
`nip.io` cannot satisfy an ACME DNS-01 challenge, so dev stays on the default
internal CA (`certManager.issuer: ais-edge-ca`).

**Prod** (Azure DNS):
```bash
az network dns zone create --resource-group ais-edge-rg --name aisedge.example.com
az network dns record-set a add-record \
  --resource-group ais-edge-rg --zone-name aisedge.example.com \
  --record-set-name "*" --ipv4-address 20.x.y.z
```

## Step 4 — Config

Use the management node address for `domain.mgmtNodeIP`, not the public
load-balancer address. Public service names belong under `domain.internal`
and must resolve through the selected LB. Also override the four explicit
`local-path` observability StorageClass settings for a managed cluster if that
class does not exist there: Prometheus and Alertmanager `storageSpec`, Grafana
`persistence.storageClassName`, and Loki `singleBinary.persistence.storageClass`.
A default cloud StorageClass does not override an explicit `local-path` name.

`sites/<site>/values.yaml` is **YAML**, read with `yaml.safe_load`
(`install.sh`) and then handed to Helm with `-f`. Nothing sources it,
so shell `export` lines in it are invalid YAML configuration ; and `CLOUD_PROVIDER`,
`CLOUD_CREDENTIALS_FILE`, `LB_PUBLIC_IP`, `CERT_ISSUER` and `DNS_PROVIDER`
have no reader anywhere in `charts/`, `scripts/`, `sites/` or `install.sh`.
The live keys are:

```yaml
installMode: existing        # we're using AKS; install.sh
topology: cloud              # charts/mgmt/values.yaml; choices: onprem | cloud

domain:
  internal: aisedge.example.com
  mgmtNodeIP: "<management node IP>"  # not the public LB address

certManager:
  issuer: letsencrypt-prod   # default is ais-edge-ca, the internal CA
  acme:
    email: ops@example.com   # both acme keys are REQUIRED with letsencrypt-*
    dns01Solver:             # passed through verbatim; Azure DNS shape below
      azureDNS:
        hostedZoneName: aisedge.example.com
        resourceGroupName: ais-edge-rg
        subscriptionID: <your-subscription>
        environment: AzurePublicCloud
```

`certManager.acme.email` and `certManager.acme.dns01Solver` are not optional
on a `letsencrypt-*` issuer: `charts/mgmt/templates/cert-issuers.yaml` fails the
render without them, deliberately, so a missing solver surfaces at
`helm template` rather than as Certificates that sit Pending forever.

Pin the LB to your reserved IP in the same file. It is layered onto the
management chart with `-f`, so a top-level `ingress-nginx:` key overrides the
vendored subchart's defaults at `charts/mgmt/values.yaml`, whose settings are
the on-prem ones, `hostNetwork: true` + `service.type: ClusterIP`. Left
untouched on AKS, the reserved 20.x.y.z never attaches and Step 6 can never
pass:

```yaml
ingress-nginx:
  controller:
    hostNetwork: false        # AKS has a cloud controller; no need to own the node's :443
    dnsPolicy: ClusterFirst   # ClusterFirstWithHostNet only makes sense with hostNetwork
    service:
      type: LoadBalancer
      annotations:
        service.beta.kubernetes.io/azure-pip-name: ais-edge-lb-ip
        # only needed when the public IP is NOT in the AKS node resource group (see Step 2)
        service.beta.kubernetes.io/azure-load-balancer-resource-group: ais-edge-rg
```

Two traps in that block:
- Use `ingress-nginx.controller.service.annotations` with `azure-pip-name`
  and the resource group. Azure documents `spec.loadBalancerIP` as deprecated;
  see [static IP configuration](https://learn.microsoft.com/en-us/azure/aks/static-ip).
  A top-level `ingressNginx.loadBalancerIP` used to sit in the chart defaults
  and was read by nothing; it has been removed rather than left looking like
  the obvious place.
- Override only the keys above. The inherited
  `controller.extraArgs.enable-ssl-passthrough: "true"` and
  `ingressNginx.sslPassthrough: true` must stay:
  `charts/mgmt/templates/edge-clusters.yaml` hard-fails the render if
  passthrough is turned off, because the k0s API and konnectivity are mTLS end
  to end and terminating here breaks only the edge workers' join.

## Step 5 — Run install.sh

```bash
./install.sh -y <site>
```

`install.sh` is a seven-step installer now, not the old numbered-script chain.
`install.sh` records that steps 4 and 7 replaced
`02b/02c/02d/03/04/07/07b/07c`, and there is no `01b` to skip — the repo
installs no cloud controller in any topology, on AKS or anywhere else:

| Step | What happens on AKS |
|---|---|
| 1/7 k0s management cluster | Skipped (`installMode: existing` — AKS is already there) |
| 2/7 cert-manager CRDs + k0smotron operator | Standard; both are pinned |
| 3/7 site Secrets (SOPS → cluster) | Standard |
| 4/7 helm: management chart | SeaweedFS, uploader, observability, CA, ingress, hosted control planes. This is where the `ingress-nginx:` override lands and AKS provisions the Azure Standard LB against your static IP |
| 5/7 per edge: child kubeconfig + join token | Standard edge setup |
| 6/7 per edge: join the k0s worker over SSH | Standard edge setup |
| 7/7 per edge: helm: edge chart | Orthanc, de-id, pipeline, uploader, Vector |

## Step 6 — Verify

The ingress-nginx Service is part of the management release, so it carries the
release prefix and lives in the release namespace (`mgmt` / `ais-mgmt`,
`install.sh`) ; there is no `ingress-nginx` namespace:

```bash
kubectl -n ais-mgmt get svc mgmt-ingress-nginx-controller
# EXTERNAL-IP should equal 20.x.y.z

curl -v --cert <edge-loki-client.crt> --key <edge-loki-client.key> \
  https://loki.aisedge.example.com/ready
# Expect 200 with an admitted client certificate and valid server trust.
# With the internal issuer, also pass --cacert <ais-edge-ca.crt>.
```

## Workload Identity for cert-manager DNS-01

Azure equivalent of AWS IRSA / GCP Workload Identity:

The commands below were an incomplete historical outline. Before using them,
enable OIDC and workload identity on the AKS cluster; label the cert-manager
controller pod `azure.workload.identity/use: "true"`; bind the federated
ServiceAccount and identity; configure the solver identity; and confirm token
injection after rollout. A ServiceAccount annotation alone is insufficient.
Manage these settings in the prerequisite cert-manager release so later
installer runs do not discard them. See [cert-manager AzureDNS setup](https://cert-manager.io/docs/configuration/acme/dns01/azuredns/).

```bash
# 1. Create a managed identity
az identity create --resource-group ais-edge-rg --name cert-manager-dns01
CLIENT_ID=$(az identity show -g ais-edge-rg -n cert-manager-dns01 --query clientId -o tsv)

# 2. Grant DNS Zone Contributor on the zone
az role assignment create \
  --assignee $CLIENT_ID \
  --role "DNS Zone Contributor" \
  --scope $(az network dns zone show -g ais-edge-rg -n aisedge.example.com --query id -o tsv)

# 3. Enable federation first, then obtain its issuer and bind the k8s SA
az aks update -g ais-edge-rg -n ais-edge-mgmt \
  --enable-oidc-issuer --enable-workload-identity
OIDC_ISSUER=$(az aks show -g ais-edge-rg -n ais-edge-mgmt \
  --query oidcIssuerProfile.issuerUrl -o tsv)
az identity federated-credential create \
  --name cert-manager-fed \
  --identity-name cert-manager-dns01 \
  --resource-group ais-edge-rg \
  --issuer $OIDC_ISSUER \
  --subject "system:serviceaccount:cert-manager:cert-manager"

# 4. Annotate the SA
kubectl annotate sa -n cert-manager cert-manager \
  azure.workload.identity/client-id=$CLIENT_ID
```

## Cost ballpark (Sydney region, 2026)

**Historical estimates, 2026; calculation date not recorded.** Every amount
and the total in this table is **not verified (2026-11-10)** and must not be
used as a current quote. Recalculate the selected cluster mode, region,
instance count, public addresses, storage, backups and network transfer with
the provider before provisioning. No prices in the table are deployment gates.

| Item | Approx monthly |
|---|---|
| AKS control plane | $0 (free tier) |
| 2 × D2s_v3 nodes | ~$140 |
| Standard LB | ~$22 + per-hour rule charges |
| Static public IP | ~$4 |
| 100 GB Premium SSD | ~$20 |
| **Total** | **~$190/mo** |

## Common gotchas

- **Resource group split**: Azure splits AKS into two RGs — the cluster
  RG (where the AKS resource lives) and the node RG (where VMs, NICs,
  LBs, etc. live). The static public IP must be reachable from the AKS
  managed identity's perspective; see Step 2.
- **Standard SKU**: use the supported Standard LB and matching IP resource.
  Basic Load Balancer is no longer supported by AKS; the old comparison is
  historical. Verify any upgrade requirements before importing existing resources.
- **NetworkSecurityGroup AKS-managed**: AKS auto-manages the NSG attached
  to the node subnet. It should auto-open the listener ports when you
  create a LoadBalancer Service. If it doesn't, `kubectl describe svc`
  for the controller will show events.
