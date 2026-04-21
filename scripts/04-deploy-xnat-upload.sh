#!/usr/bin/env bash
# =============================================================================
# Step 04: Deploy XNAT upload pod on management cluster
#          Reads from MinIO → uploads to XNAT
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

echo "=== 04: Deploying XNAT upload pod ==="

render "${REPO_DIR}/manifests/01-management/xnat-upload.yaml.tpl" \
    XNAT_URL "$XNAT_URL" \
    XNAT_USER "$XNAT_USER" \
    XNAT_PASS "$XNAT_PASS" \
    MINIO_ROOT_USER "$MINIO_ROOT_USER" \
    MINIO_ROOT_PASSWORD "$MINIO_ROOT_PASSWORD" \
    MINIO_BUCKET "$MINIO_BUCKET" \
    | kubectl apply -f -

kubectl wait --for=condition=Available deployment/xnat-ingest-upload -n xnat-upload --timeout=180s 2>/dev/null || true

echo "=== 04: Complete ==="
kubectl get pods -n xnat-upload
