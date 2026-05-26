# Azure install (AKS)

> Status: **untested, design complete**. Same pattern as AWS/GCP — AKS
> bundles its own cloud-controller-manager, so step 01b auto-skips.

## TL;DR

```bash
az group create --name ais-edge-rg --location australiaeast
az aks create --resource-group ais-edge-rg --name ais-edge-mgmt \
  --node-count 2 --node-vm-size Standard_D2s_v3 \
  --enable-managed-identity --generate-ssh-keys
az network public-ip create --resource-group ais-edge-rg \
  --name ais-edge-lb-ip --sku Standard --allocation-method Static
# Edit config/management.env (CLOUD_PROVIDER=azure, INSTALL_MODE=existing, etc.)
./install.sh -y
```

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

**Dev**: `INTERNAL_DOMAIN="dev.<ip-with-dashes>.nip.io"`

**Prod** (Azure DNS):
```bash
az network dns zone create --resource-group ais-edge-rg --name aisedge.example.com
az network dns record-set a add-record \
  --resource-group ais-edge-rg --zone-name aisedge.example.com \
  --record-set-name "*" --ipv4-address 20.x.y.z
```

## Step 4 — Config

`config/management.env`:

```bash
export CLOUD_PROVIDER="azure"
export CLOUD_CREDENTIALS_FILE=""           # az CLI keeps creds in ~/.azure
export INSTALL_MODE="existing"             # we're using AKS
export INSTALL_TOPOLOGY="cloud"
export LB_PUBLIC_IP="20.x.y.z"             # the reserved static IP
export INTERNAL_DOMAIN="aisedge.example.com"
export CERT_ISSUER="letsencrypt-prod"
export DNS_PROVIDER="azuredns"             # for cert-manager DNS-01
```

The AKS-specific annotation that pins the LB to your pre-allocated IP is
already in `manifests/01-management/nginx-ingress-values-cloud.yaml.tpl`
in spirit — but you may need to add this annotation if AKS doesn't pick
up `loadBalancerIP`:
```yaml
service.beta.kubernetes.io/azure-load-balancer-resource-group: ais-edge-rg
```

## Step 5 — Run install.sh

```bash
./install.sh -y
```

| Step | What happens on AKS |
|---|---|
| 01  | Skipped (`INSTALL_MODE=existing`) |
| 01b | Skipped (`CLOUD_PROVIDER=azure` → managed K8s) |
| 02–04, 02d | Standard |
| 02c | nginx-ingress → AKS provisions Azure Standard LB, attaches static IP |
| 05–07c | Standard edge setup |

## Step 6 — Verify

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller
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
