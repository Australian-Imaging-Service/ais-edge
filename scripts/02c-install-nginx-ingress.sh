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
        # LB_PUBLIC_IP is OPTIONAL in cloud mode:
        #  * If set, OCCM tries to associate that exact public IP. Required
        #    pattern for AWS NLB + Elastic IP, GCP regional static IP, etc.
        #  * If empty, the cloud LB controller auto-assigns a VIP and we
        #    discover it from the Service status. Required pattern for
        #    Nectar QLD where the LB sits on the external network and FIP
        #    association doesn't apply (Neutron rejects same-network FIPs).
        if [ -z "${LB_PUBLIC_IP:-}" ]; then
            echo "  LB_PUBLIC_IP unset — letting cloud LB auto-assign a VIP."
            echo "  (Set LB_PUBLIC_IP in management.env to pin to a specific IP.)"
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

# Strip any `{{#LB_PUBLIC_IP}}` / `{{/LB_PUBLIC_IP}}` marker lines. The
# template wraps `loadBalancerIP:` so it's only emitted when LB_PUBLIC_IP
# is non-empty (a real value would have been substituted before we get
# here). awk drops marker lines and, when LB_PUBLIC_IP is empty, also
# drops the inner content.
if [ -n "${LB_PUBLIC_IP:-}" ]; then
    sed -i '/{{[/#]LB_PUBLIC_IP}}/d' "${VALUES_FILE}"
else
    awk '/\{\{#LB_PUBLIC_IP\}\}/{skip=1; next} /\{\{\/LB_PUBLIC_IP\}\}/{skip=0; next} !skip {print}' \
        "${VALUES_FILE}" > "${VALUES_FILE}.tmp" && mv "${VALUES_FILE}.tmp" "${VALUES_FILE}"
fi

# Ensure the helm repo is available
if ! helm repo list 2>/dev/null | grep -q "ingress-nginx"; then
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
fi
helm repo update ingress-nginx

# Install or upgrade. NB: no `--wait` — helm's --wait blocks on the
# LoadBalancer Service getting a status.externalIP, which never resolves on
# cloud topologies where the LB controller can't fully claim the Service
# (e.g. Nectar QLD, where Octavia gives the LB a working public VIP but
# OCCM keeps retrying an impossible FIP-association). The kubectl wait
# below is the real readiness check.
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    --namespace ingress-nginx \
    --create-namespace \
    --values "${VALUES_FILE}"

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
        if [ -n "${LB_PUBLIC_IP:-}" ] && [ "${EXT_IP}" != "${LB_PUBLIC_IP}" ]; then
            echo "  WARNING: LB external IP (${EXT_IP}) differs from configured LB_PUBLIC_IP (${LB_PUBLIC_IP})."
            echo "           Check the cloud-controller-manager logs."
        fi
        EFFECTIVE_IP="${EXT_IP}"
    elif [ -n "${EXT_HOST}" ]; then
        echo "  LoadBalancer external hostname: ${EXT_HOST}"
        EFFECTIVE_IP="${EXT_HOST}"
    else
        # Service status may still be pending if OCCM is retrying. On Nectar
        # QLD topology the FIP association loop is harmless — discover the
        # actual VIP directly from the LB pool member's listener via the
        # underlying provider when available; otherwise the operator must
        # query their cloud manually.
        echo "  NOTE: LB did not get an external address within 5 minutes."
        echo "        Check 'kubectl describe svc -n ingress-nginx ingress-nginx-controller'."
        echo "        On Nectar shared-public-network topologies OCCM cannot mark the"
        echo "        Service ready (FIP-on-external-network limitation); query the"
        echo "        Octavia LB directly with:"
        echo "          openstack loadbalancer list -c name -c vip_address"
        EFFECTIVE_IP="${LB_PUBLIC_IP:-<unknown>}"
    fi
    echo ""
    echo "Test:  curl -kv https://${EFFECTIVE_IP}/   # expect TLS handshake + 404 default backend"
fi
