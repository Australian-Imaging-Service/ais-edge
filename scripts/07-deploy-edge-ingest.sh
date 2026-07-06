#!/usr/bin/env bash
# =============================================================================
# Deploy the xnat-ingest SORT pod (single node).
#   Sort REST-pulls labelled studies from Orthanc and hardlinks the deid'd
#   DICOMs into /data/xnat-ingest/staging, where the upload pod picks them up.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

echo "=== Deploying xnat-ingest sort ==="

# Sort's hardlink target. orthanc-storage + facility-backup are created by the
# Orthanc deploy step. All three live under /data/xnat-ingest on this host so
# the hardlink from orthanc-storage -> staging resolves (same filesystem).
sudo mkdir -p /data/xnat-ingest/staging
sudo chmod 777 /data/xnat-ingest/staging
echo "Staging dir ready: /data/xnat-ingest/staging"

kubectl create namespace xnat-ingest --dry-run=client -o yaml | kubectl apply -f -

render "${REPO_DIR}/manifests/02-edge/xnat-ingest.yaml.tpl" \
    PROJECT_ID "$PROJECT_ID" \
    INGEST_LOOP_SECONDS "${INGEST_LOOP_SECONDS:-60}" \
    INGEST_WAIT_PERIOD "${INGEST_WAIT_PERIOD:-60}" \
    XNAT_INGEST_IMAGE "${XNAT_INGEST_IMAGE:-ghcr.io/australian-imaging-service/xnat-ingest:latest}" \
    | kubectl apply -f -

echo "Waiting for sort pod..."
kubectl rollout status deployment/xnat-ingest-sort -n xnat-ingest --timeout=180s || true
kubectl get pods -n xnat-ingest -o wide
echo "=== sort deployed (REST-pull mode against Orthanc) ==="
