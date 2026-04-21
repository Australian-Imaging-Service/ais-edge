#!/usr/bin/env bash
# =============================================================================
# Step 06: Install k0s worker on edge VM and join the hosted cluster
#          Usage: ./06-join-edge-worker.sh <edge-entry>
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <edge-entry>"
    exit 1
fi

parse_edge_entry "$1"

echo "=== 06: Installing k0s worker on ${NODE_IP} for ${CLUSTER_NAME} ==="

# Test SSH
ssh ${SSH_KEY_OPT} -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "${EDGE_SSH}" "hostname" || {
    echo "ERROR: Cannot SSH to ${EDGE_SSH}"; exit 1;
}

# Copy join token
scp ${SSH_KEY_OPT} "${REPO_DIR}/join-token-${CLUSTER_NAME}" "${EDGE_SSH}:/tmp/join-token"

# Install and start worker
ssh ${SSH_KEY_OPT} "${EDGE_SSH}" bash -s <<'WORKER_SCRIPT'
set -euo pipefail
command -v k0s &>/dev/null || { curl -sSLf https://get.k0s.sh | sudo sh; }
echo "k0s: $(k0s version)"
if ! sudo systemctl is-active k0sworker &>/dev/null; then
    sudo mkdir -p /etc/k0s
    sudo cp /tmp/join-token /etc/k0s/join-token
    sudo chmod 600 /etc/k0s/join-token
    rm -f /tmp/join-token
    sudo k0s install worker --force --token-file /etc/k0s/join-token
    sudo systemctl reset-failed k0sworker 2>/dev/null || true
    sudo k0s start
fi
RETRIES=18
for i in $(seq 1 $RETRIES); do
    sudo systemctl is-active k0sworker &>/dev/null && pgrep -f kubelet &>/dev/null && {
        echo "Worker running (kubelet active)"; break; }
    [ $i -eq $RETRIES ] && echo "WARNING: kubelet not yet detected — may still be downloading"
    echo "  Waiting... ($i/$RETRIES)"; sleep 10
done
WORKER_SCRIPT

# Verify node joined
echo "Verifying node joined..."
RETRIES=18
for i in $(seq 1 $RETRIES); do
    NODES=$(KUBECONFIG="$EDGE_KC" kubectl get nodes --no-headers 2>/dev/null | grep -c "Ready" || true)
    [ "$NODES" -ge 1 ] && { echo "Node joined and Ready!"; break; }
    [ $i -eq $RETRIES ] && { echo "ERROR: Node not Ready"; exit 1; }
    echo "  Waiting... ($i/$RETRIES)"
    sleep 10
done
KUBECONFIG="$EDGE_KC" kubectl get nodes -o wide

echo "=== 06: Complete for ${CLUSTER_NAME} ==="
