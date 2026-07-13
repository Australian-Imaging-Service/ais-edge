#!/usr/bin/env bash
# =============================================================================
# Deploy the xnat-ingest group-orthanc + assign pods (single node).
#   group-orthanc REST-pulls labelled studies from Orthanc and hardlinks the
#   deid'd DICOMs into /data/xnat-ingest/grouped; assign then collates them into
#   /data/xnat-ingest/staging, where the upload pod picks them up.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

echo "=== Deploying xnat-ingest staging (group-orthanc + assign) ==="

# group-orthanc hardlinks from orthanc-storage into grouped/; assign collates
# grouped/ into staging/. All dirs live under /data/xnat-ingest on this host so
# the hardlinks resolve (same filesystem; cross-fs hardlink would EXDEV).
sudo mkdir -p /data/xnat-ingest/grouped /data/xnat-ingest/staging
sudo chmod 777 /data/xnat-ingest/grouped /data/xnat-ingest/staging
echo "Staging dirs ready: /data/xnat-ingest/{grouped,staging}"

kubectl create namespace xnat-ingest --dry-run=client -o yaml | kubectl apply -f -

render "${REPO_DIR}/manifests/02-edge/xnat-ingest.yaml.tpl" \
    PROJECT_ID "$PROJECT_ID" \
    INGEST_LOOP_SECONDS "${INGEST_LOOP_SECONDS:-60}" \
    INGEST_WAIT_PERIOD "${INGEST_WAIT_PERIOD:-60}" \
    XNAT_INGEST_IMAGE "${XNAT_INGEST_IMAGE:-ghcr.io/australian-imaging-service/xnat-ingest:latest}" \
    | kubectl apply -f -

echo "Waiting for group + assign pods..."
kubectl rollout status deployment/xnat-ingest-group  -n xnat-ingest --timeout=180s || true
kubectl rollout status deployment/xnat-ingest-assign -n xnat-ingest --timeout=180s || true
kubectl get pods -n xnat-ingest -o wide
echo "=== staging deployed (group-orthanc REST-pull -> assign) ==="
