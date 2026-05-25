#!/usr/bin/env bash
# =============================================================================
# Step 07b: Deploy Vector log shipper on the edge child cluster
#          Usage: ./07b-deploy-edge-observability.sh <edge-entry>
# =============================================================================
# Pushes the per-edge Loki bearer-token Secret + the ais-edge-ca bundle
# Secret into the edge cluster, then applies the Vector DaemonSet
# manifest. Vector tails /var/log/pods/, parses JSON, and ships everything
# to https://${LOKI_HOSTNAME} on the management node — same single-port
# 443 path as the rest of the data plane.
#
# Skips cleanly if the observability stack wasn't installed (i.e.
# ALERT_EMAIL_TO unset) — the edge keeps working without log shipping.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <edge-entry>"
    exit 1
fi

parse_edge_entry "$1"

if [ -z "${ALERT_EMAIL_TO:-}" ]; then
    echo "=== 07b: edge observability — SKIPPED (observability stack not installed) ==="
    exit 0
fi

if [ ! -f "${EDGE_KC}" ]; then
    echo "ERROR: kubeconfig ${EDGE_KC} not found — run step 05 first"
    exit 1
fi

echo "=== 07b: Deploying edge observability for ${CLUSTER_NAME} ==="

# 1. Ensure the logging namespace exists
KUBECONFIG="$EDGE_KC" kubectl create namespace logging --dry-run=client -o yaml \
    | KUBECONFIG="$EDGE_KC" kubectl apply -f -

# 2. Push the per-edge Loki bearer token from mgmt → edge
TOKEN=$(kubectl get secret "loki-push-token-${CLUSTER_NAME}" -n observability \
    -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
if [ -z "$TOKEN" ]; then
    echo "ERROR: loki-push-token-${CLUSTER_NAME} not found in observability ns on mgmt"
    echo "Run scripts/02d-install-observability.sh first."
    exit 1
fi
KUBECONFIG="$EDGE_KC" kubectl create secret generic loki-push-credentials \
    --namespace logging \
    --from-literal=token="$TOKEN" \
    --dry-run=client -o yaml \
    | KUBECONFIG="$EDGE_KC" kubectl apply -f -

# 3. Push the ais-edge-ca bundle (Vector verifies the Loki server cert
# against this — same CA that signs seaweedfs-tls).
if [ -f "${REPO_DIR}/ais-edge-ca.crt" ]; then
    KUBECONFIG="$EDGE_KC" kubectl create secret generic ca-bundle \
        --namespace logging \
        --from-file=ca.crt="${REPO_DIR}/ais-edge-ca.crt" \
        --dry-run=client -o yaml \
        | KUBECONFIG="$EDGE_KC" kubectl apply -f -
else
    echo "WARNING: ais-edge-ca.crt not found at ${REPO_DIR}; Vector TLS will fail"
fi

# 4. Apply the Vector DaemonSet manifest — render_with_topology drops the
#    {{#ONPREM_ONLY}} hostAliases block in cloud mode.
render_with_topology "${REPO_DIR}/manifests/02-edge/vector.yaml.tpl" \
    CLUSTER_NAME           "$CLUSTER_NAME" \
    MGMT_NODE_IP           "${MGMT_NODE_IP:-}" \
    SEAWEEDFS_HOSTNAME     "$SEAWEEDFS_HOSTNAME" \
    K0S_API_HOSTNAME       "$K0S_API_HOSTNAME" \
    KONNECTIVITY_HOSTNAME  "$KONNECTIVITY_HOSTNAME" \
    LOKI_HOSTNAME          "$LOKI_HOSTNAME" \
    GRAFANA_HOSTNAME       "$GRAFANA_HOSTNAME" \
    | KUBECONFIG="$EDGE_KC" kubectl apply -f -

echo "Waiting for Vector DaemonSet rollout..."
KUBECONFIG="$EDGE_KC" kubectl rollout status daemonset/vector -n logging --timeout=180s || \
    echo "WARNING: Vector rollout did not complete in 180s — check 'kubectl logs -n logging -l app.kubernetes.io/name=vector'"

echo "=== 07b: Complete for ${CLUSTER_NAME} ==="
echo "Open Grafana → Explore → Loki → {cluster=\"${CLUSTER_NAME}\"} to verify logs are flowing"
