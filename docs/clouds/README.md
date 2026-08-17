# Per-cloud install guides

> ⚠️ **These five guides describe the pre-Helm imperative installer and have
> not been ported.** The repo has since consolidated into `charts/mgmt` +
> `charts/edge`, driven by `./install.sh <site>` reading
> `sites/<site>/values.yaml` — `install.sh:35` records that "Steps 4 and 7
> replace what used to be scripts 02b/02c/02d/03/04/07/07b/07c". The scripts
> these guides call (`00a`, `01b`, `02b`, `02c`, `02d`, `07b`, `07c`) and the
> shell variables they set (`CLOUD_PROVIDER`, `LB_PUBLIC_IP`, `CERT_ISSUER`,
> `DNS_PROVIDER`, `CLOUD_CREDENTIALS_FILE`) no longer exist anywhere outside
> `docs/`. `topology: cloud` survives as a chart value
> (`charts/mgmt/values.yaml:32`) but is parked, not ported — every site under
> `sites/` ships `topology: onprem`, annotated "cloud   parked, not ported to
> the charts yet". Read the guides below as design records, not as an install
> path.

The AIS-Edge codebase is **cloud-portable by design**, but the portability
lives in the site file now rather than in a provider switch: `topology:`
(`onprem | cloud`, `charts/mgmt/values.yaml:32`) picks the network shape, and
everything genuinely cloud-specific — the cloud-controller-manager, the DNS
zone, the pre-allocated LB address — is configured on those components
themselves rather than consumed by this repo. There is no `CLOUD_PROVIDER`
variable and no `provider_guard_*` function in `install.sh`; the installer
reads the site file with `yaml.safe_load` (`install.sh:95-113`) and hands the
same file to Helm with `-f`.

| Cloud | Doc | Status |
|---|---|---|
| OpenStack — private subnet + FIP (**recommended for production**) | [openstack-private-subnet.md](openstack-private-subnet.md) | 📋 Design complete, pre-Helm; mirrors AWS/GCP/Azure |
| OpenStack — Nectar QLD shared external network (dev/test only) | [openstack-nectar.md](openstack-nectar.md) | ✅ E2E tested (2026-05-25), on the pre-Helm installer |
| AWS (EKS) | [aws.md](aws.md) | 📋 Design complete, untested |
| GCP (GKE) | [gcp.md](gcp.md) | 📋 Design complete, untested |
| Azure (AKS) | [azure.md](azure.md) | 📋 Design complete, untested |

2026-05-25 is the commissioning record in
[openstack-nectar.md](openstack-nectar.md) ("Tested cluster topology
(commissioning, 2026-05-25)"), which is the primary evidence for that run. The
charts landed afterwards, which is why "E2E tested" and "current" are not the
same claim in that row.

The on-prem path (no cloud, hostNetwork :443 on the mgmt VM) is the default
`topology: onprem` and is documented in the top-level
[README.md](../../README.md). It is the only path the charts install today.

## What's shared vs cloud-specific

**Shared across all clouds (the "cloud topology"):**
- `nginx-ingress` runs as `Service type=LoadBalancer` (the cloud LB
  controller does the rest). On the charts that is a site-file override of the
  vendored subchart under the `ingress-nginx:` key — its in-repo default is
  on-prem, `hostNetwork: true` + `service.type: ClusterIP`
  (`charts/mgmt/values.yaml:523-550`)
- Edges resolve hostnames via real public DNS (no `/etc/hosts` hacks)
- Pod manifests don't carry `hostAliases:` blocks
- The k0s API server is exposed through the same SNI ingress as
  SeaweedFS, Loki, Grafana (single port :443)

**Cloud-specific (and NOT installed by this repo):**
- Cloud-controller-manager installation (or skip, for managed K8s) — you
  provision the CCM and its own cloud config yourself, before `install.sh`
  runs; nothing in `charts/` or `scripts/` installs one
- Credentials format (openrc.sh, ~/.aws/credentials, gcloud ADC, az login)
- DNS-01 solver for cert-manager (Cloudflare, Route53, Cloud DNS, Azure DNS)
  — `certManager.acme.dns01Solver`, a provider-specific block passed through
  verbatim (`charts/mgmt/values.yaml:426`)
- LB attachment to a pre-allocated public IP —
  `ingress-nginx.controller.service.loadBalancerIP` in the site file

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
   cloud-controller-manager and the CCM's config, the DNS zone, the reserved
   public IP.

Everything else (chart templates, ingress config, certs, edge join flow) is
already topology-aware via `topology` and is intended to work unchanged — but
that path is unexercised on the charts, which is what the banner above is
about.

## Common workflow

The five steps below apply to every cloud. The per-cloud doc gives you
the exact commands to substitute; the keys named here are the ones the charts
actually read, which is not what those docs still print.

1. **Provision the mgmt cluster.** Managed K8s (EKS/GKE/AKS) or a VM
   running k0s. Set `installMode: existing` for managed K8s,
   `installMode: fresh` for a VM (`install.sh:134`). These are site-file keys,
   not env vars — `install.sh` overwrites its own variables from the file
   unconditionally, so exporting them changes nothing.
2. **Pre-allocate a public IP** (Elastic IP / static IP / floating IP) and set
   it as `ingress-nginx.controller.service.loadBalancerIP`. Some clouds
   (Nectar QLD) need this to be empty — see the per-cloud doc. There is no
   `LB_PUBLIC_IP`, and the intuitive-looking top-level
   `ingressNginx.loadBalancerIP` (`charts/mgmt/values.yaml:555`) is consumed
   by no template, so setting it there fails silently.
3. **Set DNS** to point at that IP. Use `nip.io` for dev,
   your own zone for prod (`domain.internal`). `nip.io` cannot satisfy
   Let's Encrypt, so dev stays on the default `certManager.issuer:
   ais-edge-ca` internal CA.
4. **Edit `sites/<site>/values.yaml`** with the per-cloud values. It is YAML
   read with `yaml.safe_load` and passed straight to Helm; shell `export`
   lines written into it are inert.
5. **Run `./install.sh -y <site>`** with the credentials sourced in your
   shell. The site argument is mandatory — without it the run aborts at
   `install.sh:80` with `usage: ./install.sh [-y] <site>`. There is no
   `CLOUD_CREDENTIALS_FILE`: no install step reads cloud credentials, only the
   tools you run yourself (`az`, `aws`, `openstack`) do.

See the parent [cloud-deployment.md](../cloud-deployment.md) for the
architecture overview and the dev → prod swap procedure.
