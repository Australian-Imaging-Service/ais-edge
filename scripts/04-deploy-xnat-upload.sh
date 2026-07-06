#!/usr/bin/env bash
# =============================================================================
# Deploy the xnat-ingest UPLOAD pod (single node).
#   Reads the LOCAL staging dir written by sort (/data/xnat-ingest/staging)
#   and uploads sessions to XNAT over HTTPS. No SeaweedFS / S3 hop.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

echo "=== Deploying xnat-ingest upload pod (local staging -> XNAT) ==="

render "${REPO_DIR}/manifests/01-management/xnat-upload.yaml.tpl" \
    XNAT_URL "$XNAT_URL" \
    XNAT_USER "$XNAT_USER" \
    XNAT_PASS "$XNAT_PASS" \
    XNAT_INGEST_IMAGE "${XNAT_INGEST_IMAGE:-ghcr.io/australian-imaging-service/xnat-ingest:latest}" \
    | kubectl apply -f -

kubectl wait --for=condition=Available deployment/xnat-ingest-upload -n xnat-upload --timeout=180s 2>/dev/null || true

echo "=== upload pod deployed ==="
kubectl get pods -n xnat-upload
