#!/usr/bin/env bash
# =============================================================================
# Step 02b: Set up cert-manager ClusterIssuers for the chosen CERT_ISSUER
# =============================================================================
# Always installs the self-signed ais-edge-ca pipeline because (a) it's used
# by the on-prem topology and (b) it's also the dev/nip.io fallback for cloud
# topology (Let's Encrypt refuses nip.io domains).
#
# Additionally, when CERT_ISSUER=letsencrypt-* AND DNS_PROVIDER is set, also
# installs the Let's Encrypt ClusterIssuers (staging + prod). The DNS-01
# challenge solver is rendered from a small per-provider stub at
# manifests/01-management/dns01-solvers/.
#
# CERT_ISSUER values:
#   ais-edge-ca         — default; uses the self-signed CA below.
#   letsencrypt-prod    — Let's Encrypt production; requires DNS_PROVIDER.
#   letsencrypt-staging — Let's Encrypt staging (fake CA, for testing the
#                         DNS-01 plumbing without burning the prod rate limit).
#
# Idempotent: re-running does NOT regenerate the CA. To rotate, use
# scripts/rotate-ca.sh.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

CERT_ISSUER="${CERT_ISSUER:-ais-edge-ca-issuer}"

echo "=== 02b: cert-manager Issuers (selected: ${CERT_ISSUER}) ==="

# Always install the self-signed CA pipeline. It's the default issuer and
# also the fallback for nip.io dev domains (Let's Encrypt blocks them).
kubectl apply -f "${REPO_DIR}/manifests/01-management/cert-issuers.yaml"

echo "Waiting for CA Certificate 'ais-edge-ca' to be Ready..."
kubectl wait --for=condition=Ready certificate/ais-edge-ca \
    -n cert-manager --timeout=120s

echo "Waiting for ClusterIssuer 'ais-edge-ca-issuer' to be Ready..."
RETRIES=12
for i in $(seq 1 $RETRIES); do
    if kubectl get clusterissuer ais-edge-ca-issuer \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
        | grep -q "True"; then
        break
    fi
    [ "$i" -eq "$RETRIES" ] && {
        echo "ERROR: ais-edge-ca-issuer never became Ready"
        kubectl describe clusterissuer ais-edge-ca-issuer
        exit 1
    }
    echo "  Not ready yet... ($i/$RETRIES)"
    sleep 5
done

# Export the public CA cert for edge distribution.
CA_OUT="${REPO_DIR}/ais-edge-ca.crt"
kubectl get secret -n cert-manager ais-edge-ca-secret \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > "${CA_OUT}"
chmod 644 "${CA_OUT}"

if ! openssl x509 -in "${CA_OUT}" -noout >/dev/null 2>&1; then
    echo "ERROR: exported ais-edge-ca.crt is not a valid x509 cert"
    exit 1
fi

CA_SHA256=$(openssl x509 -in "${CA_OUT}" -noout -fingerprint -sha256 | sed 's/^.*=//')
CA_NOTAFTER=$(openssl x509 -in "${CA_OUT}" -noout -enddate | sed 's/^.*=//')
CA_SUBJECT=$(openssl x509 -in "${CA_OUT}" -noout -subject | sed 's/^.*= //')

echo ""
echo "ais-edge-ca:"
echo "  cert file:      ${CA_OUT}"
echo "  subject:        ${CA_SUBJECT}"
echo "  expires:        ${CA_NOTAFTER}"
echo "  SHA-256 fp:     ${CA_SHA256}"

# ---------------------------------------------------------------------------
# Optional: also install Let's Encrypt ClusterIssuers when requested.
# ---------------------------------------------------------------------------
case "${CERT_ISSUER}" in
    letsencrypt-prod|letsencrypt-staging)
        if [ -z "${DNS_PROVIDER:-}" ]; then
            echo ""
            echo "ERROR: CERT_ISSUER=${CERT_ISSUER} but DNS_PROVIDER is unset."
            echo "  Set DNS_PROVIDER in config/management.env (e.g. cloudflare,"
            echo "  route53, rfc2136) and provide the corresponding API creds."
            exit 1
        fi
        SOLVER_FILE="${REPO_DIR}/manifests/01-management/dns01-solvers/${DNS_PROVIDER}.yaml"
        if [ ! -f "$SOLVER_FILE" ]; then
            echo ""
            echo "ERROR: No DNS-01 solver stub at ${SOLVER_FILE}."
            echo "  Add one or pick a supported DNS_PROVIDER."
            exit 1
        fi
        echo ""
        echo "Installing Let's Encrypt ClusterIssuers (DNS-01 solver: ${DNS_PROVIDER})..."
        SOLVER_BLOCK=$(sed 's/^/          /' "$SOLVER_FILE")     # 10-space indent
        render "${REPO_DIR}/manifests/01-management/cert-issuers-letsencrypt.yaml.tpl" \
            ACME_EMAIL          "${ACME_EMAIL:-noreply@example.com}" \
            DNS01_SOLVER_BLOCK  "$SOLVER_BLOCK" \
            | kubectl apply -f -

        echo "Waiting for letsencrypt-${CERT_ISSUER##letsencrypt-} ClusterIssuer to be Ready..."
        for i in $(seq 1 12); do
            if kubectl get clusterissuer "${CERT_ISSUER}" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null \
                | grep -q "True"; then
                break
            fi
            echo "  Not ready yet... ($i/12)"
            sleep 5
        done
        ;;
    ais-edge-ca-issuer|ais-edge-ca)
        # nothing extra — the CA path above is already in place
        ;;
    *)
        echo "WARNING: CERT_ISSUER=${CERT_ISSUER} doesn't match any recognised issuer."
        echo "  Recognised values: ais-edge-ca-issuer | letsencrypt-prod | letsencrypt-staging"
        ;;
esac

echo ""
echo "=== 02b: Complete ==="
echo "  Available ClusterIssuers:"
kubectl get clusterissuer 2>&1 | sed 's/^/    /'
