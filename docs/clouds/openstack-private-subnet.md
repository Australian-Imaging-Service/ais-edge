# OpenStack install — **private-subnet topology** (recommended for production)

> Status: **design complete + validated routing**. This is the topology
> that matches how OpenStack networking is "supposed" to work, mirrors
> AWS / GCP / Azure, and avoids every Nectar-QLD-shared-network quirk
> documented in [openstack-nectar.md](openstack-nectar.md).
>
> If you are about to deploy AIS-Edge on a real OpenStack production
> cluster (with admin / tenant control over networks), **use this page,
> not openstack-nectar.md**. The Nectar QLD path is a workaround for
> Nectar's unusual default of placing VMs directly on the shared
> external network.

## TL;DR

```bash
source openrc.sh

# 1. Tenant network + subnet
openstack network create aisedge-internal
openstack subnet create aisedge-internal-sub \
  --network aisedge-internal --subnet-range 192.168.100.0/24 \
  --dns-nameserver 8.8.8.8

# 2. Router connecting the tenant subnet to the external pool
EXTNET=<your-external-net-name>   # e.g. qld, public, ext-net
openstack router create aisedge-rtr
openstack router set --external-gateway $EXTNET aisedge-rtr
openstack router add subnet aisedge-rtr aisedge-internal-sub

# 3. Mgmt VM on the tenant subnet, with a FIP for SSH
openstack server create --image <ubuntu-2204> --flavor <flavor> \
  --network aisedge-internal --security-group default \
  --key-name <yourkey> mgmt-vm
MGMT_FIP=$(openstack floating ip create $EXTNET -f value -c floating_ip_address)
openstack server add floating ip mgmt-vm $MGMT_FIP

# 4. Pre-allocate a FIP for the LB
LB_FIP=$(openstack floating ip create $EXTNET -f value -c floating_ip_address)
echo "LB FIP: $LB_FIP   — point your DNS at this"

# 5. Subnet ID — OCCM needs it to place the LB VIP on the tenant subnet
LB_SUBNET=$(openstack subnet show aisedge-internal-sub -f value -c id)
echo "subnet-id: $LB_SUBNET"
```

Then:

```yaml
# sites/<site>/values.yaml — this file is YAML, not a shell env file.
# install.sh parses it with yaml.safe_load (install.sh:95-113) and reads dotted
# paths out of it; `export` lines here are not config, they are a parse error.

topology: cloud            # install.sh:133 — skips the on-prem /etc/hosts writes
installMode: fresh         # install.sh:134 — the TL;DR above boots a bare VM,
                           # so install.sh installs k0s on it. Use `existing`
                           # only when adopting a cluster that already runs.

domain:
  internal: aisedge.example.com   # your real DNS, or <FIP-dashed>.nip.io for dev
  mgmtNodeIP: "192.168.100.10"    # required (install.sh:130) — the mgmt VM's
                                  # address ON THE TENANT SUBNET, not the FIP

certManager:
  enabled: false                  # install.sh step 2/7 installs cert-manager
  issuer: letsencrypt-prod        # real LE certs once you have real DNS;
                                  # anything prefixed letsencrypt- takes the
                                  # ACME path (cert-issuers.yaml:80)
  acme:
    email: ops@example.com
    server: https://acme-v02.api.letsencrypt.org/directory
    # REQUIRED on a letsencrypt-* issuer: an empty dns01Solver fails the render
    # (cert-issuers.yaml:265), because a ClusterIssuer with no solver leaves
    # every Certificate Pending while nginx serves its default self-signed cert
    # — which reads as a browser warning rather than a misconfiguration. The
    # block is passed through VERBATIM into solvers[0].dns01
    # (cert-issuers.yaml:291), so it must be a shape cert-manager understands.
    dns01Solver:
      # <provider-key>:           # route53 / cloudDNS / azureDNS / webhook / ...
      #   <provider fields>       # see the DNS-01 note below

# The chart ships the ON-PREM ingress shape (hostNetwork on the host's :443,
# Service type ClusterIP) and expects cloud sites to override it here — see the
# CAUTION at charts/mgmt/values.yaml:511-522. All three lines matter: without
# them no Octavia LB is ever requested and loadBalancerIP alone does nothing.
ingress-nginx:                    # subchart key — hyphenated, exactly this
  controller:
    hostNetwork: false
    dnsPolicy: ClusterFirst
    service:
      type: LoadBalancer
      loadBalancerIP: "203.101.x.y"          # the FIP from step 4
      annotations:                           # read by OCCM, not by this chart
        loadbalancer.openstack.org/subnet-id: "<LB_SUBNET from step 5>"
        loadbalancer.openstack.org/availability-zone: "<your-AZ>"
```

```bash
./install.sh -y <site>       # <site> is a directory under sites/ — required
```

There is no cloud-provider, credentials or LB key in the site file to set.
OpenStack credentials reach OCCM the way OCCM is already configured on the
cluster (its own Secret / `openrc` on the control plane), not through this
repo, and the LB is expressed purely as the `Service` override above. Note also
that the top-level `ingressNginx.loadBalancerIP` key at
`charts/mgmt/values.yaml:555` is **dead** — no template reads it.

**DNS-01 on OpenStack.** cert-manager has no built-in solver for OpenStack
Designate; the built-ins are the big public providers. Either run a
cert-manager DNS-01 *webhook* solver for Designate (installed separately — this
chart does not ship one) and reference it under `dns01Solver`, or host the zone
with a provider cert-manager supports natively. For a working solver block in
this repo, see `scripts/ci/values.sh:166-175`, which uses route53 — same shape,
different provider key. If you have no resolvable domain at all, leave
`certManager.issuer: ais-edge-ca` and skip ACME entirely: nip.io cannot satisfy
a DNS-01 challenge (`charts/mgmt/values.yaml:366-370`).

`install.sh` runs the standard cloud path: one `helm upgrade --install` of the
management chart at step 4/7 creates the `Service type=LoadBalancer`, and OCCM
does the rest. Nothing pre-creates the load balancer.

## Why this topology is preferred

| | Nectar QLD shared network | Private subnet + FIP |
|---|---|---|
| Floating IP attaches to LB? | ❌ No — same-network rejection | ✅ Yes — standard Octavia + Neutron router NAT |
| Public IP known up front? | ❌ Discovered after LB creation | ✅ Pre-allocated, pinned at LB create time |
| Extra pre-create pass needed? | ✅ Yes (workaround — the IP has to be discovered, then written back into the site file, then the install re-run) | ❌ No — one `install.sh` run, like AWS/GCP/Azure |
| Cert SANs from the start? | ❌ Need a first pass to learn the IP before the hostnames can be pinned | ✅ FIP is the IP, certs reference it directly |
| Mirrors AWS/GCP/Azure shape? | ❌ Unusual / Nectar-specific | ✅ Identical 4-tier shape |
| Production-ready? | dev only | ✅ |

## Architecture (packet path)

```
external client (edge VM, clinician's laptop, etc.)
   │
   ▼ HTTPS to seaweedfs.aisedge.example.com
   │
   ▼ public DNS resolves to LB_FIP (e.g. 203.101.x.y)
   │
   ▼ TCP to 203.101.x.y:443
   │
   ▼
Neutron router (external gateway = qld/ext-net)
   │
   ▼ 1:1 NAT  LB_FIP ⇄ LB_VIP (e.g. 192.168.100.50)
   │
   ▼
Octavia LB amphora on aisedge-internal subnet
   │
   ▼ TCP forwards to backend pool member
   │
   ▼
mgmt VM (192.168.100.10) NodePort (e.g. :30775)
   │
   ▼
nginx-ingress controller pod
   │
   ▼ SNI / Ingress rule routes to the right Service
   ▼
seaweedfs / loki / grafana / k0s API / konnectivity
```

This is the **exact** shape AWS uses (NLB-in-private-subnet + EIP +
Internet Gateway), GCP uses (Network LB + static IP + Cloud Router),
and Azure uses (Standard LB + public IP + NAT Gateway). The Nectar QLD
shared-network arrangement is the outlier.

## What the install actually does about the LB on this topology

**Nothing pre-creates it, and there is no separate LB step.** Earlier revisions
of this page described a `00a-precreate-lb.sh` script with a "skip if the public
IP is already pinned" guard; no such script exists — `scripts/` holds
`00-common.sh`, `01-install-k0s.sh`, `05-setup-edge-cluster.sh`,
`06-join-edge-worker.sh`, `06b-make-bootstrap.sh`, `06c-post-join.sh` and the
maintenance helpers, and nothing else. The pre-create dance was a Nectar-QLD
workaround for an IP that could not be known in advance; on this topology the
FIP is allocated by you in TL;DR step 4, so there is nothing to discover.

The load balancer is requested declaratively instead, as one line of chart
values. `install.sh` step **4/7** (`helm upgrade --install mgmt charts/mgmt`)
renders the vendored ingress-nginx subchart with the override from the site
file, producing a `Service type=LoadBalancer` carrying
`loadBalancerIP: 203.101.x.y` and the OCCM annotations. OCCM then:

1. Creates a fresh Octavia LB on `aisedge-internal` with the requested
   VIP (Neutron allocates one from the subnet range).
2. Associates the pre-allocated FIP to the LB VIP port via Neutron
   router NAT.
3. Adds listeners + pool + members.

Service status populates with `EXTERNAL-IP=<LB_FIP>`. No retries, no
errors. Install runs one-shot:

```bash
kubectl -n ais-mgmt get svc mgmt-ingress-nginx-controller
# release `mgmt` in namespace `ais-mgmt` (install.sh:121-122); there is no
# ingress-nginx namespace. EXTERNAL-IP stays <none> if the ingress-nginx
# override is missing from the site file — the chart default is
# service.type ClusterIP (charts/mgmt/values.yaml:536).
```

## Security group rules (same as Nectar QLD)

The tenant subnet's security groups must allow the LB amphora to reach
the mgmt VM's NodePort range. Either:
- A. Open NodePort range on the tenant SG:
  ```bash
  openstack security group rule create --ingress --protocol tcp \
    --dst-port 30000:32767 --remote-ip 0.0.0.0/0 default
  ```
- B. Or restrict to the amphora SG: `--remote-group <amphora-sg-id>`.

For production, prefer (B) — narrower attack surface. Octavia's
amphora SG ID is visible via:
```bash
openstack port show <lb-vip-port-id> -f value -c security_group_ids
```

## Pros + cons

**Pros:**
- Single-pass `install.sh -y <site>` with the LB address pinned in the site
  file (`ingress-nginx.controller.service.loadBalancerIP`) from the start.
- Standard `Service type=LoadBalancer` + FIP pattern that every CCM
  (AWS, GCP, Azure, OpenStack) implements the same way.
- No Nectar-specific workarounds — same codepath as managed K8s.
- Explicit network boundaries, smaller attack surface
  scoped to the tenant subnet.

**Cons:**
- One-time network setup (router + private subnet) — a few openstack
  CLI commands you run once per project.
- Two FIPs per deployment (one for mgmt VM SSH, one for the LB).
- On Nectar, this requires that your project has quota for routers +
  private networks (most do, by default).

## Migrating an existing Nectar QLD deployment to this topology

You can't move a VM between networks live. Plan a maintenance window:

1. Stand up the new network + router + subnet.
2. Snapshot the mgmt VM disk (`openstack server image create mgmt-vm`).
3. Boot a new mgmt VM from the snapshot on the new tenant subnet.
4. Re-allocate the FIP (or allocate a fresh one) and update DNS.
5. Update `sites/<site>/values.yaml` to the new IDs — at minimum
   `domain.mgmtNodeIP`, the ingress-nginx `loadBalancerIP`, and the OCCM
   subnet-id annotation.
6. Run `./install.sh -y <site>` on the new VM — it provisions fresh from the
   snapshotted state.

SeaweedFS data, k0smotron child clusters, and pod configs all live
inside the cluster — they migrate with the VM snapshot.
