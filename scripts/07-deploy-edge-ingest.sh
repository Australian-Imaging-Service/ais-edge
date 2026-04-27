#!/usr/bin/env bash
# =============================================================================
# Step 07: Deploy xnat-ingest pods on the edge cluster
#          Usage: ./07-deploy-edge-ingest.sh <edge-entry>
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <edge-entry>"
    exit 1
fi

parse_edge_entry "$1"

echo "=== 07: Deploying xnat-ingest on ${CLUSTER_NAME} ==="

# Create directories on edge
ssh ${SSH_KEY_OPT} "${EDGE_SSH}" \
    "sudo mkdir -p /data/xnat-ingest/incoming /data/xnat-ingest/staging && \
     sudo chmod 777 /data/xnat-ingest/incoming /data/xnat-ingest/staging"
echo "Data directories ready on ${NODE_IP}"

# Deploy manifests
render "${REPO_DIR}/manifests/02-edge/xnat-ingest.yaml.tpl" \
    S3_EDGE_ACCESS_KEY "$EDGE_ACCESS_KEY" \
    S3_EDGE_SECRET_KEY "$EDGE_SECRET_KEY" \
    PROJECT_ID "$PROJECT_ID" \
    INGEST_LOOP_SECONDS "$INGEST_LOOP_SECONDS" \
    INGEST_WAIT_PERIOD "$INGEST_WAIT_PERIOD" \
    S3_BUCKET "$S3_BUCKET" \
    MGMT_NODE_IP "$MGMT_NODE_IP" \
    S3_NODEPORT "$S3_NODEPORT" \
    | KUBECONFIG="$EDGE_KC" kubectl apply -f -

echo "Waiting for pods..."
sleep 30
KUBECONFIG="$EDGE_KC" kubectl get pods -n xnat-ingest -o wide

# Test SeaweedFS reachability from edge
echo "Testing SeaweedFS from edge..."
SHTTP=$(ssh ${SSH_KEY_OPT} "${EDGE_SSH}" \
    "curl -s -o /dev/null -w '%{http_code}' http://${MGMT_NODE_IP}:${S3_NODEPORT}/" || echo "000")
echo "SeaweedFS S3 endpoint from edge: HTTP ${SHTTP}"

echo "=== 07: Complete for ${CLUSTER_NAME} ==="
echo "Test: scp file.dcm ${EDGE_SSH}:/data/xnat-ingest/incoming/"
