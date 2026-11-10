# Per-cloud install guides

> **Review status, 2026-11-10:** cloud topology is implemented in the Helm
> charts and `install.sh`. `sites/example-cloud/values.yaml` is the complete
> management example; cloud sites are no longer parked. The five provider
> guides retain older design and commissioning material, with current
> repository corrections beside it. Provider provisioning commands, quotas,
> capacities and a fresh end-to-end replay are not verified (2026-11-10)
> unless a dated result explicitly says otherwise. Do not treat a past
> OpenStack result as evidence that every provider recipe has been tested.
>
> The old numbered installer scripts were removed. The seven-step installer
> reads site YAML and applies the management and edge charts; there is no
> provider switch or automatic cloud infrastructure provisioning.

The AIS-Edge codebase is **cloud-portable by design**, but the portability
lives in the site file now rather than in a provider switch: `topology:`
(`onprem | cloud`, `charts/mgmt/values.yaml` (`topology`)) picks the network shape, and
everything genuinely cloud-specific — the load balancer, the DNS
zone, the pre-allocated LB address — is configured on those components
themselves rather than consumed by this repo. There is no `CLOUD_PROVIDER`
variable and no `provider_guard_*` function in `install.sh`; the installer
reads the site file with `yaml.safe_load` (`install.sh`, `cfg()`) and hands the
same file to Helm with `-f`.

| Cloud | Doc | Status |
|---|---|---|
| OpenStack private subnet + FIP (candidate production topology) | [openstack-private-subnet.md](openstack-private-subnet.md) | Historical design; chart path implemented, current provider replay not verified (2026-11-10) |
| OpenStack ; Nectar QLD shared external network (dev/test only) | [openstack-nectar.md](openstack-nectar.md) | Historical E2E commissioning (2026-05-25); not a current chart acceptance test |
| AWS (EKS) | [aws.md](aws.md) | Historical design; end-to-end provider recipe not verified (2026-11-10) |
| GCP (GKE) | [gcp.md](gcp.md) | Historical design; end-to-end provider recipe not verified (2026-11-10) |
| Azure (AKS) | [azure.md](azure.md) | Historical design; end-to-end provider recipe not verified (2026-11-10) |

2026-05-25 is the commissioning record in
[openstack-nectar.md](openstack-nectar.md) ("Tested cluster topology
(commissioning, 2026-05-25)"), which is the primary evidence for that run. The
charts landed afterwards, which is why "E2E tested" and "current" are not the
same claim in that row.

The on-prem path (no cloud, hostNetwork :443 on the mgmt VM) is the default
`topology: onprem` and is documented in the top-level
[README.md](../../README.md). Cloud mode is also implemented, with explicit
site ingress settings, public DNS and cloud topology render guards.

## What is yours to provision, and what this installer does

The installer deploys the AIS-Edge application. It does **not** provision cloud
infrastructure, on any cloud, and that boundary is deliberate:

* it is cloud-specific, and this repo would need a different implementation per
  provider to do it;
* it needs credentials that can create and delete resources in your project —
  credentials an application installer should not hold;
* managed Kubernetes supplies some infrastructure, but load-balancer,
  identity, storage and network prerequisites vary by provider and cluster mode.

| | Who does it |
|---|---|
| Kubernetes cluster | you (or your provider) |
| **Load balancer, listener, pool, members** | **you** |
| Floating IP / static address | you |
| DNS records | you |
| Cloud controller manager | only if you choose the `LoadBalancer` path — see below |
| cert-manager, k0smotron, the charts, edge joins | the installer |

### Two ways to get traffic in, and this deployment picks the simpler one

Kubernetes does not know your cloud exists. When a Service asks for
`type: LoadBalancer`, something has to translate that into API calls that create
a real balancer, listeners, pools and members, and then write the address back.

There are two supported shapes. Set one explicitly in the cloud site file;
the chart does not translate `topology: cloud` into ingress subchart values:

**1. `NodePort`: you build the balancer and pin its backend ports.**
The ingress controller is exposed on a node port, and your load balancer
forwards 443 to it. This ingress path does not require a cloud credential in a load-balancer
controller. Other components, such as a DNS-01 solver, may still need cloud access. This is the recommended shape for self-managed clusters: the pieces
you provision are the ones you already provision anyway, and the cluster gains
no privileged component. The cost is that it is static — if the node address or
the node port changes, you update the pool yourself.

**2. `LoadBalancer` — a cloud controller builds it.**
The cluster asks, and a **cloud controller manager** creates and destroys
balancers on demand. Each cloud has its own implementation:

| Cloud | Implementation | Pre-installed? |
|---|---|---|
| OpenStack | `openstack-cloud-controller-manager` | no — self-managed clusters must install it |
| AWS EKS | Selected AWS load-balancer implementation | Varies by EKS mode; verify rather than assume |
| Azure AKS | Managed Azure integration | Provider-managed; not necessarily a visible CCM pod |
| GCP GKE | Managed GCP integration | Provider-managed; not necessarily a visible CCM pod |

On managed Kubernetes a supported load-balancer integration can satisfy the
Service request. Verify the chosen mode and controller before selecting it. On a self-managed cluster it means installing a
credentialled controller into `kube-system` whose whole purpose is to create
infrastructure for you, which is exactly the thing this repo declines to do on
your behalf. Choose it deliberately, not by accident.

**Without one, nothing fails loudly.** If you set `type: LoadBalancer` on a
cluster with no controller, the ingress pod reports `1/1 Running`, its Service
sits at `<pending>` with no external address forever, and every hostname your
edges resolve points at nothing. The first symptom is an edge that will not
join, at the far end of the link.

### What the installer checks before it starts

`install.sh` runs cloud preflight after steps 1 and 2, before applying site
Secrets and the management chart. It may already have installed prerequisites.
Its checks are narrower than a deployment verification:

* For NodePort, resolve the first address of `domain.internal` and reject it
  if empty or equal to `domain.mgmtNodeIP`. This does not prove reachability
  from an edge or resolution of every service name.
* For LoadBalancer, count pods whose names contain `cloud-controller-manager`
  and check the uninitialized node taint. A matching pod need not be Ready;
  a functioning managed service or differently named controller may be missed.
  This branch does not perform the NodePort DNS checks.

`SKIP_CLOUD_PREFLIGHT=1` bypasses these checks, not chart guards. Independently
verify the provider controller, DNS and TCP forwarding before using that
bypass. The heuristic does not justify a claim that all managed clouds pass.

## What's shared vs cloud-specific

**Shared across all clouds (the "cloud topology"):**
- `nginx-ingress` uses an explicitly selected NodePort or LoadBalancer Service.
  The provider integration or operator-managed pool supplies TCP forwarding. On the charts that is a site-file override of the
  vendored subchart under the `ingress-nginx:` key — its in-repo default is
  on-prem, `hostNetwork: true` + `service.type: ClusterIP`
  (`charts/mgmt/values.yaml`, `ingress-nginx.controller`)
- Edges resolve hostnames via real public DNS (no `/etc/hosts` hacks)
- Pod manifests don't carry `hostAliases:` blocks
- The k0s API server is exposed through the same SNI ingress as
  SeaweedFS, Loki, Grafana (single port :443)

**Cloud-specific (and NOT installed by this repo):**
- Cloud-controller-manager installation (or skip, for managed K8s) — you
  provision the load balancer (or, on the `LoadBalancer` path, the CCM and its
  own cloud config) yourself, before `install.sh`
  runs; nothing in `charts/` or `scripts/` installs one
- Credentials format (openrc.sh, ~/.aws/credentials, gcloud ADC, az login)
- DNS-01 solver for cert-manager (Cloudflare, Route53, Cloud DNS, Azure DNS)
  — `certManager.acme.dns01Solver`, a provider-specific block passed through
  verbatim (`charts/mgmt/values.yaml`, `certManager.acme.dns01Solver`)
- LB attachment to pre-allocated addresses uses the selected controller
  interface under `ingress-nginx.controller.service`. It is not portable as
  one field: AWS uses EIP allocation-ID annotations; Azure recommends IP-name
  annotations; other providers have their own address and subnet requirements.

## Adding a new cloud

There is no longer a provider switch to extend. `install.sh` has no
`provider_guard_<name>()` function and no cloud case statement, and
`scripts/01b-install-cloud-controller.sh` went with the rest of the numbered
installer. What replaced both is a site directory plus work outside this repo:

1. `sites/<site>/values.yaml` — set `topology: cloud`, `installMode`,
   `domain.internal` / `domain.mgmtNodeIP`, and override the vendored
   `ingress-nginx:` subchart (`controller.hostNetwork: false`,
   `controller.dnsPolicy: ClusterFirst`,
   `controller.service.type: LoadBalancer`) so the cloud LB controller has
   something to attach your address to.
2. That cloud's own prerequisites, provisioned before `install.sh`: its
   load balancer and its listener and pool, the DNS zone, the reserved
   public IP.

Everything else (chart templates, ingress config, certs, edge join flow) is
topology-aware via `topology`. Cloud render and negative cases exercise the
chart interface, while provider-specific infrastructure and fresh end-to-end
acceptance remain separate checks. The historical provider guides do not
establish that a current managed-cloud deployment has passed them.

## Common workflow

The five steps below apply to every cloud. The per-cloud doc gives you
provider command examples to adapt and verify. Their review banners state
what has not been replayed; the chart interface is the site YAML used here.

1. **Provision the mgmt cluster.** Managed K8s (EKS/GKE/AKS) or a VM
   running k0s. Set `installMode: existing` for managed K8s,
   `installMode: fresh` for a VM (`install.sh`, `INSTALL_MODE`). These are site-file keys,
   not env vars — `install.sh` overwrites its own variables from the file
   unconditionally, so exporting them changes nothing.
2. **Build the load balancer and get its address.** Create the balancer, a
   listener on 443 and a pool, with the mgmt node as a member on the ingress
   node port. Its address is what DNS will name. On the default `NodePort`
   path this is the step that replaces a cloud controller entirely.

   Some clouds hand you the address up front (pre-allocate an Elastic IP /
   static IP / floating IP); others assign it only when the balancer is
   created, so you read it back afterwards. Nectar QLD is the second kind and
   additionally **rejects** pinning a floating IP — see that doc.

   For LoadBalancer, use the provider's supported Service annotation or
   address field under `ingress-nginx.controller.service`; do not assume
   `loadBalancerIP` configures every provider. There is no `LB_PUBLIC_IP`,
   and no top-level `ingressNginx.loadBalancerIP`: it existed, was read by no
   template, and was removed. A parent chart cannot set a subchart's values, so
   the address goes on the subchart itself.
3. **Set DNS** to point at that IP. Use `nip.io` for dev,
   your own zone for prod (`domain.internal`). this chart's DNS-01 solver cannot write challenge records for a nip.io
   zone you do not control, so that development example uses the default
   `certManager.issuer: ais-edge-ca` internal CA.
4. **Edit `sites/<site>/values.yaml`** with the per-cloud values. It is YAML
   read with `yaml.safe_load` and passed straight to Helm; shell `export`
   lines written into it are invalid configuration, not environment settings.
5. **Run `./install.sh -y <site>`** with the credentials sourced in your
   shell. The site argument is mandatory — without it the run aborts at
   `install.sh` (`SITE_DIR`) with `usage: ./install.sh [-y] <site>`. There is no
   `CLOUD_CREDENTIALS_FILE`: no install step reads cloud credentials, only the
   tools you run yourself (`az`, `aws`, `openstack`) do.

See the parent [cloud-deployment.md](../cloud-deployment.md) for the
architecture overview and the dev → prod swap procedure.
