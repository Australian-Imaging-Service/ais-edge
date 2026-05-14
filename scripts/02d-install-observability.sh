#!/usr/bin/env bash
# =============================================================================
# Step 02d: Install the observability stack on the management cluster
# =============================================================================
# Stack:
#   * Loki                    log store (S3 backend = SeaweedFS logs-bucket)
#   * Prometheus              metrics store (kube-prometheus-stack chart)
#   * Alertmanager            alert routing (config from ALERT_* env vars)
#   * Grafana                 dashboards UI
#   * kube-state-metrics      K8s object metrics
#   * Vector (mgmt-side)      log shipper DaemonSet on the mgmt node
#
# This step is OPTIONAL. If ALERT_EMAIL_TO is unset in management.env we
# skip cleanly with an explanatory message. If it's set, we install the
# full stack and add two new SNI routes to the existing nginx-ingress
# (grafana.aisedge.local + loki.aisedge.local) — both signed by ais-edge-ca.
#
# Idempotent: helm upgrade --install reapplies values. Re-running after
# config changes (e.g. new email recipient) takes effect on next pod
# restart.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

# Skip cleanly if observability isn't configured.
if [ -z "${ALERT_EMAIL_TO:-}" ]; then
    echo "=== 02d: Observability stack — SKIPPED ==="
    echo "  Set ALERT_EMAIL_TO (and SMTP_* vars) in config/management.env to enable."
    echo "  All other Phase 1/Phase 2 functionality works without this stack."
    exit 0
fi

# Validate the rest of the observability vars only once we know the stack
# is wanted.
for var in ALERT_EMAIL_FROM ALERT_SMTP_HOST ALERT_SMTP_PORT \
           GRAFANA_HOSTNAME LOKI_HOSTNAME GRAFANA_ADMIN_USER \
           GRAFANA_ADMIN_PASSWORD OBSERVABILITY_RETENTION_DAYS \
           LOKI_S3_ACCESS_KEY LOKI_S3_SECRET_KEY LOGS_BUCKET; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: ${var} must be set in config/management.env when ALERT_EMAIL_TO is set"
        exit 1
    fi
done

echo "=== 02d: Installing observability stack ==="
echo "  Grafana    https://${GRAFANA_HOSTNAME}     (admin: ${GRAFANA_ADMIN_USER})"
echo "  Loki       https://${LOKI_HOSTNAME}        (Vector push endpoint)"
echo "  Alerts     ${ALERT_EMAIL_TO}"
echo "  Retention  ${OBSERVABILITY_RETENTION_DAYS} days"
echo ""

# 1. Namespace
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

# 2. Helm repos
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add vector https://helm.vector.dev >/dev/null 2>&1 || true
helm repo update grafana prometheus-community vector

# 3. Grafana admin Secret (consumed by kube-prometheus-stack values)
kubectl create secret generic grafana-admin-credentials \
    --namespace observability \
    --from-literal=admin-user="${GRAFANA_ADMIN_USER}" \
    --from-literal=admin-password="${GRAFANA_ADMIN_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

# 4. Alertmanager config Secret (rendered from env vars)
TMP_AM=$(mktemp /tmp/alertmanager-XXXXXX.yaml)
trap "rm -f $TMP_AM" EXIT
render "${REPO_DIR}/manifests/01-management/observability/alertmanager-config.yaml.tpl" \
    ALERT_EMAIL_TO         "$ALERT_EMAIL_TO" \
    ALERT_EMAIL_FROM       "$ALERT_EMAIL_FROM" \
    ALERT_SMTP_HOST        "$ALERT_SMTP_HOST" \
    ALERT_SMTP_PORT        "$ALERT_SMTP_PORT" \
    ALERT_SMTP_USERNAME    "${ALERT_SMTP_USERNAME:-}" \
    ALERT_SMTP_PASSWORD    "${ALERT_SMTP_PASSWORD:-}" \
    ALERT_SMTP_REQUIRE_TLS "${ALERT_SMTP_REQUIRE_TLS:-true}" \
    ALERT_SLACK_WEBHOOK    "${ALERT_SLACK_WEBHOOK:-https://hooks.slack.com/disabled}" \
    > "$TMP_AM"

kubectl create secret generic alertmanager-aisedge-config \
    --namespace observability \
    --from-file=alertmanager.yaml="$TMP_AM" \
    --dry-run=client -o yaml | kubectl apply -f -

# 5. kube-prometheus-stack (Prometheus + Grafana + Alertmanager + KSM)
TMP_KPS=$(mktemp /tmp/kps-values-XXXXXX.yaml)
trap "rm -f $TMP_AM $TMP_KPS" EXIT
render "${REPO_DIR}/manifests/01-management/observability/kube-prometheus-stack-values.yaml.tpl" \
    PROM_RETENTION_DAYS "${OBSERVABILITY_RETENTION_DAYS}" \
    > "$TMP_KPS"

helm upgrade --install kube-prometheus-stack \
    prometheus-community/kube-prometheus-stack \
    --namespace observability \
    --values "$TMP_KPS" \
    --wait --timeout 600s

# 6. Loki ruler rules (must exist BEFORE Loki starts — singleBinary mounts
# this ConfigMap as a volume; without it, the pod fails to schedule).
kubectl apply -f "${REPO_DIR}/manifests/01-management/observability/loki-ruler-rules.yaml"

# 7. Loki (single-binary, S3 backend, ruler enabled)
TMP_LOKI=$(mktemp /tmp/loki-values-XXXXXX.yaml)
trap "rm -f $TMP_AM $TMP_KPS $TMP_LOKI" EXIT
LOKI_RETENTION_HOURS=$((OBSERVABILITY_RETENTION_DAYS * 24))
render "${REPO_DIR}/manifests/01-management/observability/loki-values.yaml.tpl" \
    LOKI_RETENTION_HOURS "$LOKI_RETENTION_HOURS" \
    LOGS_BUCKET          "$LOGS_BUCKET" \
    LOKI_S3_ACCESS_KEY   "$LOKI_S3_ACCESS_KEY" \
    LOKI_S3_SECRET_KEY   "$LOKI_S3_SECRET_KEY" \
    > "$TMP_LOKI"

helm upgrade --install loki grafana/loki \
    --namespace observability \
    --values "$TMP_LOKI" \
    --wait --timeout 600s || {
    echo "WARNING: loki helm install timed out — check 'kubectl get pods -n observability'"
}

# 7. Vector (mgmt-side DaemonSet)
TMP_VECT=$(mktemp /tmp/vector-values-XXXXXX.yaml)
trap "rm -f $TMP_AM $TMP_KPS $TMP_LOKI $TMP_VECT" EXIT
render "${REPO_DIR}/manifests/01-management/observability/vector-mgmt-values.yaml.tpl" \
    CLUSTER_LABEL "mgmt" \
    > "$TMP_VECT"

helm upgrade --install vector-mgmt vector/vector \
    --namespace observability \
    --values "$TMP_VECT" \
    --wait --timeout 300s

# 8. TLS Certificates for Grafana + Loki
render "${REPO_DIR}/manifests/01-management/observability/tls-certs.yaml.tpl" \
    GRAFANA_HOSTNAME "$GRAFANA_HOSTNAME" \
    LOKI_HOSTNAME    "$LOKI_HOSTNAME" \
    MGMT_NODE_IP     "$MGMT_NODE_IP" \
    | kubectl apply -f -

echo "Waiting for grafana-tls + loki-tls certs to be Ready..."
kubectl wait --for=condition=Ready certificate/grafana-tls -n observability --timeout=120s
kubectl wait --for=condition=Ready certificate/loki-tls    -n observability --timeout=120s

# 9. Ingress routes (adds SNI hostnames to the existing :443 listener)
render "${REPO_DIR}/manifests/01-management/observability/observability-ingress.yaml.tpl" \
    GRAFANA_HOSTNAME "$GRAFANA_HOSTNAME" \
    LOKI_HOSTNAME    "$LOKI_HOSTNAME" \
    | kubectl apply -f -

# 10. PrometheusRule files for K8s/cert-manager-derived alerts. Alerts
# derived from JSON pipeline events live in loki-ruler-rules.yaml (already
# applied above before Loki started).
kubectl apply -f "${REPO_DIR}/manifests/01-management/observability/alerts/"

# 10b. Cross-namespace ServiceMonitors that depend on the kube-prometheus
# -stack CRDs being installed (which only happens in this step). SeaweedFS
# (deployed in step 03) ships its own /metrics on a separate Service; this
# is the operator-facing object that wires that Service into Prometheus.
kubectl apply -f "${REPO_DIR}/manifests/01-management/observability/seaweedfs-servicemonitor.yaml"

# 11. Dashboards as ConfigMaps with the grafana_dashboard label
for f in "${REPO_DIR}/manifests/01-management/observability/dashboards/"*.json; do
    name="grafana-dashboard-$(basename "$f" .json)"
    kubectl create configmap "$name" \
        --namespace observability \
        --from-file="$(basename "$f")=$f" \
        --dry-run=client -o yaml \
        | kubectl label --local -f - grafana_dashboard=1 -o yaml \
        | kubectl annotate --local -f - grafana_dashboard_folder='AIS Edge' -o yaml \
        | kubectl apply -f -
done

# 12. Add /etc/hosts entries on the mgmt node for the new hostnames so the
# operator can reach Grafana via curl/browser without a DNS server.
HOSTS_MARKER="# ais-edge observability hostnames"
HOSTS_LINE="${MGMT_NODE_IP} ${GRAFANA_HOSTNAME} ${LOKI_HOSTNAME}"
if ! grep -qF "${HOSTS_MARKER}" /etc/hosts; then
    echo -e "${HOSTS_MARKER}\n${HOSTS_LINE}" | sudo tee -a /etc/hosts >/dev/null
fi

# 13. Generate per-edge Loki bearer tokens and store as a Secret on mgmt.
# 07b will copy these into each child cluster as Vector's auth Secret.
for entry in "${EDGE_NODES[@]}"; do
    parse_edge_entry "$entry"
    SECRET_NAME="loki-push-token-${CLUSTER_NAME}"
    if ! kubectl get secret "$SECRET_NAME" -n observability >/dev/null 2>&1; then
        TOKEN=$(openssl rand -base64 32 | tr -d '\n')
        kubectl create secret generic "$SECRET_NAME" \
            --namespace observability \
            --from-literal=token="$TOKEN"
        echo "Generated Loki push token for ${CLUSTER_NAME}"
    fi
done

echo ""
echo "=== 02d: Complete ==="
echo "  Grafana:     https://${GRAFANA_HOSTNAME}/  (admin: ${GRAFANA_ADMIN_USER})"
echo "  Loki:        https://${LOKI_HOSTNAME}/     (Vector push endpoint)"
echo "  Prometheus:  kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090"
echo "  Alertmgr:    kubectl port-forward -n observability svc/kube-prometheus-stack-alertmanager 9093:9093"
