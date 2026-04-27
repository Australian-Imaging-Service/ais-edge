#!/usr/bin/env bash
# =============================================================================
# Step 05: Create hosted k0s control plane for an edge site
#          Usage: ./05-setup-edge-cluster.sh <edge-entry>
#          Called by install.sh for each edge node, or run manually.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <edge-entry>"
    echo "  edge-entry format: CLUSTER_NAME|NODE_IP|SSH_USER|SSH_KEY|PROJECT_ID|ACCESS_KEY|SECRET_KEY"
    exit 1
fi

parse_edge_entry "$1"

echo "=== 05: Creating hosted cluster '${CLUSTER_NAME}' ==="

# Create namespace and cluster
kubectl create namespace "${CLUSTER_NAME}" --dry-run=client -o yaml | kubectl apply -f -
render "${REPO_DIR}/manifests/01-management/edge-cluster.yaml.tpl" \
    CLUSTER_NAME "$CLUSTER_NAME" \
    | kubectl apply -f -

# Wait for control plane
echo "Waiting for control plane pods (may take 2-3 min first time)..."
RETRIES=36
for i in $(seq 1 $RETRIES); do
    READY=$(kubectl get pods -n "${CLUSTER_NAME}" --no-headers 2>/dev/null | grep "1/1" | wc -l)
    [ "$READY" -ge 2 ] && { echo "Control plane ready!"; break; }
    [ $i -eq $RETRIES ] && { echo "ERROR: Control plane not ready"; kubectl get pods -n "${CLUSTER_NAME}"; exit 1; }
    echo "  Attempt $i/$RETRIES..."
    sleep 10
done

# Extract kubeconfig
kubectl get secret "${CLUSTER_NAME}-kubeconfig" -n "${CLUSTER_NAME}" \
    -o jsonpath='{.data.value}' | base64 -d > "${EDGE_KC}"
chmod 600 "${EDGE_KC}"
SVC_NAME=$(kubectl get svc -n "${CLUSTER_NAME}" --no-headers | grep -i nodeport | awk '{print $1}')
API_PORT=$(kubectl get svc "${SVC_NAME}" -n "${CLUSTER_NAME}" -o jsonpath='{.spec.ports[0].nodePort}')
sed -i "s|server:.*|server: https://${MGMT_NODE_IP}:${API_PORT}|" "${EDGE_KC}"
echo "Kubeconfig: kubeconfig-${CLUSTER_NAME}"

# Generate join token
kubectl delete jointokenrequest "${CLUSTER_NAME}-token" -n "${CLUSTER_NAME}" --ignore-not-found 2>/dev/null
kubectl delete secret "${CLUSTER_NAME}-token" -n "${CLUSTER_NAME}" --ignore-not-found 2>/dev/null
sleep 2
cat <<EOF | kubectl apply -f -
apiVersion: k0smotron.io/v1beta1
kind: JoinTokenRequest
metadata:
  name: ${CLUSTER_NAME}-token
  namespace: ${CLUSTER_NAME}
spec:
  clusterRef:
    name: ${CLUSTER_NAME}
    namespace: ${CLUSTER_NAME}
EOF

RETRIES=12
for i in $(seq 1 $RETRIES); do
    TOKEN=$(kubectl get secret "${CLUSTER_NAME}-token" -n "${CLUSTER_NAME}" \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    [ -n "$TOKEN" ] && break
    [ $i -eq $RETRIES ] && { echo "ERROR: Token not generated"; exit 1; }
    echo "  Waiting for token... ($i/$RETRIES)"
    sleep 5
done
echo "$TOKEN" > "${REPO_DIR}/join-token-${CLUSTER_NAME}"
chmod 600 "${REPO_DIR}/join-token-${CLUSTER_NAME}"
echo "Join token saved"

# Note: SeaweedFS S3 identities for edge users are provisioned by step 03
# (the s3.json ConfigMap is built from edge-nodes.env at install time).
# No per-edge step here — credentials defined in edge-nodes.env are already
# active in SeaweedFS by the time we reach this step.

echo "=== 05: Complete for ${CLUSTER_NAME} ==="
