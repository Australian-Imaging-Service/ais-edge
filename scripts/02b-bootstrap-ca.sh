#!/usr/bin/env bash
# =============================================================================
# Step 02b: Bootstrap the self-signed CA (Phase 2)
# =============================================================================
# Creates the cert-manager Issuers + the 10-year root CA, then exports the
# public CA cert to ${REPO_DIR}/ais-edge-ca.crt for distribution to edges.
#
# Idempotent: re-running does NOT regenerate the CA (the existing Certificate
# is unchanged). To rotate the CA, use scripts/rotate-ca.sh (M8).
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

echo "=== 02b: Bootstrap self-signed CA ==="

# 1. Apply the Issuers + CA Certificate
kubectl apply -f "${REPO_DIR}/manifests/01-management/cert-issuers.yaml"

# 2. Wait for the CA Certificate to be Ready
echo "Waiting for CA Certificate 'ais-edge-ca' to be Ready..."
kubectl wait --for=condition=Ready certificate/ais-edge-ca \
    -n cert-manager --timeout=120s

# 3. Wait for the CA ClusterIssuer to be Ready
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

# 4. Export the public CA cert
CA_OUT="${REPO_DIR}/ais-edge-ca.crt"
kubectl get secret -n cert-manager ais-edge-ca-secret \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > "${CA_OUT}"
chmod 644 "${CA_OUT}"

# 5. Verify and print fingerprint
if ! openssl x509 -in "${CA_OUT}" -noout >/dev/null 2>&1; then
    echo "ERROR: exported ais-edge-ca.crt is not a valid x509 cert"
    exit 1
fi

CA_SHA256=$(openssl x509 -in "${CA_OUT}" -noout -fingerprint -sha256 \
    | sed 's/^.*=//')
CA_NOTAFTER=$(openssl x509 -in "${CA_OUT}" -noout -enddate | sed 's/^.*=//')
CA_SUBJECT=$(openssl x509 -in "${CA_OUT}" -noout -subject | sed 's/^.*= //')

echo "=== 02b: Complete ==="
echo "CA cert:        ${CA_OUT}"
echo "Subject:        ${CA_SUBJECT}"
echo "Expires:        ${CA_NOTAFTER}"
echo "SHA-256 fp:     ${CA_SHA256}"
echo ""
echo "This CA cert will be distributed to edge clusters in step 07"
echo "(as a Secret 'ca-bundle' in the xnat-ingest namespace)."
