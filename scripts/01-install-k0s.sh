#!/usr/bin/env bash
# =============================================================================
# Step 01: Install k0s management cluster (skip if INSTALL_MODE=existing)
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

if [ "${INSTALL_MODE}" = "existing" ]; then
    echo "=== 01: Using existing Kubernetes cluster ==="
    kubectl get nodes -o wide || { echo "ERROR: kubectl not configured"; exit 1; }
    if ! kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' | grep -q '.'; then
        echo "WARNING: No default StorageClass. PVCs may fail."
    fi
    exit 0
fi

echo "=== 01: Installing k0s management cluster ==="

# Install binary
if ! command -v k0s &>/dev/null; then
    curl -sSLf https://get.k0s.sh | sudo sh
fi
echo "k0s: $(k0s version)"

# Start cluster
if ! sudo k0s status &>/dev/null; then
    sudo mkdir -p /etc/k0s
    sudo cp "${REPO_DIR}/config/k0s-controller.yaml" /etc/k0s/k0s.yaml
    sudo k0s install controller --single -c /etc/k0s/k0s.yaml
    sudo k0s start
    echo "Waiting for k0s to start..."
    sleep 15
fi

# Wait for Ready
RETRIES=30
for i in $(seq 1 $RETRIES); do
    sudo k0s kubectl get nodes 2>/dev/null | grep -q "Ready" && { echo "Node Ready!"; break; }
    [ $i -eq $RETRIES ] && { echo "ERROR: Node not Ready"; exit 1; }
    echo "  Waiting... ($i/$RETRIES)"
    sleep 10
done

# Kubeconfig
mkdir -p ~/.kube
sudo k0s kubeconfig admin > ~/.kube/config
chmod 600 ~/.kube/config

# kubectl + helm
if ! command -v kubectl &>/dev/null; then
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm -f kubectl
fi
if ! command -v helm &>/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Local-path provisioner
if ! kubectl get sc local-path &>/dev/null; then
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
    kubectl patch storageclass local-path \
        -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
fi

echo "=== 01: Complete ==="
kubectl get nodes -o wide
