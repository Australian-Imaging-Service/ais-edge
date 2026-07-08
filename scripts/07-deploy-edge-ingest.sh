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

# Sort's hardlink target. Other edge data dirs (orthanc-storage,
# facility-backup) are created by 07c-deploy-edge-orthanc.sh.
ssh ${SSH_KEY_OPT} "${EDGE_SSH}" \
    "sudo mkdir -p /data/xnat-ingest/grouped /data/xnat-ingest/staging && sudo chmod 777 /data/xnat-ingest/grouped /data/xnat-ingest/staging"
echo "Data directories ready on ${NODE_IP}"

# Phase 2: ensure namespace exists and push the CA bundle as a Secret. The
# s3-uploader pod mounts this so mc can verify the seaweedfs-tls server cert
# (issued by ais-edge-ca-issuer).
KUBECONFIG="$EDGE_KC" kubectl create namespace xnat-ingest --dry-run=client -o yaml \
    | KUBECONFIG="$EDGE_KC" kubectl apply -f -

if [ -f "${REPO_DIR}/ais-edge-ca.crt" ]; then
    KUBECONFIG="$EDGE_KC" kubectl create secret generic ca-bundle \
        --namespace xnat-ingest \
        --from-file=ca.crt="${REPO_DIR}/ais-edge-ca.crt" \
        --dry-run=client -o yaml \
        | KUBECONFIG="$EDGE_KC" kubectl apply -f -
    echo "CA bundle Secret pushed to edge cluster"
else
    echo "WARNING: ais-edge-ca.crt not found at ${REPO_DIR} — run 02b-bootstrap-ca.sh first."
    echo "         Phase 2 TLS path will fail until the CA bundle is in place."
fi

# Deploy manifests — render_with_topology strips the {{#ONPREM_ONLY}}
# hostAliases block when INSTALL_TOPOLOGY=cloud, leaving the pod with
# normal DNS resolution.
render_with_topology "${REPO_DIR}/manifests/02-edge/xnat-ingest.yaml.tpl" \
    CLUSTER_NAME "$CLUSTER_NAME" \
    S3_EDGE_ACCESS_KEY "$EDGE_ACCESS_KEY" \
    S3_EDGE_SECRET_KEY "$EDGE_SECRET_KEY" \
    PROJECT_ID "$PROJECT_ID" \
    INGEST_LOOP_SECONDS "$INGEST_LOOP_SECONDS" \
    INGEST_WAIT_PERIOD "$INGEST_WAIT_PERIOD" \
    S3_BUCKET "$S3_BUCKET" \
    MGMT_NODE_IP "${MGMT_NODE_IP:-}" \
    SEAWEEDFS_HOSTNAME "$SEAWEEDFS_HOSTNAME" \
    K0S_API_HOSTNAME "$K0S_API_HOSTNAME" \
    KONNECTIVITY_HOSTNAME "$KONNECTIVITY_HOSTNAME" \
    LOKI_HOSTNAME "${LOKI_HOSTNAME:-loki.aisedge.local}" \
    GRAFANA_HOSTNAME "${GRAFANA_HOSTNAME:-grafana.aisedge.local}" \
    INGRESS_PORT "$INGRESS_PORT" \
    XNAT_INGEST_IMAGE "${XNAT_INGEST_IMAGE:-ghcr.io/australian-imaging-service/xnat-ingest:latest}" \
    | KUBECONFIG="$EDGE_KC" kubectl apply -f -

echo "Waiting for pods..."
sleep 30
KUBECONFIG="$EDGE_KC" kubectl get pods -n xnat-ingest -o wide

# Verify the TLS path from the edge VM. Phase 2 has no HTTP fallback —
# only :443 is exposed. Expect HTTP 403 (S3 unauthenticated GET on /).
echo "Verifying TLS path from edge VM..."
if [ -f "${REPO_DIR}/ais-edge-ca.crt" ]; then
    scp -q ${SSH_KEY_OPT} "${REPO_DIR}/ais-edge-ca.crt" "${EDGE_SSH}:/tmp/ais-edge-ca.crt"
    TLS_HTTP=$(ssh ${SSH_KEY_OPT} "${EDGE_SSH}" \
        "curl -s -o /dev/null -w '%{http_code}' --cacert /tmp/ais-edge-ca.crt https://${SEAWEEDFS_HOSTNAME}/" \
        || echo "000")
    ssh ${SSH_KEY_OPT} "${EDGE_SSH}" "rm -f /tmp/ais-edge-ca.crt"
    echo "SeaweedFS HTTPS (Ingress :${INGRESS_PORT}) from edge: HTTP ${TLS_HTTP:-000}  (expect 403)"
fi

echo "=== 07: Complete for ${CLUSTER_NAME} ==="
echo "Pipeline: group-orthanc (REST-pull) -> assign -> s3-uploader -> SeaweedFS."
echo "Push test DICOMs via C-STORE to AET=AISEDGE ${NODE_IP}:4242 (see step 07c output)."
