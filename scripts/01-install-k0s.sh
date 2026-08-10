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
#
# v0.0.36, not the v0.0.30 that was here. v0.0.30 is affected by
# CVE-2025-62878 (CVSS 9.9 — `parameters.pathPattern` on a StorageClass is
# not sanitised, so a traversal sequence provisions a PV anywhere on the host
# filesystem; pathPattern handling is present in v0.0.30, so it is genuinely
# in range) and CVE-2026-44543 (helperPod.yaml template injection). Both need
# cluster-scoped write to exploit, so this is hardening rather than an open
# door — but this provisioner backs the Prometheus, Grafana and Alertmanager
# PVCs on the internet-facing management node, and the fix is a version
# number. v0.0.36 is the lowest release fixing both; v0.0.37 is a day old.
#
# NOTE THE `if` ABOVE: this only runs when the StorageClass is absent, so it
# does NOT upgrade a cluster that already has v0.0.30 — see the manual step in
# the CVE audit. Checked before changing the version, since a live cluster's
# existing PVs depend on all of it: StorageClass name (`local-path`),
# provisioner (`rancher.io/local-path`), reclaimPolicy (Delete) and node path
# (/opt/local-path-provisioner) are byte-identical between the two manifests.
# The only other difference is upstream fully-qualifying its image names.
if ! kubectl get sc local-path &>/dev/null; then
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.36/deploy/local-path-storage.yaml
    kubectl patch storageclass local-path \
        -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
fi

echo "=== 01: Complete ==="
kubectl get nodes -o wide
