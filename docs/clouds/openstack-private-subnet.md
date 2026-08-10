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

# 5. Subnet ID for management.env
LB_SUBNET=$(openstack subnet show aisedge-internal-sub -f value -c id)
echo "LB_SUBNET_ID=$LB_SUBNET"
```

Then:

```bash
# config/management.env
export INSTALL_TOPOLOGY="cloud"
export CLOUD_PROVIDER="openstack"
export CLOUD_CREDENTIALS_FILE="/path/to/openrc.sh"
export LB_PUBLIC_IP="$LB_FIP"                   # the FIP from step 4
export LB_SUBNET_ID="$LB_SUBNET"                 # the tenant subnet
export LB_AVAILABILITY_ZONE="<your-AZ>"          # AZ where mgmt VM lives
export PRECREATE_LB=""                           # NOT needed — FIP gives us the IP up front
export OCCM_CLUSTER_NAME="aisedge"
export INTERNAL_DOMAIN="aisedge.example.com"     # your real DNS, or .<FIP-dashed>.nip.io for dev
export CERT_ISSUER="letsencrypt-prod"            # real LE certs once you have real DNS

./install.sh -y
```

`install.sh` runs the standard cloud path — no Nectar-specific
`00a-precreate-lb` step needed.

## Why this topology is preferred

| | Nectar QLD shared network | Private subnet + FIP |
|---|---|---|
| Floating IP attaches to LB? | ❌ No — same-network rejection | ✅ Yes — standard Octavia + Neutron router NAT |
| `LB_PUBLIC_IP` known up front? | ❌ Discovered after LB creation | ✅ Pre-allocated, pinned at LB create time |
| `00a-precreate-lb.sh` needed? | ✅ Yes (workaround) | ❌ No — install runs one-shot like AWS/GCP/Azure |
| Cert SANs from the start? | ❌ Need `00a` to write IP back into env first | ✅ FIP is the IP, certs reference it directly |
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

## What `00a-precreate-lb.sh` looks like on this topology

It runs but **does nothing** — `LB_PUBLIC_IP` is already set in
`management.env`, so 00a's "skip if LB_PUBLIC_IP is pinned" guard
fires:

```
=== 00a: pre-create LB — SKIPPED (LB_PUBLIC_IP=203.101.x.y already pinned) ===
```

Then 02c's `helm install nginx-ingress` renders a `Service type=LoadBalancer`
with `loadBalancerIP: ${LB_PUBLIC_IP}`. OCCM:
1. Creates a fresh Octavia LB on `aisedge-internal` with the requested
   VIP (Neutron allocates one from the subnet range).
2. Associates the pre-allocated `LB_FIP` to the LB VIP port via Neutron
   router NAT.
3. Adds listeners + pool + members.

Service status populates with `EXTERNAL-IP=<LB_FIP>`. No retries, no
errors. Install runs one-shot.

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
- Single-pass `install.sh -y` with pinned `LB_PUBLIC_IP` from the start.
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
5. Update `config/management.env` to the new IDs.
6. Run `./install.sh -y` on the new VM — it provisions fresh from the
   snapshotted state.

SeaweedFS data, k0smotron child clusters, and pod configs all live
inside the cluster — they migrate with the VM snapshot.
