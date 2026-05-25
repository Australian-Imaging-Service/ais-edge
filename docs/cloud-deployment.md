# Cloud deployment (managed-K8s topology)

This document describes the **cloud topology** — the deployment shape used
when the management cluster runs on managed Kubernetes (EKS / GKE / AKS /
OpenStack Magnum / Nectar k0s with Octavia). It is the equivalent of the
on-prem topology described in the main `README.md`, with two specific
substitutions:

| | On-prem | Cloud |
|---|---|---|
| Inbound TLS | `nginx-ingress` on `hostNetwork: true` :443 | `nginx-ingress` Service `type: LoadBalancer`, cloud LB takes over :443 |
| Hostname resolution | `hostAliases:` in every pod + `/etc/hosts` on every edge VM | Real public DNS (a domain you own, or `nip.io` for dev) |

Nothing else changes — same application stack (xnat-ingest, Orthanc, Loki,
Vector, Prometheus, Grafana, k0smotron, SeaweedFS), same memory-leak fix,
same dashboards, same alerts.

## One env var picks the topology

`config/management.env`:
```bash
export INSTALL_TOPOLOGY="cloud"               # vs "onprem"
export LB_PUBLIC_IP="203.101.227.222"         # pre-allocated floating IP
export INTERNAL_DOMAIN="dev-nectar-test.203-101-227-222.nip.io"   # or your real zone
export CERT_ISSUER="ais-edge-ca-issuer"       # nip.io must use self-signed CA
```

The install scripts read those vars and:
* skip `/etc/hosts` writes on edge VMs (step 06)
* skip the CoreDNS `hosts {}` patch (step 06)
* strip the `hostAliases:` block from every edge pod (rendered at apply time)
* install the openstack-cloud-controller-manager via step 01b
* run nginx-ingress as `Service type: LoadBalancer` with the chosen `loadBalancerIP`
* drop the IP SAN from every server certificate (cloud certs are pure DNS-named)

Everything else (the four steps 02-04, the observability stack 02d, the
edge cluster steps 05-07c) runs unchanged.

## Dev DNS via nip.io (zero registration)

`nip.io` is a free wildcard DNS service. Any hostname like
`<anything>.<ip-with-dashes>.nip.io` resolves to the embedded IP — no
DNS records to register, no domain to buy. Example:

```
loki.dev-nectar-test.203-101-227-222.nip.io   → 203.101.227.222
seaweedfs.dev-nectar-test.203-101-227-222.nip.io → 203.101.227.222
...
```

For our dev work on Nectar, we use nip.io and `ais-edge-ca-issuer` because
Let's Encrypt rejects nip.io domains (anti-abuse). Promotion to production
is two env-var edits — see "Dev → Prod swap" below.

## Production swap (when you own a real domain)

```bash
# 1. INTERNAL_DOMAIN — the one string everything else derives from
export INTERNAL_DOMAIN="aisedge.uq.edu.au"

# 2. CERT_ISSUER — switch from self-signed to Let's Encrypt prod
export CERT_ISSUER="letsencrypt-prod"

# 3. DNS_PROVIDER — needed for cert-manager's DNS-01 challenge solver
export DNS_PROVIDER="cloudflare"   # or route53 | rfc2136
# Plus the corresponding Secret in cert-manager namespace, see
# manifests/01-management/dns01-solvers/README.md
```

Re-run `./install.sh -y`. All other code stays the same.

The certificate templates emit DNS-only SANs in cloud mode, which is
exactly what Let's Encrypt requires. The edge CA-bundle distribution can
be removed (every edge already trusts Let's Encrypt roots through OS
truststores) — that's a separate cleanup, not a blocker for the swap.

## How the LB gets its IP

Step 01b installs the openstack-cloud-controller-manager (or, on EKS/AKS/
GKE, the managed control plane already runs the equivalent — step 01b is
a no-op there).

Step 02c renders `nginx-ingress-values-cloud.yaml.tpl` with
`loadBalancerIP: ${LB_PUBLIC_IP}` and lets the CCM provision a real LB:

```
Operator runs:
  $ openstack floating ip create qld    # → 203.101.227.222
                          ↓
  config/management.env:
    LB_PUBLIC_IP=203.101.227.222
                          ↓
  Step 01b: openstack-cloud-controller-manager + cloud.conf Secret
                          ↓
  Step 02c: nginx-ingress Service type=LoadBalancer
              spec.loadBalancerIP: 203.101.227.222
                          ↓
  CCM watches the Service:
              ↓
          Octavia API → create LB + listener + pool + members
                      → associate floating IP 203.101.227.222
                          ↓
  Service status:
    loadBalancer:
      ingress:
        - ip: 203.101.227.222    # the pre-allocated FIP, now attached
```

On AWS the same code path provisions an NLB and the FIP becomes an
Elastic IP. On GCP it's a Network LB with a pre-allocated regional IP.
On Azure, a Standard LB with a pre-allocated public IP.

## End-to-end trace of one edge request in cloud mode

```
   xnat-ingest-sort pod (edge cluster)
         │
         │ HTTP push to  loki.dev-nectar-test.203-101-227-222.nip.io:443
         ▼
   edge worker DNS resolver (kubelet's /etc/resolv.conf chain)
         │
         │ → public DNS resolves nip.io → 203.101.227.222
         ▼
   TCP connect → 203.101.227.222:443
         │
         ▼
   Cloud L4 load balancer (Octavia / NLB / Azure LB / GCP LB)
         │
         │ → routes :443 to nginx-ingress controller Service backends
         ▼
   nginx-ingress controller pod (mgmt cluster)
         │
         │ → SNI passthrough (SSL passthrough enabled)
         ▼
   Service loki.observability.svc.cluster.local:3100
         │
         ▼
   Loki ingester
```

Identical to the on-prem path except for one hop (LB instead of direct
node binding) and one resolution mechanism (DNS instead of /etc/hosts).
The TLS termination happens at Loki itself (or at the backend Service it
points to) — the LB and ingress controller only pass bytes through.

## Test matrix (what to run after deployment)

| What | How |
|---|---|
| LB came up with the right IP | `kubectl -n ingress-nginx get svc ingress-nginx-controller -o yaml` — `status.loadBalancer.ingress[0].ip` should equal `LB_PUBLIC_IP` |
| TLS termination | `curl -kv https://loki.dev-nectar-test.<lb-ip-dashes>.nip.io/` — expect TLS handshake + 404 default backend |
| SNI passthrough | `curl --resolve loki.dev-nectar-test.<lb-ip-dashes>.nip.io:443:<lb-ip> https://loki.dev-nectar-test.<lb-ip-dashes>.nip.io/ready` — expect Loki's `ready` response |
| Edge resolves via real DNS | `kubectl --kubeconfig kubeconfig-edge-dev exec -n xnat-ingest deploy/s3-uploader -- nslookup seaweedfs.dev-nectar-test.<lb-ip-dashes>.nip.io` — should resolve via the worker's standard resolver |
| Full pipeline | drop a DICOM into Orthanc (via `dcmsend`, `storescu`, or the Orthanc REST upload), wait for sort, watch `upload_completed` event land in Loki + dashboards |
| Memory leak fix | sample `kubectl top pod -n xnat-upload` over 2 hours — should stay flat ±20 MiB |

## When to use on-prem vs cloud

| Use **on-prem** if... | Use **cloud** if... |
|---|---|
| The mgmt VM is a bare-metal or single-VM node you fully control | The mgmt cluster is managed K8s (EKS / GKE / AKS / Magnum) |
| Operating in an air-gapped environment without DNS | You have a real DNS zone you can publish records into |
| Edges are inside the same LAN as the mgmt VM and can reach it by IP | Edges are remote and reach mgmt over the public internet |
| You want zero cloud provider dependencies | You want LB / auto-renew / scaling provided by the cloud |
| Simplicity over scale | Multiple ingress replicas for horizontal scale |

Both topologies are first-class in the codebase. There's no implicit
preference — the `INSTALL_TOPOLOGY` env var is the single switch.
