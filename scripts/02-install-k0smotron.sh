#!/usr/bin/env bash
# =============================================================================
# Step 02: Install cert-manager and k0smotron operator
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

echo "=== 02: Installing cert-manager + k0smotron ==="

# Helper: wait until at least one pod matching a label exists in a namespace,
# then wait until they are all Ready. The "wait for at least one pod first"
# step avoids the classic race where `kubectl apply` returns before the
# controller has created pods, making `kubectl wait --all` fail with
# "no matching resources found" and a non-zero exit (which under set -e
# kills the entire install).
wait_pods_ready() {
    local ns="$1"; shift
    local timeout_appear=120         # seconds to wait for the FIRST pod
    local timeout_ready=300          # seconds to wait for ALL Ready
    local desc="${ns} pods"

    echo "  Waiting for ${desc} to appear in namespace '${ns}'..."
    local i=0
    while [ "$i" -lt "$timeout_appear" ]; do
        if kubectl get pods -n "$ns" --no-headers 2>/dev/null | grep -q .; then
            break
        fi
        sleep 3
        i=$((i + 3))
    done
    if [ "$i" -ge "$timeout_appear" ]; then
        echo "  ERROR: no pods appeared in ${ns} within ${timeout_appear}s"
        kubectl get all -n "$ns" 2>&1 | head -20
        return 1
    fi

    echo "  Waiting for ${desc} to be Ready..."
    kubectl wait --for=condition=Ready pods --all -n "$ns" \
        --timeout="${timeout_ready}s"
}

# cert-manager
if ! kubectl get namespace cert-manager &>/dev/null; then
    echo "Installing cert-manager..."
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
    wait_pods_ready cert-manager
else
    echo "cert-manager: already installed"
    wait_pods_ready cert-manager
fi

# k0smotron
if ! kubectl get crds clusters.k0smotron.io &>/dev/null 2>&1; then
    echo "Installing k0smotron..."
    kubectl apply --server-side=true -f https://docs.k0smotron.io/stable/install.yaml
    K0S_NS="k0smotron"
    # The k0smotron operator's namespace is created by the manifest itself.
    # Wait for the namespace to exist, then for its pods.
    i=0
    while [ "$i" -lt 60 ]; do
        if kubectl get namespace "$K0S_NS" &>/dev/null; then
            break
        fi
        sleep 2
        i=$((i + 2))
    done
    wait_pods_ready "$K0S_NS"
else
    echo "k0smotron: already installed"
    wait_pods_ready k0smotron
fi

echo "=== 02: Complete ==="
kubectl get crds | grep k0smotron | head -3
