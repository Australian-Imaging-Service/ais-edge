#!/usr/bin/env bash
# =============================================================================
# Deploy Orthanc DICOM receiver + deid hook (single node).
#   Orthanc: DIMSE SCP on host port 4242 (AET=AISEDGE). The Lua hook
#   OnStoredInstance de-identifies per the profile selected by routing.json,
#   writes the ORIGINAL to /facility-backup, keeps the deid'd instance, and
#   OnStableStudy labels the study `xnat-ingest-ready` for the sort pod.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

ORTHANC_CFG_DIR="${REPO_DIR}/config/orthanc"

# --- Validate required inputs ---
for f in orthanc.json deidentify-and-forward.lua; do
    [ -f "${ORTHANC_CFG_DIR}/${f}" ] || { echo "ERROR: ${ORTHANC_CFG_DIR}/${f} not found"; exit 1; }
done
if [ ! -f "${ORTHANC_CFG_DIR}/routing.json" ]; then
    echo "ERROR: ${ORTHANC_CFG_DIR}/routing.json not found"
    echo "       cp ${ORTHANC_CFG_DIR}/routing.json.template ${ORTHANC_CFG_DIR}/routing.json && edit AETMap"
    exit 1
fi
if [ -z "${AIS_DEID_HMAC_SALT:-}" ]; then
    echo "ERROR: AIS_DEID_HMAC_SALT not set in config/management.env (openssl rand -hex 32)"; exit 1
fi
ORTHANC_IMAGE="${ORTHANC_IMAGE:-jodogne/orthanc-plugins:1.12.6}"

echo "=== Deploying Orthanc (deid) ==="
echo "Image:  ${ORTHANC_IMAGE}"

# --- Site-admin confirmation: deid policy review ---
echo
echo "=== Deidentification policy that will be deployed ==="
echo "--- routing.json (AET -> profile + project) ---"
sed -n '/"AETMap"/,/^  }/p' "${ORTHANC_CFG_DIR}/routing.json" | head -30
echo "--- deidentification profile ---"
echo "  ${ORTHANC_CFG_DIR}/deidentification-profile.json"
echo
if [ "${AIS_AUTO_CONFIRM:-}" != "yes" ] && [ -t 0 ]; then
    read -p "Have you reviewed the AETMap + profiles above? [y/N] " -r REPLY
    [[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted at deid-policy review."; exit 1; }
fi

# --- Host-side directories (local; shared with sort so hardlinks resolve) ---
sudo mkdir -p /data/xnat-ingest/orthanc-storage /data/facility-backup
sudo chmod 777 /data/xnat-ingest/orthanc-storage
sudo chmod 750 /data/facility-backup
echo "Dirs ready: /data/xnat-ingest/orthanc-storage, /data/facility-backup"

# --- Namespace + ConfigMaps from config/orthanc/ ---
kubectl create namespace xnat-ingest --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap orthanc-config -n xnat-ingest \
    --from-file=orthanc.json="${ORTHANC_CFG_DIR}/orthanc.json" \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap orthanc-scripts -n xnat-ingest \
    --from-file="${ORTHANC_CFG_DIR}/deidentify-and-forward.lua" \
    --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap orthanc-routing -n xnat-ingest \
    --from-file=routing.json="${ORTHANC_CFG_DIR}/routing.json" \
    --dry-run=client -o yaml | kubectl apply -f -
if [ ! -f "${ORTHANC_CFG_DIR}/deidentification-profile.json" ]; then
    echo "ERROR: ${ORTHANC_CFG_DIR}/deidentification-profile.json not found — copy from .template"; exit 1
fi
kubectl create configmap orthanc-deidentification-profile -n xnat-ingest \
    --from-file=deidentification-profile.json="${ORTHANC_CFG_DIR}/deidentification-profile.json" \
    --dry-run=client -o yaml | kubectl apply -f -
echo "ConfigMaps applied: orthanc-config, orthanc-scripts, orthanc-routing, orthanc-deidentification-profile"

# --- Secret + Deployment + Service ---
render "${REPO_DIR}/manifests/02-edge/orthanc.yaml.tpl" \
    ORTHANC_IMAGE "$ORTHANC_IMAGE" \
    AIS_DEID_HMAC_SALT "$AIS_DEID_HMAC_SALT" \
    | kubectl apply -f -

echo "Waiting for Orthanc pod..."
kubectl rollout status -n xnat-ingest deployment/orthanc --timeout=180s || true
kubectl get pods -n xnat-ingest -l app=orthanc -o wide

echo
echo "=== Orthanc deployed ==="
echo "Modality DICOM endpoint (C-STORE target):"
echo "  AET=AISEDGE  Host=${MGMT_NODE_IP}  Port=4242"
echo "  storescu -aec <AET-from-routing.json> -aet TEST_MOD ${MGMT_NODE_IP} 4242 path/to/study/*.dcm"
