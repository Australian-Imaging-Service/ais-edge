#!/usr/bin/env bash
# =============================================================================
# Step 03: Deploy MinIO on the management cluster
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

echo "=== 03: Deploying MinIO ==="

sudo mkdir -p /data/minio
render "${REPO_DIR}/manifests/01-management/minio.yaml.tpl" \
    MINIO_ROOT_USER "$MINIO_ROOT_USER" \
    MINIO_ROOT_PASSWORD "$MINIO_ROOT_PASSWORD" \
    MINIO_NODEPORT "$MINIO_NODEPORT" \
    MINIO_CONSOLE_NODEPORT "$MINIO_CONSOLE_NODEPORT" \
    | kubectl apply -f -

echo "Waiting for MinIO pod..."
kubectl wait --for=condition=Ready pods -l app=minio -n minio --timeout=180s
echo "MinIO ready: http://${MGMT_NODE_IP}:${MINIO_CONSOLE_NODEPORT}"

# Install mc (MinIO client)
if ! command -v mc &>/dev/null; then
    curl -sL https://dl.min.io/client/mc/release/linux-amd64/mc -o /tmp/mc
    sudo install -o root -g root -m 0755 /tmp/mc /usr/local/bin/mc && rm -f /tmp/mc
fi

sleep 5
mc alias set myminio "http://localhost:${MINIO_NODEPORT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" 2>/dev/null
mc mb "myminio/${MINIO_BUCKET}" --ignore-existing 2>/dev/null
echo "Bucket '${MINIO_BUCKET}' ready"

echo "=== 03: Complete ==="
