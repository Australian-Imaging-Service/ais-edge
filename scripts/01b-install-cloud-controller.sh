#!/usr/bin/env bash
# =============================================================================
# Step 01b: Install OpenStack cloud-controller-manager (cloud topology only)
# =============================================================================
# Only runs when INSTALL_TOPOLOGY=cloud AND the operator's OpenStack
# environment is loaded (OS_AUTH_URL etc). Skips cleanly otherwise.
#
# What this does:
#   * Build a cloud.conf from the sourced OpenStack env (typically from a
#     Nectar app-cred-*-openrc.sh) and apply it as Secret
#     `openstack-cloud-config` in kube-system.
#   * Install the cloud-provider-openstack helm chart, configured to run
#     ONLY the loadbalancer controller (we don't need node-, route-, or
#     volume-controllers for our setup — local-path-provisioner handles
#     storage and we don't use cluster-aware volumes).
#
# Why we need this:
#   * Step 02c sets nginx-ingress Service type=LoadBalancer when topology=cloud.
#   * Without a cloud-controller-manager that knows how to talk to Octavia,
#     that Service stays Pending forever. The LB controller in OCCM watches
#     LoadBalancer Services and provisions an Octavia LB + associates the
#     floating IP specified in service.spec.loadBalancerIP.
#
# Why this is a separate step (not bundled into 01-install-k0s.sh):
#   * Keeps the on-prem install path completely unchanged.
#   * Allows the operator to swap OCCM for an alternative (e.g. MetalLB) by
#     pointing this step at a different installer — the rest of the pipeline
#     stays identical.
#
# On EKS / AKS / GKE / Magnum this step is a NO-OP — the managed control
# plane already ships its own cloud-controller-manager.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

TOPOLOGY="${INSTALL_TOPOLOGY:-onprem}"

if [ "${TOPOLOGY}" != "cloud" ]; then
    echo "=== 01b: cloud-controller-manager — SKIPPED (topology=${TOPOLOGY}) ==="
    exit 0
fi

# Required OpenStack credentials (sourced from the operator's openrc.sh).
for var in OS_AUTH_URL OS_REGION_NAME \
           OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: ${var} not set in environment."
        echo "  Run: source /path/to/openrc.sh   before launching install.sh -y"
        exit 1
    fi
done

echo "=== 01b: Installing OpenStack cloud-controller-manager ==="
echo "  auth-url:    ${OS_AUTH_URL}"
echo "  region:      ${OS_REGION_NAME}"
echo "  cred-id:     ${OS_APPLICATION_CREDENTIAL_ID:0:8}... (truncated)"
echo "  LB_PUBLIC_IP that 02c will request: ${LB_PUBLIC_IP:-<not set yet>}"
echo ""

# Build cloud.conf — application credential auth, Octavia for LB.
TMP_CC=$(mktemp /tmp/cloud.conf-XXXXXX)
trap "rm -f $TMP_CC" EXIT
cat > "$TMP_CC" <<EOF
[Global]
auth-url=${OS_AUTH_URL}
region=${OS_REGION_NAME}
application-credential-id=${OS_APPLICATION_CREDENTIAL_ID}
application-credential-secret=${OS_APPLICATION_CREDENTIAL_SECRET}

[LoadBalancer]
use-octavia=true
# Let Octavia pick the LB algorithm. ROUND_ROBIN is fine for our SNI-passthrough
# workload — there are 2 ingress-nginx replicas and they're functionally equivalent.
lb-method=ROUND_ROBIN
# Floating networks: when a Service requests a loadBalancerIP that's already
# allocated as a floating IP, OCCM associates it instead of allocating a new one.
# Leaving floating-network-id unset lets it auto-detect from the LB_PUBLIC_IP.
EOF

# Apply as Secret in kube-system. The OCCM helm chart points to this Secret
# via cloudConfig.useExistingSecret.
kubectl create secret generic openstack-cloud-config \
    --namespace kube-system \
    --from-file=cloud.conf="$TMP_CC" \
    --dry-run=client -o yaml | kubectl apply -f -

# Install the helm chart. We disable all controllers except the LB one — node-
# and route-controllers expect the kubelet to be running with
# --cloud-provider=external and the node to carry a providerID, which we
# don't bother to set up because we only want LB capabilities.
helm repo add cpo https://kubernetes.github.io/cloud-provider-openstack >/dev/null 2>&1 || true
helm repo update cpo >/dev/null

helm upgrade --install openstack-ccm cpo/openstack-cloud-controller-manager \
    --namespace kube-system \
    --set "secret.create=false" \
    --set "secret.name=openstack-cloud-config" \
    --set "cloudConfig.useExistingSecret=true" \
    --set "cloudConfig.existingSecret=openstack-cloud-config" \
    --set "controllerExtraArgs={--controllers=cloud-node-lifecycle\,service\,-route}" \
    --set 'tolerations[0].operator=Exists' \
    --wait --timeout 300s

echo ""
echo "Waiting for cloud-controller-manager pod to be Ready..."
kubectl -n kube-system wait --for=condition=Ready pod \
    -l component=cloud-controller-manager --timeout=120s 2>/dev/null \
  || kubectl -n kube-system wait --for=condition=Ready pod \
       -l app.kubernetes.io/name=openstack-cloud-controller-manager --timeout=120s

echo ""
echo "=== 01b: Complete ==="
echo "  OCCM is watching for LoadBalancer Services."
echo "  Step 02c will create one; the LB controller will provision an Octavia LB"
echo "  and associate floating IP ${LB_PUBLIC_IP:-<set LB_PUBLIC_IP first>}."
