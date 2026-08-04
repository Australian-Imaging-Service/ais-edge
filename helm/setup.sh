#!/usr/bin/env bash
# Prepare local storage and secrets, then install or upgrade AIS Edge.
# Usage: bash helm/setup.sh <values-file>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$SCRIPT_DIR/edge"
RELEASE=edge
VALUES_FILE="${1:-}"
# NAMESPACE is derived from the chart + site values further down, not
# hardcoded here: every template addresses .Values.namespace, so a site that
# overrides it would otherwise get its Secrets created in one namespace while
# its workloads render into another.
NAMESPACE=

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

# Ask the chart itself which namespace it renders into, so this script and the
# templates can never disagree. templates/namespace.yaml is just
# `name: {{ .Values.namespace }}`, which makes it the authoritative answer for
# whatever the site values file happens to set.
NAMESPACE=$(helm template "$RELEASE" "$CHART_DIR" \
  --values "$VALUES_FILE" \
  --show-only templates/namespace.yaml 2>/dev/null \
  | awk '/^  name:/ {print $2; exit}')
[[ -n "$NAMESPACE" ]] || error "Could not determine the namespace from $VALUES_FILE"
info "Target namespace: $NAMESPACE"

RENDERED_CHART=$(helm template "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --values "$VALUES_FILE")

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

# Only prompt when the rendered chart actually contains a samba Deployment
# (samba.enabled). Same gate as the s3sync credentials below — no point asking
# an operator for an SMB password on a site that has no share.
if grep -q '^  name: samba$' <<< "$RENDERED_CHART"; then
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

if grep -q '^  name: s3sync$' <<< "$RENDERED_CHART"; then
  if kubectl get secret s3-credentials -n "$NAMESPACE" >/dev/null 2>&1; then
    info "Reusing existing s3-credentials secret"
  else
    echo
    echo "=== AWS credentials for S3 sync (stored in Kubernetes) ==="
    prompt AWS_ACCESS_KEY_ID "AWS access key ID"
    prompt_secret AWS_SECRET_ACCESS_KEY "AWS secret access key"
    prompt AWS_DEFAULT_REGION "AWS region" "ap-southeast-2"
    kubectl create secret generic s3-credentials \
      --from-literal="AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" \
      --from-literal="AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" \
      --from-literal="AWS_DEFAULT_REGION=$AWS_DEFAULT_REGION" \
      -n "$NAMESPACE"
  fi
fi

info "Installing AIS Edge"
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --values "$VALUES_FILE" \
  --atomic \
  --timeout 10m

NODE_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
NODE_IP=${NODE_IP:-"<vm-ip>"}
DICOM_NODE_PORT=$(kubectl get service orthanc -n "$NAMESPACE" \
  -o jsonpath='{.spec.ports[?(@.name=="dicom")].nodePort}')
HTTP_NODE_PORT=$(kubectl get service orthanc -n "$NAMESPACE" \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
if SHARE_NAME=$(kubectl get deployment samba -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="NAME")].value}' 2>/dev/null) \
  && [[ -n "$SHARE_NAME" ]]; then
  SAMBA_STATUS="//$NODE_IP/$SHARE_NAME"
else
  SAMBA_STATUS="disabled"
fi
if UPLOAD_REPLICAS=$(kubectl get deployment upload -n "$NAMESPACE" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null); then
  UPLOAD_STATUS="$UPLOAD_REPLICAS replica(s)"
else
  UPLOAD_STATUS="disabled"
fi
if kubectl get deployment s3sync -n "$NAMESPACE" >/dev/null 2>&1; then
  S3_STATUS="enabled"
else
  S3_STATUS="disabled"
fi

echo
info "AIS Edge is installed"
echo "  Values file:    $VALUES_FILE"
echo "  Orthanc DICOM:  $NODE_IP:$DICOM_NODE_PORT"
echo "  Orthanc web:    http://$NODE_IP:$HTTP_NODE_PORT/ui/app/"
echo "  Samba share:    $SAMBA_STATUS"
echo "  File drop:      /data/ais-edge/incoming"
echo "  Upload:         $UPLOAD_STATUS"
echo "  S3 sync:        $S3_STATUS"
echo
kubectl get deployments,pods,pvc -n "$NAMESPACE"
