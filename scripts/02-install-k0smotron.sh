#!/usr/bin/env bash
# =============================================================================
# Step 02: Install cert-manager and k0smotron operator
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

echo "=== 02: Installing cert-manager + k0smotron ==="

# cert-manager
if ! kubectl get namespace cert-manager &>/dev/null; then
    echo "Installing cert-manager..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
    kubectl wait --for=condition=Ready pods --all -n cert-manager --timeout=180s
else
    echo "cert-manager: already installed"
fi

# k0smotron
if ! kubectl get crds clusters.k0smotron.io &>/dev/null 2>&1; then
    echo "Installing k0smotron..."
    kubectl apply --server-side=true -f https://docs.k0smotron.io/stable/install.yaml
    sleep 15
    K0S_NS=$(kubectl get pods -A -l control-plane=controller-manager --no-headers 2>/dev/null | head -1 | awk '{print $1}' || echo "k0smotron")
    kubectl wait --for=condition=Ready pods --all -n "$K0S_NS" --timeout=180s
else
    echo "k0smotron: already installed"
fi

echo "=== 02: Complete ==="
kubectl get crds | grep k0smotron | head -3
