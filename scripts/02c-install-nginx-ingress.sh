#!/usr/bin/env bash
# =============================================================================
# Step 02c: Install nginx-ingress on the management node (Phase 2)
# =============================================================================
# Helm install with hostNetwork: true so the controller binds port 443 on the
# management node directly. SSL passthrough is enabled so backends with their
# own TLS (SeaweedFS, k0smotron API/konnectivity) can be SNI-routed without
# terminating TLS at the proxy.
#
# Idempotent: helm upgrade --install reapplies values without recreating.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

echo "=== 02c: Install nginx-ingress ==="

VALUES_FILE=$(mktemp /tmp/nginx-ingress-values-XXXXXX.yaml)
trap "rm -f $VALUES_FILE" EXIT

# Render template (no placeholders right now, but keeps the pattern consistent
# in case we want to inject values later).
render "${REPO_DIR}/manifests/01-management/nginx-ingress-values.yaml.tpl" > "${VALUES_FILE}"

# Ensure the helm repo is available
if ! helm repo list 2>/dev/null | grep -q "ingress-nginx"; then
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
fi
helm repo update ingress-nginx

# Install or upgrade
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --values "${VALUES_FILE}" \
    --wait \
    --timeout 300s

echo "Waiting for ingress-nginx controller pod to be Ready..."
kubectl wait --for=condition=Ready pod \
    -l app.kubernetes.io/component=controller \
    -n ingress-nginx --timeout=300s

# Verify port 443 is bound on the host
echo ""
echo "Verifying port 443 is bound on the host..."
if ! ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ':443$'; then
    # Fall back to checking from inside the pod
    POD=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller \
        -o jsonpath='{.items[0].metadata.name}')
    echo "  ss did not show :443 on host; checking from inside pod ${POD}..."
    kubectl exec -n ingress-nginx "${POD}" -- /bin/sh -c \
        "netstat -tln 2>/dev/null | grep -E ':443\s' || ss -tln 2>/dev/null | grep -E ':443'" \
        || echo "  WARNING: port 443 not visibly bound — check 'kubectl logs -n ingress-nginx ${POD}'"
fi

echo ""
echo "=== 02c: Complete ==="
echo "ingress-nginx is listening on the host's :443"
echo "Test:  curl -kv https://${MGMT_NODE_IP}/   # expect TLS handshake + 404 default backend"
