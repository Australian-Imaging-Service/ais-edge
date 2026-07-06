#!/usr/bin/env bash
# =============================================================================
# Step 02d: Install the observability stack (single-node tier-1 appliance)
# =============================================================================
# Stack (everything runs on ONE k0s node):
#   * Loki                    log store (FILESYSTEM backend on a local-path PVC)
#   * Prometheus              metrics store (kube-prometheus-stack chart)
#   * Alertmanager            alert routing (config from ALERT_* env vars)
#   * Grafana                 dashboards UI, exposed on a NodePort
#   * kube-state-metrics      K8s object metrics
#   * Vector                  the single log-shipper DaemonSet for the node
#
# This step is OPTIONAL. If ALERT_EMAIL_TO is unset in management.env we
# skip cleanly with an explanatory message. If it's set, we install the
# full stack. There is NO nginx-ingress and NO cert-manager dependency:
# Grafana is reached directly on a NodePort, and Vector pushes to the
# in-cluster Loki Service over plain HTTP.
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
    echo "  All other functionality works without this stack."
    exit 0
fi

# Defaults for the two knobs this step renders itself.
GRAFANA_NODEPORT="${GRAFANA_NODEPORT:-30030}"
OBSERVABILITY_RETENTION_DAYS="${OBSERVABILITY_RETENTION_DAYS:-30}"

# Validate the rest of the observability vars only once we know the stack
# is wanted.
for var in ALERT_EMAIL_FROM ALERT_SMTP_HOST ALERT_SMTP_PORT \
           GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: ${var} must be set in config/management.env when ALERT_EMAIL_TO is set"
        exit 1
    fi
done

# Node IP the site admin uses to reach Grafana's NodePort.
NODE_IP="${MGMT_NODE_IP:-<NODE_IP>}"

echo "=== 02d: Installing observability stack (single node) ==="
echo "  Grafana    http://${NODE_IP}:${GRAFANA_NODEPORT}   (admin: ${GRAFANA_ADMIN_USER})"
echo "  Loki       http://loki.observability.svc.cluster.local:3100  (in-cluster Vector push endpoint)"
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

# 5. kube-prometheus-stack (Prometheus + Grafana + Alertmanager + KSM).
# Grafana is exposed on a fixed NodePort — no ingress.
TMP_KPS=$(mktemp /tmp/kps-values-XXXXXX.yaml)
trap "rm -f $TMP_AM $TMP_KPS" EXIT
render "${REPO_DIR}/manifests/01-management/observability/kube-prometheus-stack-values.yaml.tpl" \
    PROM_RETENTION_DAYS "${OBSERVABILITY_RETENTION_DAYS}" \
    GRAFANA_NODEPORT    "${GRAFANA_NODEPORT}" \
    > "$TMP_KPS"

helm upgrade --install kube-prometheus-stack \
    prometheus-community/kube-prometheus-stack \
    --namespace observability \
    --values "$TMP_KPS" \
    --wait --timeout 600s

# 6. Loki ruler rules (must exist BEFORE Loki starts — singleBinary mounts
# this ConfigMap as a volume; without it, the pod fails to schedule).
kubectl apply -f "${REPO_DIR}/manifests/01-management/observability/loki-ruler-rules.yaml"

# 7. Loki (single-binary, FILESYSTEM backend on a local-path PVC, ruler enabled)
TMP_LOKI=$(mktemp /tmp/loki-values-XXXXXX.yaml)
trap "rm -f $TMP_AM $TMP_KPS $TMP_LOKI" EXIT
LOKI_RETENTION_HOURS=$((OBSERVABILITY_RETENTION_DAYS * 24))
render "${REPO_DIR}/manifests/01-management/observability/loki-values.yaml.tpl" \
    LOKI_RETENTION_HOURS         "$LOKI_RETENTION_HOURS" \
    OBSERVABILITY_RETENTION_DAYS "$OBSERVABILITY_RETENTION_DAYS" \
    > "$TMP_LOKI"

helm upgrade --install loki grafana/loki \
    --namespace observability \
    --values "$TMP_LOKI" \
    --wait --timeout 600s || {
    echo "WARNING: loki helm install timed out — check 'kubectl get pods -n observability'"
}

# 8. Vector (the single log-shipper DaemonSet for the whole node). Pushes to
# the in-cluster Loki Service over plain HTTP. cluster label = "mgmt" keeps
# the dashboards' {cluster=...} scoping intact.
TMP_VECT=$(mktemp /tmp/vector-values-XXXXXX.yaml)
trap "rm -f $TMP_AM $TMP_KPS $TMP_LOKI $TMP_VECT" EXIT
render "${REPO_DIR}/manifests/01-management/observability/vector-mgmt-values.yaml.tpl" \
    CLUSTER_LABEL "mgmt" \
    > "$TMP_VECT"

helm upgrade --install vector-mgmt vector/vector \
    --namespace observability \
    --values "$TMP_VECT" \
    --wait --timeout 300s

# 9. PrometheusRule files for K8s-metric-derived alerts. Alerts derived from
# JSON pipeline events live in loki-ruler-rules.yaml (already applied above
# before Loki started).
kubectl apply -f "${REPO_DIR}/manifests/01-management/observability/alerts/"

# 10. Dashboards as ConfigMaps with the grafana_dashboard label
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

echo ""
echo "=== 02d: Complete ==="
echo "  Grafana:     http://${NODE_IP}:${GRAFANA_NODEPORT}/   (admin: ${GRAFANA_ADMIN_USER})"
echo "  Prometheus:  kubectl port-forward -n observability svc/kube-prometheus-stack-prometheus 9090:9090"
echo "  Alertmgr:    kubectl port-forward -n observability svc/kube-prometheus-stack-alertmanager 9093:9093"
echo ""
echo "  Verify logs: Grafana -> Explore -> Loki -> {namespace=\"xnat-ingest\"} or {namespace=\"xnat-upload\"}"
