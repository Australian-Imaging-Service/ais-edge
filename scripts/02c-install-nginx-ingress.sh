#!/usr/bin/env bash
# =============================================================================
# Step 02c: Install nginx-ingress on the management cluster
# =============================================================================
# Two topologies (driven by INSTALL_TOPOLOGY in config/management.env):
#
#   onprem (legacy, default):
#     hostNetwork: true → controller binds :443 directly on the mgmt node.
#     One replica (only one pod can bind the host port). Edges dial the
#     node's IP. Hostname resolution via /etc/hosts + hostAliases.
#
#   cloud (managed K8s / EKS / Magnum / etc.):
#     Service type LoadBalancer → cloud CCM provisions a real L4 LB and
#     assigns it the pre-allocated public IP from LB_PUBLIC_IP. Multiple
#     replicas allowed; LB load-balances across them. Hostname resolution
#     via real public DNS.
#
# SSL passthrough is enabled in both cases so backends with their own TLS
# (SeaweedFS, k0smotron API/konnectivity) can be SNI-routed without
# terminating TLS at the proxy.
#
# Idempotent: helm upgrade --install reapplies values without recreating.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

TOPOLOGY="${INSTALL_TOPOLOGY:-onprem}"

echo "=== 02c: Install nginx-ingress (topology=${TOPOLOGY}) ==="

# Pick the right values template
case "${TOPOLOGY}" in
    onprem)
        VALUES_TPL="${REPO_DIR}/manifests/01-management/nginx-ingress-values.yaml.tpl"
        ;;
    cloud)
        VALUES_TPL="${REPO_DIR}/manifests/01-management/nginx-ingress-values-cloud.yaml.tpl"
        if [ -z "${LB_PUBLIC_IP:-}" ]; then
            echo "ERROR: INSTALL_TOPOLOGY=cloud requires LB_PUBLIC_IP to be set in"
            echo "       config/management.env (pre-allocated cloud floating IP)."
            exit 1
        fi
        ;;
    *)
        echo "ERROR: Unknown INSTALL_TOPOLOGY='${TOPOLOGY}'. Use 'onprem' or 'cloud'."
        exit 1
        ;;
esac

VALUES_FILE=$(mktemp /tmp/nginx-ingress-values-XXXXXX.yaml)
trap "rm -f $VALUES_FILE" EXIT

render "${VALUES_TPL}" \
    LB_PUBLIC_IP "${LB_PUBLIC_IP:-}" \
    > "${VALUES_FILE}"

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

echo ""
echo "=== 02c: Complete (topology=${TOPOLOGY}) ==="

if [ "${TOPOLOGY}" = "onprem" ]; then
    # Verify port 443 is bound on the host
    if ! ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ':443$'; then
        POD=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller \
            -o jsonpath='{.items[0].metadata.name}')
        echo "  ss did not show :443 on host; checking from inside pod ${POD}..."
        kubectl exec -n ingress-nginx "${POD}" -- /bin/sh -c \
            "netstat -tln 2>/dev/null | grep -E ':443\s' || ss -tln 2>/dev/null | grep -E ':443'" \
            || echo "  WARNING: port 443 not visibly bound — check 'kubectl logs -n ingress-nginx ${POD}'"
    fi
    echo "ingress-nginx is listening on the host's :443"
    echo "Test:  curl -kv https://${MGMT_NODE_IP}/   # expect TLS handshake + 404 default backend"
else
    # cloud — wait for the LB to get an external IP, then verify it matches
    # what we asked for.
    echo "Waiting for LoadBalancer Service to be provisioned with an external IP..."
    for i in $(seq 1 60); do
        EXT_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        EXT_HOST=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        if [ -n "${EXT_IP}" ] || [ -n "${EXT_HOST}" ]; then break; fi
        sleep 5
    done

    if [ -n "${EXT_IP}" ]; then
        echo "  LoadBalancer external IP: ${EXT_IP}"
        if [ "${EXT_IP}" != "${LB_PUBLIC_IP}" ]; then
            echo "  WARNING: LB external IP (${EXT_IP}) differs from configured LB_PUBLIC_IP (${LB_PUBLIC_IP})."
            echo "           Check the cloud-controller-manager logs."
        fi
    elif [ -n "${EXT_HOST}" ]; then
        echo "  LoadBalancer external hostname: ${EXT_HOST}"
    else
        echo "  WARNING: LB did not get an external address within 5 minutes."
        echo "  Check 'kubectl describe svc -n ingress-nginx ingress-nginx-controller' and"
        echo "  the cloud-controller-manager logs."
    fi
    echo ""
    echo "Test:  curl -kv https://${LB_PUBLIC_IP}/   # expect TLS handshake + 404 default backend"
fi
