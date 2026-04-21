#!/usr/bin/env bash
# =============================================================================
# Uninstall everything — management cluster, edge workers, MinIO, k0smotron
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/config/management.env"
source "${SCRIPT_DIR}/config/edge-nodes.env"

echo "============================================"
echo "WARNING: This will destroy EVERYTHING:"
echo "  - All edge workers and their data"
echo "  - MinIO and all stored files"
echo "  - k0smotron and all hosted clusters"
echo "  - k0s controller (if fresh install)"
echo "============================================"
read -p "Are you sure? (y/N) " -r
[[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# --- Remove edge workers ---
for entry in "${EDGE_NODES[@]}"; do
    IFS='|' read -r CLUSTER_NAME NODE_IP SSH_USER SSH_KEY _ _ _ <<< "$entry"
    SSH_KEY_OPT=""
    [ -n "${SSH_KEY}" ] && SSH_KEY_OPT="-i ${SSH_KEY}"
    EDGE_SSH="${SSH_USER}@${NODE_IP}"

    echo ""
    echo "=== Removing edge: ${CLUSTER_NAME} (${NODE_IP}) ==="
    ssh ${SSH_KEY_OPT} "${EDGE_SSH}" bash -s <<'EOF' 2>/dev/null || echo "  (skipped)"
sudo k0s stop 2>/dev/null || true
sudo k0s reset 2>/dev/null || true
sudo rm -rf /data/xnat-ingest 2>/dev/null || true
EOF

    kubectl delete namespace "${CLUSTER_NAME}" --ignore-not-found 2>/dev/null || true
    rm -f "${SCRIPT_DIR}/kubeconfig-${CLUSTER_NAME}" "${SCRIPT_DIR}/join-token-${CLUSTER_NAME}"
done

# --- Remove management workloads ---
echo ""
echo "=== Removing MinIO and XNAT upload ==="
kubectl delete namespace xnat-upload --ignore-not-found 2>/dev/null || true
kubectl delete namespace minio --ignore-not-found 2>/dev/null || true
sudo rm -rf /data/minio

echo ""
echo "=== Removing k0smotron ==="
kubectl delete -f https://docs.k0smotron.io/stable/install.yaml --ignore-not-found 2>/dev/null || true

echo ""
echo "=== Removing cert-manager ==="
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml --ignore-not-found 2>/dev/null || true

echo ""
echo "=== Removing local-path-provisioner ==="
kubectl delete -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml --ignore-not-found 2>/dev/null || true

if [ "${INSTALL_MODE}" = "fresh" ]; then
    echo ""
    echo "=== Stopping k0s ==="
    sudo k0s stop 2>/dev/null || true
    sudo k0s reset 2>/dev/null || true
    rm -f ~/.kube/config
fi

echo ""
echo "=== Uninstall complete ==="
