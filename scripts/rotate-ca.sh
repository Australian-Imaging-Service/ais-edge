#!/usr/bin/env bash
# =============================================================================
# CA Rotation — Bundled-CA Transition (Phase 2 / M8)
# =============================================================================
# Rotates the self-signed root CA used to sign all server certs in the AIS
# Edge stack. Designed for two reasons to run:
#   (a) Approaching the 10-year CA expiry (year 9 is the latest you should
#       leave it).
#   (b) Suspected compromise of the CA private key.
#
# This is a TWO-PHASE operation. Phase 1 distributes the new CA alongside
# the old one (so edges trust BOTH). Phase 2, after a grace period, retires
# the old CA. NEVER run phase=2 immediately after phase=1 — the grace period
# lets running clients refresh their bundle before the old CA disappears.
#
#   ./rotate-ca.sh --dry-run         show what would happen
#   ./rotate-ca.sh --phase=1         issue NEW CA + push BUNDLE (old + new)
#   <wait 14-30 days>
#   ./rotate-ca.sh --phase=2         switch Issuer to NEW + drop old from bundle
#
# Caveats:
#   - Server certs (seaweedfs-tls, etc.) auto-renew at duration-renewBefore
#     using whichever CA the Issuer currently references. Phase 2 cuts over
#     the Issuer; new certs from that point are signed by the new CA.
#   - Pods that mount the ca-bundle Secret use a projected volume — the
#     mount sees Secret updates within ~1 minute (kubelet sync interval).
#     We still trigger a rollout-restart for determinism.
#   - This script touches BOTH the management cluster (CA Issuer + Cert)
#     AND every edge cluster's ca-bundle Secret. It iterates the `edges:`
#     list in sites/<site>/values.yaml — the SAME list install.sh rendered
#     the charts from, so it can never rotate a different set of edges than
#     the deployment actually has.
# =============================================================================
set -euo pipefail
# Only the helpers: the edge list comes from the site file below, so loading
# any other configuration here could only contradict it.
AIS_NO_CONFIG=1 source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

DRY_RUN=false
PHASE=""
SITE=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --phase=1) PHASE=1 ;;
        --phase=2) PHASE=2 ;;
        -*) echo "Unknown arg: $arg"; exit 1 ;;
        *)  SITE="$arg" ;;
    esac
done

if [ -z "$PHASE" ] || [ -z "$SITE" ]; then
    echo "Usage: $0 <site> --phase=1 [--dry-run]   issue new CA, push bundle"
    echo "       $0 <site> --phase=2 [--dry-run]   switch Issuer, drop old CA"
    echo
    echo "  <site> is a directory under sites/ — the same one install.sh takes."
    echo "  Its edges: list is what gets rotated."
    exit 1
fi

# --- the edge list, from the SITE FILE ---------------------------------------
# Read once, up front, so a malformed or empty edges: list fails before any CA
# has been issued. A rotation that gets halfway — new CA minted, only some
# edges holding the new bundle — leaves the fleet unable to verify each other.
VALUES="${REPO_DIR}/sites/${SITE}/values.yaml"
[ -f "$VALUES" ] || { echo "ERROR: no such site: ${VALUES}" >&2; exit 1; }

mapfile -t EDGE_NAMES < <(python3 - "$VALUES" <<'PY'
import sys, yaml
v = yaml.safe_load(open(sys.argv[1])) or {}
for e in (v.get("edges") or []):
    n = (e or {}).get("name")
    if n:
        print(n)
PY
)
if [ "${#EDGE_NAMES[@]}" -eq 0 ]; then
    echo "ERROR: sites/${SITE}/values.yaml lists no edges." >&2
    echo >&2
    echo "       The \`edges:\` list lives in the MANAGEMENT site, not an edge" >&2
    echo "       site. If you passed an edge here, pass the management one" >&2
    echo "       instead — it is the site that knows the whole fleet." >&2
    echo >&2
    echo "       Refusing to continue: rotating the management CA without" >&2
    echo "       pushing the bundle to every edge leaves the fleet unable to" >&2
    echo "       verify it." >&2
    exit 1
fi

run() {
    if $DRY_RUN; then
        echo "[dry-run] $*"
    else
        eval "$@"
    fi
}

OLD_SECRET="ais-edge-ca-secret"
OLD_CERT="ais-edge-ca"
NEW_SECRET="ais-edge-ca-2-secret"
NEW_CERT="ais-edge-ca-2"
ISSUER="ais-edge-ca-issuer"
BUNDLE_OUT="${REPO_DIR}/ca-bundle.crt"

# -----------------------------------------------------------------------------
phase_1() {
    echo "=== Phase 1: issue NEW CA + distribute bundle (old + new) ==="

    # 1. Create the new CA Certificate (signed by selfsigned-bootstrap)
    cat <<MANIFEST | run "kubectl apply -f -"
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${NEW_CERT}
  namespace: cert-manager
spec:
  isCA: true
  commonName: AIS Edge Root CA (rotation $(date -I))
  secretName: ${NEW_SECRET}
  duration: 87600h
  renewBefore: 8760h
  privateKey:
    algorithm: RSA
    size: 4096
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
    group: cert-manager.io
MANIFEST

    run "kubectl wait --for=condition=Ready certificate/${NEW_CERT} -n cert-manager --timeout=120s"

    # 2. Build the bundle: old CA + new CA, in that order so old is presented
    # first (clients tend to short-circuit on first match).
    if $DRY_RUN; then
        echo "[dry-run] would build ${BUNDLE_OUT} from ${OLD_SECRET} + ${NEW_SECRET}"
    else
        OLD_CA=$(kubectl get secret -n cert-manager "${OLD_SECRET}" -o jsonpath='{.data.ca\.crt}' | base64 -d)
        NEW_CA=$(kubectl get secret -n cert-manager "${NEW_SECRET}" -o jsonpath='{.data.ca\.crt}' | base64 -d)
        printf '%s\n%s\n' "$OLD_CA" "$NEW_CA" > "${BUNDLE_OUT}"
        chmod 644 "${BUNDLE_OUT}"
        echo "Bundle written: ${BUNDLE_OUT}"
        openssl crl2pkcs7 -nocrl -certfile "${BUNDLE_OUT}" 2>/dev/null \
            | openssl pkcs7 -print_certs -noout 2>/dev/null \
            | grep -E "subject=|issuer=" || true
    fi

    # 3. Push the bundle to every edge cluster's ca-bundle Secret + restart
    for CLUSTER_NAME in "${EDGE_NAMES[@]}"; do
        EDGE_KC="${REPO_DIR}/kubeconfig-${CLUSTER_NAME}"
        echo ""
        echo "--- Updating edge: ${CLUSTER_NAME} ---"
        if [ ! -f "${EDGE_KC}" ]; then
            echo "  (skipped: no kubeconfig at ${EDGE_KC})"
            continue
        fi
        run "KUBECONFIG='${EDGE_KC}' kubectl create secret generic ca-bundle \
            --namespace xnat-ingest \
            --from-file=ca.crt='${BUNDLE_OUT}' \
            --dry-run=client -o yaml | KUBECONFIG='${EDGE_KC}' kubectl apply -f -"
        run "KUBECONFIG='${EDGE_KC}' kubectl rollout restart deployment/s3-uploader -n xnat-ingest"
    done

    cat <<EOF

=== Phase 1 complete ===
The bundle (old + new CA) is on every edge cluster. Both CAs are trusted.
Server certs (seaweedfs-tls, etc.) are STILL signed by the OLD CA — clients
keep working without interruption.

NEXT: leave the system running for the grace period (recommend 14-30 days).
This buffers any briefly-disconnected pods that may be using the old bundle.

When ready, run:
    ${0} --phase=2

EOF
}

# -----------------------------------------------------------------------------
phase_2() {
    echo "=== Phase 2: switch Issuer to NEW CA + retire old ==="

    # 1. Repoint the CA Issuer at the NEW secret. cert-manager will re-issue
    # server certs from the new CA at next renewal (or immediately if you
    # delete the existing Certificate resources to force re-issue).
    cat <<MANIFEST | run "kubectl apply -f -"
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${ISSUER}
spec:
  ca:
    secretName: ${NEW_SECRET}
MANIFEST

    # 2. (optional but recommended) Force renewal of server certs so they
    # are immediately re-signed by the new CA, instead of waiting for the
    # natural renewal window.
    echo ""
    echo "Forcing re-issue of seaweedfs-tls (and any other ais-edge-ca-issued certs)..."
    for cert in $(kubectl get certificate -A -o jsonpath='{range .items[?(@.spec.issuerRef.name=="ais-edge-ca-issuer")]}{.metadata.namespace}/{.metadata.name} {end}'); do
        ns="${cert%/*}"
        name="${cert#*/}"
        echo "  re-issuing ${ns}/${name}"
        run "kubectl annotate --overwrite certificate/${name} -n ${ns} cert-manager.io/issue-temporary-certificate-"
        run "kubectl delete --ignore-not-found secret/${name} -n ${ns}"
    done

    # 3. Replace the bundle with ONLY the new CA — old is retired.
    if $DRY_RUN; then
        echo "[dry-run] would write new-only bundle to ${BUNDLE_OUT}"
    else
        kubectl get secret -n cert-manager "${NEW_SECRET}" -o jsonpath='{.data.ca\.crt}' | base64 -d > "${BUNDLE_OUT}"
        chmod 644 "${BUNDLE_OUT}"
        cp "${BUNDLE_OUT}" "${REPO_DIR}/ais-edge-ca.crt"
        echo "New ais-edge-ca.crt written (replaces old)"
    fi

    # 4. Push the new-only bundle to edges + restart consumers
    for CLUSTER_NAME in "${EDGE_NAMES[@]}"; do
        EDGE_KC="${REPO_DIR}/kubeconfig-${CLUSTER_NAME}"
        echo ""
        echo "--- Finalising edge: ${CLUSTER_NAME} ---"
        if [ ! -f "${EDGE_KC}" ]; then
            echo "  (skipped: no kubeconfig at ${EDGE_KC})"
            continue
        fi
        run "KUBECONFIG='${EDGE_KC}' kubectl create secret generic ca-bundle \
            --namespace xnat-ingest \
            --from-file=ca.crt='${BUNDLE_OUT}' \
            --dry-run=client -o yaml | KUBECONFIG='${EDGE_KC}' kubectl apply -f -"
        run "KUBECONFIG='${EDGE_KC}' kubectl rollout restart deployment/s3-uploader -n xnat-ingest"
    done

    # 5. Optionally retire the old CA Certificate resource. Leaving it
    # for a release cycle is safer in case rollback is needed.
    cat <<EOF

=== Phase 2 complete ===
- ClusterIssuer ${ISSUER} now uses ${NEW_SECRET}
- Server certs forced to re-issue from the new CA
- Edge ca-bundle Secrets updated to NEW-only
- ais-edge-ca.crt regenerated

The OLD CA Certificate resource (${OLD_CERT}) is left in place for safety.
Once you are confident the cutover is clean (give it a week of monitoring),
run:
    kubectl delete certificate ${OLD_CERT} -n cert-manager
    kubectl delete secret ${OLD_SECRET} -n cert-manager

The OLD CA private key is then unrecoverable.
EOF
}

case "$PHASE" in
    1) phase_1 ;;
    2) phase_2 ;;
esac
