# Azure install (AKS)

> Status: **untested, design complete, and written against the pre-Helm
> installer**. Same pattern as AWS/GCP — AKS bundles its own
> cloud-controller-manager, so there is nothing for you to install on that
> front. Note that this repo never installed one either: the numbered
> `scripts/01b-install-cloud-controller.sh` this guide was written around is
> gone, along with the rest of the imperative installer (`install.sh:35`).
> `topology: cloud` is a chart value but a parked one, so treat the commands
> below as a design record and expect to correct them as you go.

## TL;DR

```bash
az group create --name ais-edge-rg --location australiaeast
az aks create --resource-group ais-edge-rg --name ais-edge-mgmt \
  --node-count 2 --node-vm-size Standard_D2s_v3 \
  --enable-managed-identity --generate-ssh-keys
az network public-ip create --resource-group ais-edge-rg \
  --name ais-edge-lb-ip --sku Standard --allocation-method Static
# Edit sites/<site>/values.yaml (topology: cloud, installMode: existing, etc.)
./install.sh -y <site>          # the site argument is mandatory (install.sh:80)
```

## Which ingress shape, and what the pre-flight checks

AKS runs a cloud controller, so `type: LoadBalancer` works out of the box and is the right choice here.

```yaml
ingress-nginx:
  controller:
    hostNetwork: false
    dnsPolicy: ClusterFirst
    service:
      type: LoadBalancer
      loadBalancerIP: "<your static public IP>"
```

If you would rather front the cluster with a balancer you build and manage
yourself, `NodePort` is equally supported and is the DEFAULT for self-managed
clusters, which have no controller to answer a `LoadBalancer` request:

```yaml
    service:
      type: NodePort
      nodePorts:            # pin them, or Kubernetes picks fresh ports each
        http: 30080         # install and silently breaks your target group
        https: 30443
```

Before doing any work, `install.sh` checks on `topology: cloud`:

* **`domain.internal` resolves.** Edges resolve this name to find the
  management cluster; if there is no record yet there is no point installing.
* **it does not resolve to a node itself.** That works until the node is
  replaced, then every edge loses the cluster.
* **on the `LoadBalancer` path:** that a cloud controller is running and that
  no node still carries `node.cloudprovider.kubernetes.io/uninitialized`. On
  AKS this is satisfied out of the box; the check is there for the
  self-managed case and costs nothing here.

`SKIP_CLOUD_PREFLIGHT=1` overrides all of them.


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

Takes ~7-10 min.

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

**Important on AKS**: The static IP must be in the same resource group
as the AKS *node* resource group (NOT the cluster's RG). Find the node RG
with:
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

`sites/<site>/values.yaml` is **YAML**, read with `yaml.safe_load`
(`install.sh:95-113`) and then handed to Helm with `-f`. Nothing sources it,
so shell `export` lines in it are inert — and `CLOUD_PROVIDER`,
`CLOUD_CREDENTIALS_FILE`, `LB_PUBLIC_IP`, `CERT_ISSUER` and `DNS_PROVIDER`
have no reader anywhere in `charts/`, `scripts/`, `sites/` or `install.sh`.
The live keys are:

```yaml
installMode: existing        # we're using AKS; install.sh:134
topology: cloud              # charts/mgmt/values.yaml:32 — onprem | cloud

domain:
  internal: aisedge.example.com
  mgmtNodeIP: "20.x.y.z"     # the reserved static IP

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
on a `letsencrypt-*` issuer: `charts/mgmt/templates/_helpers.tpl` fails the
render without them, deliberately, so a missing solver surfaces at
`helm template` rather than as Certificates that sit Pending forever.

Pin the LB to your reserved IP in the same file. It is layered onto the
management chart with `-f`, so a top-level `ingress-nginx:` key overrides the
vendored subchart's defaults at `charts/mgmt/values.yaml:523-550` — which are
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
      loadBalancerIP: "20.x.y.z"
      annotations:
        # only needed when the public IP is NOT in the AKS node resource group (see Step 2)
        service.beta.kubernetes.io/azure-load-balancer-resource-group: ais-edge-rg
```

Two traps in that block:
- The LB address belongs under `ingress-nginx.controller.service.loadBalancerIP`.
  A top-level `ingressNginx.loadBalancerIP` used to sit in the chart defaults
  and was read by nothing; it has been removed rather than left looking like
  the obvious place.
- Override only the keys above. The inherited
  `controller.extraArgs.enable-ssl-passthrough: "true"` and
  `ingressNginx.sslPassthrough: true` must stay:
  `charts/mgmt/templates/edge-clusters.yaml:72-73` hard-fails the render if
  passthrough is turned off, because the k0s API and konnectivity are mTLS end
  to end and terminating here breaks only the edge workers' join.

## Step 5 — Run install.sh

```bash
./install.sh -y <site>
```

`install.sh` is a seven-step installer now, not the old numbered-script chain.
`install.sh:35` records that steps 4 and 7 replaced
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
`install.sh:121-122`) — there is no `ingress-nginx` namespace:

```bash
kubectl -n ais-mgmt get svc mgmt-ingress-nginx-controller
# EXTERNAL-IP should equal 20.x.y.z

curl -v https://loki.aisedge.example.com/ready
# Expect 200 with valid Let's Encrypt cert
```

## Workload Identity for cert-manager DNS-01

Azure equivalent of AWS IRSA / GCP Workload Identity:

```bash
# 1. Create a managed identity
az identity create --resource-group ais-edge-rg --name cert-manager-dns01
CLIENT_ID=$(az identity show -g ais-edge-rg -n cert-manager-dns01 --query clientId -o tsv)

# 2. Grant DNS Zone Contributor on the zone
az role assignment create \
  --assignee $CLIENT_ID \
  --role "DNS Zone Contributor" \
  --scope $(az network dns zone show -g ais-edge-rg -n aisedge.example.com --query id -o tsv)

# 3. Enable OIDC + federate to the k8s SA
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
- **Standard SKU vs Basic SKU LB**: AKS defaults to Standard LB. Standard
  IPs can only attach to Standard LBs (and vice versa). Don't mix SKUs.
- **NetworkSecurityGroup AKS-managed**: AKS auto-manages the NSG attached
  to the node subnet. It should auto-open the listener ports when you
  create a LoadBalancer Service. If it doesn't, `kubectl describe svc`
  for the controller will show events.
