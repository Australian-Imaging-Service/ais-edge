#!/usr/bin/env bash
# Prepare local storage and secrets, then install or upgrade AIS Edge.
# Usage: bash helm/setup.sh <values-file>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$SCRIPT_DIR/edge"
NAMESPACE=ais-edge
RELEASE=edge
VALUES_FILE="${1:-}"

info() { echo "[INFO] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

prompt() {
  local variable=$1 message=$2 default=${3:-} input
  if [[ -n "$default" ]]; then
    read -r -p "$message [$default]: " input
    printf -v "$variable" '%s' "${input:-$default}"
  else
    read -r -p "$message: " input
    printf -v "$variable" '%s' "$input"
  fi
}

prompt_secret() {
  local variable=$1 message=$2 input
  read -r -s -p "$message: " input
  echo
  [[ -n "$input" ]] || error "$message cannot be empty"
  printf -v "$variable" '%s' "$input"
}

json_escape() {
  local value=${1//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s' "$value"
}

command -v kubectl >/dev/null || error "kubectl is required"
command -v helm >/dev/null || error "helm is required"

[[ -n "$VALUES_FILE" ]] || error "Usage: bash helm/setup.sh <values-file>"
[[ -f "$VALUES_FILE" ]] || error "Values file not found: $VALUES_FILE"
VALUES_FILE="$(cd "$(dirname "$VALUES_FILE")" && pwd)/$(basename "$VALUES_FILE")"

CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null) \
  || error "kubectl has no current context"
info "Current kubectl context: $CURRENT_CONTEXT"
read -r -p "Continue with this cluster? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || error "Aborted"

info "Using site values: $VALUES_FILE"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NAMESPACE" app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate namespace "$NAMESPACE" \
  meta.helm.sh/release-name="$RELEASE" \
  meta.helm.sh/release-namespace="$NAMESPACE" \
  --overwrite

if ! kubectl get secret orthanc-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
  echo
  echo "=== Orthanc web credentials (stored in Kubernetes) ==="
  prompt ORTHANC_USER "Orthanc username" "admin"
  prompt_secret ORTHANC_PASSWORD "Orthanc password"
  escaped_orthanc_user=$(json_escape "$ORTHANC_USER")
  escaped_orthanc_password=$(json_escape "$ORTHANC_PASSWORD")
  USERS_JSON="{\"RegisteredUsers\":{\"${escaped_orthanc_user}\":\"${escaped_orthanc_password}\"}}"
  kubectl create secret generic orthanc-credentials \
    --from-literal="users.json=$USERS_JSON" \
    --from-literal="orthanc-user=$ORTHANC_USER" \
    --from-literal="orthanc-password=$ORTHANC_PASSWORD" \
    -n "$NAMESPACE"
else
  info "Reusing existing orthanc-credentials secret"
fi

if ! kubectl get secret samba-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
  echo
  echo "=== Samba credentials (stored in Kubernetes) ==="
  prompt SAMBA_USER "Samba username" "ais-edge"
  prompt_secret SAMBA_PASSWORD "Samba password"
  kubectl create secret generic samba-credentials \
    --from-literal="username=$SAMBA_USER" \
    --from-literal="password=$SAMBA_PASSWORD" \
    -n "$NAMESPACE"
else
  info "Reusing existing samba-credentials secret"
fi

if kubectl get secret xnat-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
  info "Reusing existing xnat-credentials secret"
else
  echo
  echo "=== XNAT credentials (stored in Kubernetes) ==="
  prompt XNAT_SERVER "XNAT server URL"
  prompt XNAT_USER "XNAT username"
  prompt_secret XNAT_PASSWORD "XNAT password"
  kubectl create secret generic xnat-credentials \
    --from-literal="server=$XNAT_SERVER" \
    --from-literal="username=$XNAT_USER" \
    --from-literal="password=$XNAT_PASSWORD" \
    -n "$NAMESPACE"
fi

info "Installing AIS Edge"
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --values "$VALUES_FILE" \
  --rollback-on-failure \
  --timeout 10m

NODE_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
NODE_IP=${NODE_IP:-"<vm-ip>"}
DICOM_NODE_PORT=$(kubectl get service orthanc -n "$NAMESPACE" \
  -o jsonpath='{.spec.ports[?(@.name=="dicom")].nodePort}')
HTTP_NODE_PORT=$(kubectl get service orthanc -n "$NAMESPACE" \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
SHARE_NAME=$(kubectl get deployment samba -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="NAME")].value}')
if UPLOAD_REPLICAS=$(kubectl get deployment upload -n "$NAMESPACE" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null); then
  UPLOAD_STATUS="$UPLOAD_REPLICAS replica(s)"
else
  UPLOAD_STATUS="disabled"
fi

echo
info "AIS Edge is installed"
echo "  Values file:    $VALUES_FILE"
echo "  Orthanc DICOM:  $NODE_IP:$DICOM_NODE_PORT"
echo "  Orthanc web:    http://$NODE_IP:$HTTP_NODE_PORT/ui/app/"
echo "  Samba share:    //$NODE_IP/$SHARE_NAME"
echo "  File drop:      /data/ais-edge/incoming"
echo "  Upload:         $UPLOAD_STATUS"
echo
kubectl get deployments,pods,pvc -n "$NAMESPACE"
