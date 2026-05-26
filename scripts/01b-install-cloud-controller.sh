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
PROVIDER="${CLOUD_PROVIDER:-openstack}"

if [ "${TOPOLOGY}" != "cloud" ]; then
    echo "=== 01b: cloud-controller-manager — SKIPPED (topology=${TOPOLOGY}) ==="
    exit 0
fi

# Managed-K8s providers ship their own CCM. Installing another one would
# fight the platform-managed controller. Skip cleanly.
case "$PROVIDER" in
    aws|gcp|azure)
        echo "=== 01b: cloud-controller-manager — SKIPPED (provider=${PROVIDER} ships its own CCM) ==="
        exit 0
        ;;
    none)
        echo "=== 01b: cloud-controller-manager — SKIPPED (provider=none; bring-your-own LB controller) ==="
        exit 0
        ;;
    openstack)
        : # fall through to the OpenStack install below
        ;;
    *)
        echo "ERROR: unknown CLOUD_PROVIDER='${PROVIDER}' in 01b."
        echo "       Valid values: openstack | aws | gcp | azure | none"
        exit 1
        ;;
esac

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

# Required: LB_SUBNET_ID. OCCM would auto-detect this from the node's
# providerID, but on a self-managed k0s cluster providerID is empty —
# OCCM fails LoadBalancer reconciliation with:
#   "can't determine instance ID from ProviderID when autodetecting LB subnet"
# Set LB_SUBNET_ID in config/management.env to bypass autodetect.
if [ -z "${LB_SUBNET_ID:-}" ]; then
    echo ""
    echo "ERROR: LB_SUBNET_ID is not set in config/management.env." >&2
    echo "       OCCM cannot auto-detect it on a self-managed k0s cluster." >&2
    echo "       Discover the right value with:" >&2
    echo "         openstack server show <mgmt-vm> -f value -c addresses" >&2
    echo "         openstack network show <net> -f value -c subnets" >&2
    exit 1
fi

# Optional: LB_FLOATING_NETWORK_ID. Auto-discover from LB_PUBLIC_IP if blank.
FLOATING_NET="${LB_FLOATING_NETWORK_ID:-}"
if [ -z "$FLOATING_NET" ] && [ -n "${LB_PUBLIC_IP:-}" ]; then
    if command -v openstack >/dev/null 2>&1; then
        FLOATING_NET=$(openstack floating ip show "${LB_PUBLIC_IP}" \
                         -f value -c floating_network_id 2>/dev/null || echo "")
    fi
fi
echo "  LB_SUBNET_ID:         ${LB_SUBNET_ID}"
echo "  LB_FLOATING_NETWORK:  ${FLOATING_NET:-<unknown — OCCM may fail to associate FIP>}"
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
# Explicit subnet/floating-network IDs — OCCM cannot auto-detect them on
# self-managed k0s clusters because the node has no providerID set.
subnet-id=${LB_SUBNET_ID}
EOF
if [ -n "$FLOATING_NET" ]; then
    echo "floating-network-id=${FLOATING_NET}" >> "$TMP_CC"
fi
# Octavia AZ — must match the mgmt VM's AZ, otherwise the amphora boots
# in one region and the backend port is in another, hanging the LB in
# PENDING_CREATE indefinitely (Nectar gotcha).
if [ -n "${LB_AVAILABILITY_ZONE:-}" ]; then
    echo "availability-zone=${LB_AVAILABILITY_ZONE}" >> "$TMP_CC"
    echo "  LB_AVAILABILITY_ZONE: ${LB_AVAILABILITY_ZONE}"
fi

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

# Use a small values file rather than --set flags; controllerExtraArgs is a
# multi-line YAML string and helm --set can't represent it cleanly.
OCCM_VALUES=$(mktemp /tmp/occm-values-XXXXXX.yaml)
cat > "$OCCM_VALUES" <<EOF
secret:
  create: false
  name: openstack-cloud-config
cloudConfig:
  useExistingSecret: true
  existingSecret: openstack-cloud-config
# Run only the LB-service controller. The cloud-node and cloud-node-
# lifecycle controllers expect kubelet's --cloud-provider=external and
# nodes to carry providerID, which we don't set up because we only need LB
# capabilities. The route controller expects Neutron-managed pod CIDRs,
# which we don't use (kube-router does the pod networking).
controllerExtraArgs: |-
  - --controllers=service
# OCCM builds Octavia LB names as
#   kube_service_<cluster-name>_<namespace>_<service-name>
# The default cluster-name is "kubernetes". Override to OCCM_CLUSTER_NAME
# (or fall back to the default) so an operator can force OCCM to create
# fresh LBs by bumping the value when a previous LB is stuck/orphaned in
# Octavia and can't be force-deleted.
cluster:
  name: ${OCCM_CLUSTER_NAME:-kubernetes}
# The upstream chart defaults nodeSelector to
#   node-role.kubernetes.io/control-plane: ""
# (empty-string value) — that matches kubeadm but NOT k0s, which labels
# control-plane nodes with the value "true". Helm merges maps, so passing
# nodeSelector: {} does not override the default — we have to pass an
# explicit replacement. Match k0s's label value here so the DS schedules
# on the mgmt controller node.
nodeSelector:
  node-role.kubernetes.io/control-plane: "true"
tolerations:
  - operator: Exists
EOF

helm upgrade --install openstack-ccm cpo/openstack-cloud-controller-manager \
    --namespace kube-system \
    --values "$OCCM_VALUES" \
    --wait --timeout 300s
rm -f "$OCCM_VALUES"

echo ""
echo "Waiting for cloud-controller-manager pod to be Ready..."
# Chart 2.36.0 labels pods with app=openstack-cloud-controller-manager. The
# selector here matches that — if you bump the chart version and the labels
# change, this wait will need to be updated. Same goes for the nodeSelector
# we set above; if the chart starts honouring nodeSelector:{} (an empty map
# override) we can simplify this.
#
# Note: kubectl rollout status returns success on a DaemonSet with
# desiredNumberScheduled=0, so we have to assert desired > 0 separately
# before waiting — otherwise a label mismatch silently "passes."
desired=$(kubectl -n kube-system get ds openstack-cloud-controller-manager \
            -o jsonpath='{.status.desiredNumberScheduled}')
if [ -z "$desired" ] || [ "$desired" -eq 0 ]; then
    echo "ERROR: DaemonSet desiredNumberScheduled=${desired:-empty}." >&2
    echo "       Likely the chart's nodeSelector doesn't match any node." >&2
    echo "       Check: kubectl get nodes --show-labels" >&2
    exit 1
fi
kubectl -n kube-system rollout status ds/openstack-cloud-controller-manager --timeout=180s
kubectl -n kube-system wait --for=condition=Ready pod \
    -l app=openstack-cloud-controller-manager --timeout=120s

echo ""
echo "=== 01b: Complete ==="
echo "  OCCM is watching for LoadBalancer Services."
echo "  Step 02c will create one; the LB controller will provision an Octavia LB"
echo "  and associate floating IP ${LB_PUBLIC_IP:-<set LB_PUBLIC_IP first>}."
