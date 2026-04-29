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
    SEAWEEDFS_HOSTNAME "$SEAWEEDFS_HOSTNAME" \
    S3_CONFIG_HASH "$S3_CONFIG_HASH" \
    | kubectl apply -f -

# 5b. Phase 2: issue the TLS server cert (cert-manager) + Ingress (nginx)
# Skipped if cert-manager / ais-edge-ca-issuer / ingress-nginx aren't ready;
# falls through with a warning so the legacy HTTP NodePort path still works.
if kubectl get clusterissuer ais-edge-ca-issuer &>/dev/null \
   && kubectl get -n ingress-nginx deployment ingress-nginx-controller &>/dev/null; then
    echo "Phase 2 prereqs found — applying SeaweedFS TLS cert + Ingress"

    render "${REPO_DIR}/manifests/01-management/seaweedfs-tls-cert.yaml.tpl" \
        SEAWEEDFS_HOSTNAME "$SEAWEEDFS_HOSTNAME" \
        MGMT_NODE_IP "$MGMT_NODE_IP" \
        | kubectl apply -f -

    echo "Waiting for seaweedfs-tls Certificate to be Ready..."
    kubectl wait --for=condition=Ready certificate/seaweedfs-tls \
        -n seaweedfs --timeout=120s

    render "${REPO_DIR}/manifests/01-management/seaweedfs-ingress.yaml.tpl" \
        SEAWEEDFS_HOSTNAME "$SEAWEEDFS_HOSTNAME" \
        | kubectl apply -f -

    echo "SeaweedFS TLS path ready: https://${SEAWEEDFS_HOSTNAME}:${INGRESS_PORT}"
else
    echo "Phase 2 prereqs missing — skipping SeaweedFS TLS cert + Ingress"
    echo "  (run 02b-bootstrap-ca.sh and 02c-install-nginx-ingress.sh first)"
fi

echo "Waiting for SeaweedFS pod to start..."
# Wait for the pod to exist first (avoids "no matching resources found" race)
RETRIES=24
for i in $(seq 1 $RETRIES); do
    kubectl get pod -n seaweedfs -l app=seaweedfs --no-headers 2>/dev/null | grep -q . && break
    [ $i -eq $RETRIES ] && { echo "ERROR: SeaweedFS pod never appeared"; kubectl get all -n seaweedfs; exit 1; }
    echo "  Pod not yet scheduled... ($i/$RETRIES)"
    sleep 5
done

echo "Waiting for SeaweedFS pod to be Ready..."
kubectl wait --for=condition=Ready pods -l app=seaweedfs -n seaweedfs --timeout=300s

# 6. Install mc (also speaks vanilla S3 — works against SeaweedFS)
if ! command -v mc &>/dev/null; then
    curl -sL https://dl.min.io/client/mc/release/linux-amd64/mc -o /tmp/mc
    sudo install -o root -g root -m 0755 /tmp/mc /usr/local/bin/mc && rm -f /tmp/mc
fi

# 7. Create bucket via in-cluster ClusterIP — start a background port-forward
# from the management host to the seaweedfs Service. Phase 2 keeps SeaweedFS
# Service as ClusterIP only (external access is via nginx-ingress :443).
PF_PORT=18333
kubectl port-forward -n seaweedfs svc/seaweedfs ${PF_PORT}:8333 \
    > /tmp/seaweedfs-pf.log 2>&1 &
PF_PID=$!
trap "rm -f $TMP_S3; kill ${PF_PID} 2>/dev/null || true" EXIT

# Wait until port-forward is serving
RETRIES=24
for i in $(seq 1 $RETRIES); do
    if mc alias set seaweed "http://localhost:${PF_PORT}" \
        "${S3_ADMIN_ACCESS_KEY}" "${S3_ADMIN_SECRET_KEY}" 2>/dev/null \
       && mc ls seaweed/ &>/dev/null; then
        break
    fi
    [ $i -eq $RETRIES ] && {
        echo "ERROR: S3 endpoint not responding via port-forward after ${RETRIES} attempts"
        cat /tmp/seaweedfs-pf.log 2>/dev/null | tail -10
        kubectl logs -n seaweedfs -l app=seaweedfs --tail=30
        exit 1
    }
    echo "  Waiting for S3 endpoint... ($i/$RETRIES)"
    sleep 5
done

mc mb "seaweed/${S3_BUCKET}" --ignore-existing 2>/dev/null
echo "Bucket '${S3_BUCKET}' ready"

# Persist a localhost mc alias for admin convenience: subsequent admin runs
# can `kubectl port-forward -n seaweedfs svc/seaweedfs 8333:8333 &` and then
# `mc ls seaweed-admin/`. We don't keep the port-forward running.
mc alias set seaweed-admin "http://localhost:8333" \
    "${S3_ADMIN_ACCESS_KEY}" "${S3_ADMIN_SECRET_KEY}" 2>/dev/null || true

echo "=== 03: Complete ==="
echo "SeaweedFS S3 API (TLS, edge):  https://${SEAWEEDFS_HOSTNAME}  (via nginx-ingress :${INGRESS_PORT})"
echo "SeaweedFS S3 API (in-cluster): http://seaweedfs.seaweedfs.svc.cluster.local:8333"
echo "SeaweedFS master UI (admin):   kubectl port-forward -n seaweedfs svc/seaweedfs 9333:9333"
echo "SeaweedFS filer UI (admin):    kubectl port-forward -n seaweedfs svc/seaweedfs 8888:8888"
