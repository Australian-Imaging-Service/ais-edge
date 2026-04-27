#!/usr/bin/env bash
# =============================================================================
# Step 03: Deploy SeaweedFS on the management cluster
# =============================================================================
# Generates s3.json with all identities (admin + per-edge users) from
# management.env and edge-nodes.env, then deploys SeaweedFS as a single-pod
# all-in-one (master + volume + filer + S3) Deployment.
#
# Re-running this script regenerates the config — useful when adding/removing
# edge nodes — and rolls the SeaweedFS pod via a config-hash annotation.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

echo "=== 03: Deploying SeaweedFS ==="

# 1. Pre-create data directory on the host
sudo mkdir -p /data/seaweedfs
sudo chmod 755 /data/seaweedfs

# 2. Build s3.json from management.env (admin) + edge-nodes.env (per-edge users)
TMP_S3=$(mktemp /tmp/s3-config-XXXXXX.json)
trap "rm -f $TMP_S3" EXIT

{
  echo '{'
  echo '  "identities": ['
  cat <<EOF
    {
      "name": "admin",
      "credentials": [
        {
          "accessKey": "${S3_ADMIN_ACCESS_KEY}",
          "secretKey": "${S3_ADMIN_SECRET_KEY}"
        }
      ],
      "actions": ["Admin", "Read", "Write", "List", "Tagging"]
    }
EOF
  for entry in "${EDGE_NODES[@]}"; do
    IFS='|' read -r CLUSTER_NAME _ _ _ _ EDGE_ACCESS_KEY EDGE_SECRET_KEY <<< "$entry"
    cat <<EOF
    ,
    {
      "name": "${CLUSTER_NAME}",
      "credentials": [
        {
          "accessKey": "${EDGE_ACCESS_KEY}",
          "secretKey": "${EDGE_SECRET_KEY}"
        }
      ],
      "actions": [
        "Read:${S3_BUCKET}",
        "List:${S3_BUCKET}",
        "Write:${S3_BUCKET}/*",
        "Tagging:${S3_BUCKET}"
      ]
    }
EOF
  done
  echo '  ]'
  echo '}'
} > "$TMP_S3"

# Validate JSON
if ! python3 -c "import json,sys; json.load(open('$TMP_S3'))" 2>/dev/null; then
    echo "ERROR: Generated s3.json is invalid:"
    cat "$TMP_S3"
    exit 1
fi
echo "Generated s3.json with $(grep -c '"name"' "$TMP_S3") identities"

# 3. Hash the config to drive pod restarts on changes
S3_CONFIG_HASH=$(sha256sum "$TMP_S3" | cut -c1-16)

# 4. Apply namespace + ConfigMap
kubectl create namespace seaweedfs --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap s3-config \
    --namespace seaweedfs \
    --from-file=s3.json="$TMP_S3" \
    --dry-run=client -o yaml | kubectl apply -f -

# 5. Apply Deployment + Service
render "${REPO_DIR}/manifests/01-management/seaweedfs.yaml.tpl" \
    S3_NODEPORT "$S3_NODEPORT" \
    MASTER_NODEPORT "$MASTER_NODEPORT" \
    FILER_NODEPORT "$FILER_NODEPORT" \
    S3_CONFIG_HASH "$S3_CONFIG_HASH" \
    | kubectl apply -f -

echo "Waiting for SeaweedFS pod to be ready..."
kubectl wait --for=condition=Ready pods -l app=seaweedfs -n seaweedfs --timeout=300s
echo "SeaweedFS ready: S3 API at http://${MGMT_NODE_IP}:${S3_NODEPORT}"

# 6. Install mc (also speaks vanilla S3 — works against SeaweedFS)
if ! command -v mc &>/dev/null; then
    curl -sL https://dl.min.io/client/mc/release/linux-amd64/mc -o /tmp/mc
    sudo install -o root -g root -m 0755 /tmp/mc /usr/local/bin/mc && rm -f /tmp/mc
fi

# 7. Wait until S3 endpoint is actually serving, then create bucket
RETRIES=24
for i in $(seq 1 $RETRIES); do
    if mc alias set seaweed "http://localhost:${S3_NODEPORT}" \
        "${S3_ADMIN_ACCESS_KEY}" "${S3_ADMIN_SECRET_KEY}" 2>/dev/null \
       && mc ls seaweed/ &>/dev/null; then
        break
    fi
    [ $i -eq $RETRIES ] && {
        echo "ERROR: S3 endpoint not responding after ${RETRIES} attempts"
        kubectl logs -n seaweedfs -l app=seaweedfs --tail=30
        exit 1
    }
    echo "  Waiting for S3 endpoint... ($i/$RETRIES)"
    sleep 5
done

mc mb "seaweed/${S3_BUCKET}" --ignore-existing 2>/dev/null
echo "Bucket '${S3_BUCKET}' ready"

echo "=== 03: Complete ==="
echo "SeaweedFS S3 API:    http://${MGMT_NODE_IP}:${S3_NODEPORT}"
echo "SeaweedFS master UI: http://${MGMT_NODE_IP}:${MASTER_NODEPORT}"
echo "SeaweedFS filer UI:  http://${MGMT_NODE_IP}:${FILER_NODEPORT}"
