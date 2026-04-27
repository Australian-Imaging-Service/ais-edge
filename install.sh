#!/usr/bin/env bash
# =============================================================================
# k0s + k0smotron + SeaweedFS Edge Setup — Interactive Installer
# =============================================================================
# Calls each script in order. Only edit config files — never edit scripts.
#
# Config files:
#   config/management.env   — Management node, SeaweedFS, XNAT settings
#   config/edge-nodes.env   — Edge node list (supports multiple sites)
#
# Usage:
#   cp config/management.env.template config/management.env
#   cp config/edge-nodes.env.template config/edge-nodes.env
#   vim config/management.env config/edge-nodes.env
#   ./install.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/00-common.sh"

# --- Validate required config ---
for var in MGMT_NODE_IP XNAT_URL XNAT_USER XNAT_PASS \
           S3_ADMIN_ACCESS_KEY S3_ADMIN_SECRET_KEY S3_BUCKET S3_NODEPORT; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: ${var} is not set in config/management.env"
        exit 1
    fi
done
if [ ${#EDGE_NODES[@]} -eq 0 ]; then
    echo "ERROR: No edge nodes defined in config/edge-nodes.env"
    exit 1
fi

# --- Show plan ---
echo ""
echo "============================================"
echo " k0s + k0smotron + SeaweedFS Edge Setup"
echo "============================================"
echo ""
echo " Management node:    ${MGMT_NODE_IP}"
echo " Install mode:       ${INSTALL_MODE}"
echo " SeaweedFS S3 port:  ${S3_NODEPORT}"
echo " SeaweedFS master:   ${MASTER_NODEPORT}"
echo " SeaweedFS filer:    ${FILER_NODEPORT}"
echo " XNAT target:        ${XNAT_URL}"
echo ""
echo " Edge nodes (${#EDGE_NODES[@]}):"
for entry in "${EDGE_NODES[@]}"; do
    IFS='|' read -r name ip _ _ project _ _ <<< "$entry"
    echo "   - ${name} → ${ip} (project: ${project})"
done
echo ""
echo " Steps:"
echo "   01. Install k0s management cluster (or use existing)"
echo "   02. Install cert-manager + k0smotron operator"
echo "   03. Deploy SeaweedFS (S3 storage)"
echo "   04. Deploy XNAT upload pod (SeaweedFS → XNAT)"
echo "   For each edge node:"
echo "     05. Create hosted k0s control plane"
echo "     06. Install k0s worker on edge VM"
echo "     07. Deploy xnat-ingest (sort + s3-uploader)"
echo ""
echo "============================================"
read -p "Proceed with installation? (y/N) " -r
[[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ============================================================================
echo ""
echo "========================================"
echo " Phase 1: Management Cluster"
echo "========================================"

echo ""
echo "--- Step 01: k0s management cluster ---"
read -p "Run step 01? (y/s to skip) " -r
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/01-install-k0s.sh"

echo ""
echo "--- Step 02: cert-manager + k0smotron ---"
read -p "Run step 02? (y/s to skip) " -r
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/02-install-k0smotron.sh"

echo ""
echo "--- Step 03: SeaweedFS ---"
read -p "Run step 03? (y/s to skip) " -r
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/03-deploy-seaweedfs.sh"

echo ""
echo "--- Step 04: XNAT upload pod ---"
read -p "Run step 04? (y/s to skip) " -r
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/04-deploy-xnat-upload.sh"

# ============================================================================
echo ""
echo "========================================"
echo " Phase 2 & 3: Edge Nodes"
echo "========================================"

for entry in "${EDGE_NODES[@]}"; do
    IFS='|' read -r name ip _ _ project _ _ <<< "$entry"
    echo ""
    echo "========================================"
    echo " Edge: ${name} (${ip}) → project: ${project}"
    echo "========================================"

    echo ""
    echo "--- Step 05: Create hosted cluster '${name}' ---"
    read -p "Run step 05 for ${name}? (y/s to skip) " -r
    [[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/05-setup-edge-cluster.sh" "$entry"

    echo ""
    echo "--- Step 06: Install k0s worker on ${ip} ---"
    read -p "Run step 06 for ${name}? (y/s to skip) " -r
    [[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/06-join-edge-worker.sh" "$entry"

    echo ""
    echo "--- Step 07: Deploy xnat-ingest on ${name} ---"
    read -p "Run step 07 for ${name}? (y/s to skip) " -r
    [[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/07-deploy-edge-ingest.sh" "$entry"
done

# ============================================================================
echo ""
echo "============================================"
echo " Installation Complete!"
echo "============================================"
echo ""
echo " Management cluster:    kubectl get pods -A"
echo " SeaweedFS S3 API:      http://${MGMT_NODE_IP}:${S3_NODEPORT}"
echo " SeaweedFS master UI:   http://${MGMT_NODE_IP}:${MASTER_NODEPORT}"
echo " SeaweedFS filer UI:    http://${MGMT_NODE_IP}:${FILER_NODEPORT}"
echo "                        (admin key: ${S3_ADMIN_ACCESS_KEY})"
echo ""
for entry in "${EDGE_NODES[@]}"; do
    IFS='|' read -r name ip _ _ _ _ _ <<< "$entry"
    echo " Edge '${name}' (${ip}):"
    echo "   Nodes:   kubectl --kubeconfig kubeconfig-${name} get nodes"
    echo "   Pods:    kubectl --kubeconfig kubeconfig-${name} get pods -n xnat-ingest"
    echo "   Sort:    kubectl --kubeconfig kubeconfig-${name} logs -n xnat-ingest -l component=sort -f"
    echo "   Upload:  kubectl --kubeconfig kubeconfig-${name} logs -n xnat-ingest -l component=s3-uploader -f"
    echo "   Test:    scp file.dcm ${ip}:/data/xnat-ingest/incoming/"
    echo ""
done
echo " XNAT upload (mgmt): kubectl logs -n xnat-upload -l component=upload -f"
echo ""
