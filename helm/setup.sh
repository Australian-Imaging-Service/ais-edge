#!/usr/bin/env bash
# CIMA-X pipeline setup script.
# Creates all required secrets and installs the Helm chart.
# Run from the repo root: bash helm/setup.sh

set -euo pipefail

CHART_DIR="$(cd "$(dirname "$0")/edge" && pwd)"
VALUES_FILE="${1:-}"

# ── helpers ──────────────────────────────────────────────────────────────────

info()  { echo "[INFO]  $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

prompt() {
    local var="$1" msg="$2" default="${3:-}"
    if [[ -n "$default" ]]; then
        read -r -p "$msg [$default]: " input
        printf -v "$var" '%s' "${input:-$default}"
    else
        read -r -p "$msg: " input
        printf -v "$var" '%s' "$input"
    fi
}

prompt_secret() {
    local var="$1" msg="$2"
    read -r -s -p "$msg: " input
    echo
    printf -v "$var" '%s' "$input"
}

# ── preflight ─────────────────────────────────────────────────────────────────

command -v helm    &>/dev/null || error "helm is not installed"
command -v kubectl &>/dev/null || error "kubectl is not installed"

CURRENT_CONTEXT=$(kubectl config current-context)
info "Current kubectl context: $CURRENT_CONTEXT"
read -r -p "Continue with this context? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || error "Aborted. Switch context with: kubectl config use-context <name>"

# ── configuration ─────────────────────────────────────────────────────────────

echo
echo "=== Site configuration ==="
prompt NAMESPACE    "Namespace"            "ais-edge"
prompt HOST_PATH    "Host data directory"  "/data/ais-edge"
prompt CAPACITY     "Storage capacity"     "1500Gi"
prompt SHARE_NAME   "Samba share name"     "edge"
prompt DICOM_PORT   "DICOM NodePort"       "30042"
prompt HTTP_PORT    "HTTP NodePort"        "30842"

echo
echo "=== Orthanc credentials ==="
prompt       ORTHANC_USER "Orthanc admin username" "admin"
prompt_secret ORTHANC_PASS "Orthanc admin password"

echo
echo "=== Samba credentials ==="
prompt        SAMBA_USER "Samba username"
prompt_secret SAMBA_PASS "Samba password"

echo
echo "=== Credentials for XNAT upload ==="
prompt        XNAT_SERVER "XNAT server URL"
prompt        XNAT_USER   "XNAT username"
prompt_secret XNAT_PASS   "XNAT password"


# ── namespace ─────────────────────────────────────────────────────────────────

echo
info "Creating namespace $NAMESPACE..."
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    kubectl create namespace "$NAMESPACE"
fi

# Always apply Helm ownership labels so the chart can manage the namespace
kubectl label namespace "$NAMESPACE" app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate namespace "$NAMESPACE" \
    meta.helm.sh/release-name=edge \
    meta.helm.sh/release-namespace="$NAMESPACE" \
    --overwrite

# ── secrets ───────────────────────────────────────────────────────────────────

info "Creating orthanc-credentials secret..."
USERS_JSON="{\"RegisteredUsers\": {\"${ORTHANC_USER}\": \"${ORTHANC_PASS}\"}}"
kubectl create secret generic orthanc-credentials \
    --from-literal="users.json=${USERS_JSON}" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

info "Creating samba-credentials secret..."
kubectl create secret generic samba-credentials \
    --from-literal="username=${SAMBA_USER}" \
    --from-literal="password=${SAMBA_PASS}" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

info "Creating xnat-credentials secret..."
kubectl create secret generic xnat-credentials \
    --from-literal="server=${XNAT_SERVER}" \
    --from-literal="username=${XNAT_USER}" \
    --from-literal="password=${XNAT_PASS}" \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -


# ── helm install ──────────────────────────────────────────────────────────────

echo
info "Installing Helm chart..."

EXTRA_ARGS=()
if [[ -n "$VALUES_FILE" ]]; then
    EXTRA_ARGS+=(-f "$VALUES_FILE")
fi

helm upgrade --install edge "$CHART_DIR" \
    --namespace "$NAMESPACE" \
    --set namespace="$NAMESPACE" \
    --set storage.hostPath="$HOST_PATH" \
    --set storage.capacity="$CAPACITY" \
    --set samba.shareName="$SHARE_NAME" \
    --set orthanc.nodePorts.dicom="$DICOM_PORT" \
    --set orthanc.nodePorts.http="$HTTP_PORT" \
    "${EXTRA_ARGS[@]}"

# ── done ──────────────────────────────────────────────────────────────────────

echo
info "Done. Check pod status with:"
echo "    kubectl get pods -n $NAMESPACE"
