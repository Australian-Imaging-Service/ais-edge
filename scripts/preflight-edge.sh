#!/usr/bin/env bash
# =============================================================================
# preflight-edge.sh — is this machine safe to join as an edge worker?
# =============================================================================
#   Run ON THE EDGE, before carrying a join bundle to it:
#       ./preflight-edge.sh [MGMT_IP] [MGMT_PORT]
#
# READ-ONLY. Every command here inspects; nothing installs, changes a rule,
# writes a file outside /tmp, or restarts anything. It is meant to be safe to
# run on a live clinical box during working hours.
#
# WHY THIS EXISTS
#
# An edge is often not a clean VM. cai-lfs3 runs RSNA CTP receiving DICOM from
# ~4 scanners, Docker with ImageTrove, and a dormant microk8s — on a host whose
# large volumes are already full. Joining it as a k0s worker puts a second
# container runtime, a CNI and a kube-proxy onto that machine. The failure modes
# are not "the install errors": they are CTP silently losing a scanner because
# something reordered an iptables chain, or / filling and taking the OS down.
#
# Each check corresponds to a blocker seen on a real edge: a second container
# runtime fighting the first over iptables, a full volume, a dormant
# orchestrator still holding ports, a kernel without the modules kube-router
# needs. The site-specific plan this was written against is not in the repo
# (docs/cai-lfs3-deployment-plan.md is gitignored — it names one hospital's
# hosts), so each check states its own reasoning inline instead.
# A FAIL is a stop. A WARN is a decision someone has to make and write down.
#
# It also writes a BASELINE to /tmp/edge-preflight-baseline-<host>-<date>.txt.
# Keep it. After the join, re-run and diff to prove what changed.
# =============================================================================
set -uo pipefail

MGMT_IP="${1:-}"
MGMT_PORT="${2:-443}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "  [ OK ] $*"; PASS=$((PASS+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
hdr()  { echo; echo "=============================================================="; echo " $*"; echo "=============================================================="; }

BASELINE="/tmp/edge-preflight-baseline-$(hostname -s)-$(date +%Y%m%d-%H%M).txt"

echo "preflight-edge.sh on $(hostname -f)  --  $(date)"
echo "baseline will be written to: ${BASELINE}"

# -----------------------------------------------------------------------------
hdr "1. DISK — can the pipeline run without filling the OS disk?"
# -----------------------------------------------------------------------------
# The edge chart declares hostPath PVs. hostPath capacity is ADVISORY ONLY —
# Kubernetes does not enforce it, so nothing stops the pipeline consuming the
# whole filesystem. On a box where CTP and Docker share that filesystem, ENOSPC
# takes clinical DICOM receiving down with it.
df -hT / /var /tmp 2>/dev/null | sed 's/^/    /'
echo
ROOT_AVAIL_G=$(df -BG --output=avail / 2>/dev/null | tail -1 | tr -dc '0-9')
echo "    / available: ${ROOT_AVAIL_G}G"
if [ "${ROOT_AVAIL_G:-0}" -ge 1000 ]; then
    ok "/ has >=1000G free — covers the 500Gi pipeline + 500Gi facilityBackup defaults"
elif [ "${ROOT_AVAIL_G:-0}" -ge 300 ]; then
    warn "/ has ${ROOT_AVAIL_G}G free. The edge site defaults declare 500Gi+500Gi and are
         NOT enforced. Lower storage.pipeline.capacity / facilityBackup.capacity in
         sites/<edge>/values.yaml AND agree a disk-full alert threshold first."
else
    bad "/ has only ${ROOT_AVAIL_G}G free — too little for a DICOM staging pipeline"
fi
echo
echo "    other filesystems (the plan says /data_local and /database are full):"
df -hT 2>/dev/null | grep -vE 'tmpfs|udev|squashfs|overlay' | sed 's/^/    /'
echo
echo "    inodes on / (a million small DICOM files exhausts these before bytes):"
df -i / 2>/dev/null | sed 's/^/    /'

# -----------------------------------------------------------------------------
hdr "2. PORTS — does k0s collide with anything CTP is listening on?"
# -----------------------------------------------------------------------------
# A k0s WORKER binds: 10250 kubelet, 10256 kube-proxy health, 179 kube-router
# BGP, and 127.0.0.1:7443 for the worker-local haproxy. The hosted control plane
# lives on the management node, so 6443/2379/2380 are NOT needed here.
echo "    everything currently listening (THIS IS YOUR BASELINE):"
(sudo ss -tulpnH 2>/dev/null || ss -tulpnH 2>/dev/null) | sort -k5 | sed 's/^/    /'
echo
for p in 10250 10256 179 7443 10248 10249; do
    if (sudo ss -tulpnH 2>/dev/null || ss -tulpnH) | awk '{print $5}' | grep -qE "[:.]${p}$"; then
        bad "port ${p} is ALREADY IN USE — k0s needs it; find the owner above"
    else
        ok "port ${p} free"
    fi
done
echo
echo "    DICOM-ish listeners to protect (104/11112/4242/2575 and CTP's own):"
(sudo ss -tulpnH 2>/dev/null || ss -tulpnH) | grep -E "[:.](104|11112|4242|2575|8080|8443)\b" | sed 's/^/    /' \
    || echo "    (none matched — confirm with the CTP admin what it binds)"

# -----------------------------------------------------------------------------
hdr "3. SUBNETS — do the cluster CIDRs overlap anything real?"
# -----------------------------------------------------------------------------
# pod CIDR     10.244.0.0/16  ->  10.244.0.0 - 10.244.255.255
# service CIDR 10.96.0.0/12   ->  10.96.0.0  - 10.111.255.255
# An overlap does not fail the install. It silently blackholes the real network:
# a CIFS server or scanner inside those ranges becomes unreachable the moment
# kube-router installs its routes.
echo "    interfaces:"; ip -4 -br addr 2>/dev/null | sed 's/^/    /'
echo; echo "    routes:";  ip -4 route 2>/dev/null | sed 's/^/    /'
echo; echo "    CIFS/NFS mounts and their servers:"
mount 2>/dev/null | grep -E 'type (cifs|nfs|nfs4)' | sed 's/^/    /' || echo "    (none)"
echo; echo "    DNS servers:"
grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | sed 's/^/    /'
echo
# Collect every IP this box actually talks to, then test each against the CIDRs.
CANDIDATES=$( { ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1
                ip -4 route | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\./) print $i}' | cut -d/ -f1
                mount | grep -oE '//[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr -d '/'
                mount | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
                grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}'
              } 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u )
CLASH=0
for ipaddr in $CANDIDATES; do
    python3 - "$ipaddr" <<'PY' || CLASH=1
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
for net, label in ((ipaddress.ip_network("10.244.0.0/16"), "POD CIDR"),
                   (ipaddress.ip_network("10.96.0.0/12"),  "SERVICE CIDR")):
    if ip in net:
        print(f"        !! {ip} falls inside {net} ({label})")
        raise SystemExit(1)
raise SystemExit(0)
PY
done
if [ "$CLASH" -eq 0 ]; then
    ok "no in-use address falls inside 10.244.0.0/16 or 10.96.0.0/12"
else
    bad "CIDR OVERLAP (above). Change podCIDR/serviceCIDR in the k0s config before joining."
fi
echo "    docker bridge (expected 172.17/16 — must NOT be inside the CIDRs above):"
ip -4 -br addr show docker0 2>/dev/null | sed 's/^/    /' || echo "    (no docker0)"

# -----------------------------------------------------------------------------
hdr "4. EXISTING KUBERNETES — microk8s leftovers that fight k0s"
# -----------------------------------------------------------------------------
if command -v snap >/dev/null 2>&1; then
    snap list microk8s 2>/dev/null | sed 's/^/    /' || echo "    microk8s snap: not installed"
    if snap list microk8s >/dev/null 2>&1; then
        ACTIVE=$(snap services microk8s 2>/dev/null | awk 'NR>1 && $3=="active"' | wc -l)
        if [ "$ACTIVE" -eq 0 ]; then
            warn "microk8s is INSTALLED but all services inactive. Snap AUTO-REFRESH can
         re-enable it without warning and it will fight k0s for CNI and ports.
         Prefer 'sudo snap remove microk8s' during an approved change window."
            echo "         next snap refresh:"; snap refresh --time 2>/dev/null | sed 's/^/           /'
        else
            bad "microk8s has ${ACTIVE} ACTIVE service(s) — it will collide with k0s"
        fi
    fi
fi
for d in /var/lib/cni /etc/cni /opt/cni /var/snap/microk8s /var/lib/kubelet; do
    if [ -e "$d" ]; then warn "leftover exists: $d ($(sudo du -sh "$d" 2>/dev/null | cut -f1))"
    else ok "absent: $d"; fi
done
if command -v k0s >/dev/null 2>&1; then
    warn "k0s binary already present: $(k0s version 2>/dev/null)"
    systemctl is-active k0sworker 2>/dev/null | sed 's/^/         k0sworker: /'
else
    ok "no k0s installed yet"
fi

# -----------------------------------------------------------------------------
hdr "5. DOCKER / CTP BASELINE — prove what was working before you touch it"
# -----------------------------------------------------------------------------
# k0s runs its OWN containerd on /run/k0s/containerd.sock and does not touch the
# moby daemon. The risk is not the runtime, it is kube-router and kube-proxy
# rewriting iptables chains that Docker and CTP depend on.
if command -v docker >/dev/null 2>&1; then
    echo "    running containers + restart policy:"
    sudo docker ps --format '    {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null
    for c in $(sudo docker ps -q 2>/dev/null); do
        sudo docker inspect -f '    {{.Name}} restart={{.HostConfig.RestartPolicy.Name}} netmode={{.HostConfig.NetworkMode}}' "$c" 2>/dev/null
    done
    ok "docker baseline captured (see ${BASELINE})"
else
    ok "docker not installed"
fi
echo
echo "    iptables rule counts — RE-CHECK THESE AFTER THE JOIN:"
for t in filter nat mangle; do
    printf '    %-8s total=%-6s DOCKER=%-5s KUBE/CNI=%s\n' "$t" \
        "$(sudo iptables-save -t $t 2>/dev/null | grep -c '^-A')" \
        "$(sudo iptables-save -t $t 2>/dev/null | grep -c 'DOCKER')" \
        "$(sudo iptables-save -t $t 2>/dev/null | grep -cE 'KUBE|CNI')"
done
echo "    iptables backend (nft vs legacy — a MISMATCH with k0s silently drops traffic):"
sudo iptables --version 2>/dev/null | sed 's/^/      /'
sudo update-alternatives --display iptables 2>/dev/null | grep -E 'link currently' | head -3 | sed 's/^/      /'

# -----------------------------------------------------------------------------
hdr "6. OUTBOUND — a bundle-joined edge still needs to dial the mgmt node"
# -----------------------------------------------------------------------------
# 'bundle' means no INBOUND path. It does NOT mean air-gapped: the kubelet and
# konnectivity dial out to the management node on 443, permanently.
if [ -n "$MGMT_IP" ]; then
    if timeout 10 bash -c "cat < /dev/null > /dev/tcp/${MGMT_IP}/${MGMT_PORT}" 2>/dev/null; then
        ok "outbound TCP to ${MGMT_IP}:${MGMT_PORT} works"
    else
        bad "CANNOT reach ${MGMT_IP}:${MGMT_PORT} — a bundle-joined edge cannot work without this"
    fi
else
    warn "no MGMT_IP given; re-run as: $0 <mgmt-ip> [port]   to test the outbound path"
fi
for h in ghcr.io registry.k8s.io docker.io; do
    if timeout 8 bash -c "cat < /dev/null > /dev/tcp/${h}/443" 2>/dev/null; then
        ok "egress to ${h}:443"
    else
        warn "no egress to ${h}:443 (image pulls will fail)"
    fi
done

# -----------------------------------------------------------------------------
hdr "7. KERNEL / CGROUP prerequisites"
# -----------------------------------------------------------------------------
echo "    $(uname -srm)   |   $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
CG=$(stat -fc %T /sys/fs/cgroup 2>/dev/null)
echo "    cgroup fs: ${CG}"
if [ "$CG" = "cgroup2fs" ]; then
    ok "cgroup v2"
else
    warn "cgroup v1 — k0s works, but the cgroup driver must match what the moby
         containerd uses or the two fight over slices"
fi
for m in br_netfilter overlay nf_conntrack; do
    if lsmod 2>/dev/null | grep -q "^${m}"; then ok "module ${m} loaded"
    else warn "module ${m} not loaded (k0s loads it at start — note the change)"; fi
done
for s in net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward; do
    printf '    %s = %s\n' "$s" "$(sysctl -n $s 2>/dev/null || echo '(unset)')"
done

# -----------------------------------------------------------------------------
hdr "RESULT"
# -----------------------------------------------------------------------------
{
    echo "preflight baseline — $(hostname -f) — $(date)"
    echo "--- listeners ---";  (sudo ss -tulpnH 2>/dev/null || ss -tulpnH)
    echo "--- routes ---";     ip -4 route
    echo "--- addrs ---";      ip -4 -br addr
    echo "--- iptables-save (filter) ---"; sudo iptables-save -t filter 2>/dev/null
    echo "--- iptables-save (nat) ---";    sudo iptables-save -t nat 2>/dev/null
    echo "--- docker ps ---";  sudo docker ps 2>/dev/null
    echo "--- df ---";         df -hT
} > "$BASELINE" 2>/dev/null
chmod 600 "$BASELINE" 2>/dev/null

echo "  PASS=${PASS}  WARN=${WARN}  FAIL=${FAIL}"
echo "  baseline saved: ${BASELINE}"
echo
if [ "$FAIL" -gt 0 ]; then
    echo "  DO NOT JOIN THIS NODE until every FAIL is resolved."
    exit 1
fi
if [ "$WARN" -gt 0 ]; then
    echo "  No hard blockers, but each WARN is a decision that needs an owner and a"
    echo "  written answer — especially the disk ceiling and microk8s auto-refresh."
    exit 0
fi
echo "  Clear. Keep the baseline and diff it after the join."
