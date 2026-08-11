# Per-cloud install guides

The AIS-Edge codebase is **cloud-portable by design** — a single
`CLOUD_PROVIDER` env var picks which cloud you're installing on. Per-cloud
specifics (credentials, LB controller, DNS, gotchas) are isolated to one
small switch table each in `install.sh` and `scripts/01b-install-cloud-controller.sh`.

| Cloud | Doc | Status |
|---|---|---|
| OpenStack — private subnet + FIP (**recommended for production**) | [openstack-private-subnet.md](openstack-private-subnet.md) | ✅ Design complete, mirrors AWS/GCP/Azure |
| OpenStack — Nectar QLD shared external network (dev/test only) | [openstack-nectar.md](openstack-nectar.md) | ✅ E2E tested (2026-05-26) |
| AWS (EKS) | [aws.md](aws.md) | 📋 Design complete, untested |
| GCP (GKE) | [gcp.md](gcp.md) | 📋 Design complete, untested |
| Azure (AKS) | [azure.md](azure.md) | 📋 Design complete, untested |

The on-prem path (no cloud, hostNetwork :443 on the mgmt VM) is the
default `INSTALL_TOPOLOGY=onprem` and documented in the top-level
[README.md](../../README.md).

## What's shared vs cloud-specific

**Shared across all clouds (the "cloud topology"):**
- `nginx-ingress` runs as `Service type=LoadBalancer` (the cloud LB
  controller does the rest)
- Edges resolve hostnames via real public DNS (no `/etc/hosts` hacks)
- Pod manifests don't carry `hostAliases:` blocks
- The k0s API server is exposed through the same SNI ingress as
  SeaweedFS, Loki, Grafana (single port :443)

**Cloud-specific (one switch table per cloud):**
- Cloud-controller-manager installation (or skip, for managed K8s)
- Credentials format (openrc.sh, ~/.aws/credentials, gcloud ADC, az login)
- DNS-01 solver for cert-manager (Cloudflare, Route53, Cloud DNS, Azure DNS)
- LB attachment to pre-allocated public IP

## Adding a new cloud

You only edit two files:

1. `install.sh` — add a `provider_guard_<name>()` function (validates the
   provider's credentials are in the env) + a branch in the case statement.
2. `scripts/01b-install-cloud-controller.sh` — add a case branch that
   either installs that cloud's CCM or skips for managed-K8s flavours.

Everything else (templates, ingress configs, certs, edge join flow) is
already topology-aware via `INSTALL_TOPOLOGY` and works unchanged.

## Common workflow

The five steps below apply to every cloud. The per-cloud doc gives you
the exact commands to substitute.

1. **Provision the mgmt cluster.** Managed K8s (EKS/GKE/AKS) or a VM
   running k0s. Set `INSTALL_MODE=existing` for managed K8s,
   `INSTALL_MODE=fresh` for a VM.
2. **Pre-allocate a public IP** (Elastic IP / static IP / floating IP).
   Set `LB_PUBLIC_IP` to it. Some clouds (Nectar QLD) need this to be
   empty — see the per-cloud doc.
3. **Set DNS** to point at that IP. Use `nip.io` for dev,
   your own zone for prod.
4. **Edit `sites/<site>/values.yaml`** with the per-cloud values.
5. **Run `./install.sh -y`** with the credentials sourced in your shell
   (or `CLOUD_CREDENTIALS_FILE` pointing at the openrc/aws/etc. file).

See the parent [cloud-deployment.md](../cloud-deployment.md) for the
architecture overview and the dev → prod swap procedure.
