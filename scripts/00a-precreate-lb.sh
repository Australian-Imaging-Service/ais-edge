#!/usr/bin/env bash
# =============================================================================
# Step 00a: Pre-create the Octavia LB so install.sh can run uninterrupted
#           on Nectar / OpenStack shared-public-network topologies.
# =============================================================================
# Why this step exists:
#
# On Nectar QLD (and similar OpenStack deployments where tenant VMs sit
# directly on a shared external network), the LB and the mgmt VM both
# live on the qld network. There is no router between qld and itself,
# so Neutron refuses to associate a pre-allocated floating IP from qld
# back to a port on qld — `ExternalGatewayForFloatingIPNotFound`.
#
# That means we can't pre-pin LB_PUBLIC_IP via a FIP. Octavia auto-
# assigns a VIP from the qld pool when the LB is created — and only
# then do we know our public IP.
#
# But step 02b creates server certs with hostnames derived from
# INTERNAL_DOMAIN, which is derived from the LB IP. So we need to know
# the IP BEFORE 02b runs.
#
# The fix: pre-create the LB ourselves via the openstack CLI in this
# step (which runs before 01b/02/02b/02c), capture its VIP, and write
# INTERNAL_DOMAIN + LB_PUBLIC_IP back into config/management.env. When
# step 02c later helm-installs nginx-ingress with Service
# type=LoadBalancer, OCCM finds the existing LB by name (cluster name
# + namespace + service name) and CLAIMS it instead of creating a new
# one. install.sh runs uninterrupted in a single invocation.
#
# Only runs when:
#   INSTALL_TOPOLOGY=cloud
#   CLOUD_PROVIDER=openstack
#   PRECREATE_LB=1                 (opt-in; default off — managed K8s
#                                   like EKS/GKE/AKS don't need this)
#   AND LB_PUBLIC_IP is empty in management.env (i.e. we don't have a
#                                                pre-pinned IP)
#
# Skips silently otherwise. NOOP on AWS / GCP / Azure / managed K8s.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

TOPOLOGY="${INSTALL_TOPOLOGY:-onprem}"
PROVIDER="${CLOUD_PROVIDER:-openstack}"
PRECREATE="${PRECREATE_LB:-0}"

if [ "${TOPOLOGY}" != "cloud" ] || [ "${PROVIDER}" != "openstack" ] || [ "${PRECREATE}" != "1" ]; then
    echo "=== 00a: pre-create LB — SKIPPED (topology=${TOPOLOGY} provider=${PROVIDER} precreate=${PRECREATE}) ==="
    exit 0
fi

if [ -n "${LB_PUBLIC_IP:-}" ]; then
    echo "=== 00a: pre-create LB — SKIPPED (LB_PUBLIC_IP=${LB_PUBLIC_IP} already pinned) ==="
    exit 0
fi

# Sanity-check required inputs.
for v in OS_AUTH_URL OS_REGION_NAME LB_SUBNET_ID LB_AVAILABILITY_ZONE; do
    if [ -z "${!v:-}" ]; then
        echo "ERROR: ${v} not set. Cannot pre-create LB." >&2
        echo "       Required in config/management.env (or sourced openrc.sh)." >&2
        exit 1
    fi
done
# Need EITHER application-credential OR username/password auth.
if [ -z "${OS_APPLICATION_CREDENTIAL_ID:-}" ] && [ -z "${OS_USERNAME:-}" ]; then
    echo "ERROR: Neither OS_APPLICATION_CREDENTIAL_ID nor OS_USERNAME is set." >&2
    exit 1
fi

echo "=== 00a: Pre-creating Octavia LB on ${LB_SUBNET_ID} in AZ ${LB_AVAILABILITY_ZONE} ==="

# OCCM names LBs as: kube_service_<cluster-name>_<namespace>_<service-name>
# Match that exact name here so OCCM finds and claims it at step 02c.
CLUSTER_NAME="${OCCM_CLUSTER_NAME:-kubernetes}"
LB_NAME="kube_service_${CLUSTER_NAME}_ingress-nginx_ingress-nginx-controller"

# Reuse an existing LB if one already has this name + is ACTIVE — this
# keeps step 00a idempotent across install.sh re-runs.
EXISTING=$(openstack loadbalancer list -c id -c name -c provisioning_status \
            -f value 2>/dev/null \
            | awk -v n="$LB_NAME" '$2==n && $3=="ACTIVE" {print $1; exit}')

if [ -n "$EXISTING" ]; then
    echo "  Found existing ACTIVE LB '$LB_NAME' (id=$EXISTING) — reusing"
    LB_ID="$EXISTING"
else
    echo "  Creating LB '$LB_NAME'..."
    LB_ID=$(openstack loadbalancer create \
              --name "$LB_NAME" \
              --vip-subnet-id "$LB_SUBNET_ID" \
              --availability-zone "$LB_AVAILABILITY_ZONE" \
              -f value -c id 2>&1) \
        || { echo "ERROR: openstack loadbalancer create failed:" >&2; echo "$LB_ID" >&2; exit 1; }
    echo "  LB id: $LB_ID"
    echo "  Polling for ACTIVE status (Nectar amphora boot can take 3-7 minutes)..."
    END=$((SECONDS+600))
    while [ $SECONDS -lt $END ]; do
        STATUS=$(openstack loadbalancer show "$LB_ID" -f value -c provisioning_status 2>/dev/null)
        echo "    [t=${SECONDS}s] $STATUS"
        case "$STATUS" in
            ACTIVE) break ;;
            ERROR)  echo "ERROR: LB went to ERROR state." >&2; exit 1 ;;
        esac
        sleep 20
    done
    if [ "$STATUS" != "ACTIVE" ]; then
        echo "ERROR: LB did not reach ACTIVE within 10 minutes (last status: $STATUS)." >&2
        exit 1
    fi
fi

# Capture the assigned VIP — this IS our public IP.
VIP=$(openstack loadbalancer show "$LB_ID" -f value -c vip_address 2>/dev/null)
echo "  LB VIP (public): $VIP"

# Derive nip.io hostname pattern from VIP (dot-separated → dash-separated).
VIP_DASHED=$(echo "$VIP" | tr '.' '-')
DERIVED_DOMAIN="dev-nectar-test.${VIP_DASHED}.nip.io"

# Write back into config/management.env so subsequent steps + later
# install.sh invocations pick up the new values automatically.
ENV_FILE="${REPO_DIR}/config/management.env"
# Each sed-i targets a single line so a previous value (or a sentinel)
# gets replaced. We tolerate either single- or double-quoted form.
sed -i -E "s|^export LB_PUBLIC_IP=.*$|export LB_PUBLIC_IP=\"${VIP}\"|" "$ENV_FILE"
sed -i -E "s|^export INTERNAL_DOMAIN=.*$|export INTERNAL_DOMAIN=\"${DERIVED_DOMAIN}\"|" "$ENV_FILE"

echo ""
echo "  Written back to config/management.env:"
echo "    LB_PUBLIC_IP=${VIP}"
echo "    INTERNAL_DOMAIN=${DERIVED_DOMAIN}"
echo "    (SEAWEEDFS_HOSTNAME, K0S_API_HOSTNAME, etc. all derive from INTERNAL_DOMAIN)"
echo ""
echo "=== 00a: Complete ==="
echo "  OCCM at step 02c will claim this LB by name and add listeners + pools."
