#!/usr/bin/env bash
# =============================================================================
# Step 05: Create hosted k0s control plane for an edge site
#          Usage: ./05-setup-edge-cluster.sh <edge-entry>
#          Called by install.sh for each edge node, or run manually.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <edge-entry>"
    echo "  edge-entry format: CLUSTER_NAME|NODE_IP|SSH_USER|SSH_KEY|ACCESS_KEY|SECRET_KEY"
    echo "  (install.sh instead exports the config and passes just the edge name)"
    exit 1
fi

# When install.sh has already exported this edge's configuration from
# sites/<site>/values.yaml, the argument is just the edge NAME and there is
# nothing to parse. Calling parse_edge_entry on it would fail ("expected 6
# pipe-separated fields, got 1") and, worse, a successful parse would
# OVERWRITE the exported values with whatever config/edge-nodes.env still
# says — the second source of truth this was meant to remove.
if [ "${AIS_CONFIG_FROM_SITE:-0}" = "1" ]; then
    : "${CLUSTER_NAME:?install.sh must export CLUSTER_NAME}"
    # parse_edge_entry also DERIVES these two from the primitives; do the same
    # here so both call styles leave the script with identical variables.
    # `~` is expanded explicitly: it comes from a YAML value, so the shell
    # never sees it in a position where tilde expansion happens, and ssh would
    # be handed a literal "~/.ssh/id_ed25519" that does not exist.
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    EDGE_SSH="${SSH_USER}@${NODE_IP}"
    SSH_KEY_OPT=""
    [ -n "${SSH_KEY:-}" ] && SSH_KEY_OPT="-i ${SSH_KEY}"
    EDGE_KC="${REPO_DIR}/kubeconfig-${CLUSTER_NAME}"
else
    parse_edge_entry "$1"
fi

echo "=== 05: Creating hosted cluster '${CLUSTER_NAME}' ==="

# Create namespace and cluster.
#
# SKIPPED when charts/mgmt owns the Cluster object, which is the normal path
# now: templates/edge-clusters.yaml renders one per entry in `edges`, with the
# per-site NodePorts and hostnames the hardcoded template below cannot express
# (it pins apiPort 30443 / konnectivityPort 30132, so a second site is
# impossible, and persistence emptyDir, which the chart refuses). Re-applying
# this here would fight Helm for ownership of the same object.
#
# The REST of this script is still required and has no Helm equivalent: the
# control-plane wait, the child kubeconfig with its server: rewritten to the
# ingress, the mgmt-node /etc/hosts entries, and above all the join token,
# which is decoded, re-pointed at the ingress and re-encoded. A Helm-rendered
# token would be re-minted on every upgrade.
if [ "${CLUSTER_CR_MANAGED_BY_HELM:-0}" = "1" ]; then
    echo "05: Cluster object is managed by charts/mgmt — skipping create, using it as-is"
else
kubectl create namespace "${CLUSTER_NAME}" --dry-run=client -o yaml | kubectl apply -f -
render "${REPO_DIR}/manifests/01-management/edge-cluster.yaml.tpl" \
    CLUSTER_NAME "$CLUSTER_NAME" \
    MGMT_NODE_IP "$MGMT_NODE_IP" \
    K0S_API_HOSTNAME "$K0S_API_HOSTNAME" \
    KONNECTIVITY_HOSTNAME "$KONNECTIVITY_HOSTNAME" \
    INGRESS_PORT "$INGRESS_PORT" \
    | kubectl apply -f -
fi

# Wait for control plane
echo "Waiting for control plane pods (may take 2-3 min first time)..."
RETRIES=36
for i in $(seq 1 $RETRIES); do
    # IMPORTANT: with `set -o pipefail` the `grep ... | wc -l` pattern fails
    # the whole pipeline when grep finds nothing (returns 1) — which under
    # `set -e` exits the script silently before the loop can even print its
    # first "Attempt" line. Use `grep -c || true` so no-match yields 0
    # instead of failing the pipe.
    READY=$(kubectl get pods -n "${CLUSTER_NAME}" --no-headers 2>/dev/null \
            | grep -c "1/1" || true)
    [ "$READY" -ge 2 ] && { echo "Control plane ready!"; break; }
    [ $i -eq $RETRIES ] && { echo "ERROR: Control plane not ready"; kubectl get pods -n "${CLUSTER_NAME}"; exit 1; }
    echo "  Attempt $i/$RETRIES..."
    sleep 10
done

# Extract kubeconfig — point it at the Phase 2 TLS hostname.
# This requires /etc/hosts on the management VM to resolve K0S_API_HOSTNAME
# to MGMT_NODE_IP. We add the line idempotently here so the site admin can use
# the kubeconfig without further setup.
kubectl get secret "${CLUSTER_NAME}-kubeconfig" -n "${CLUSTER_NAME}" \
    -o jsonpath='{.data.value}' | base64 -d > "${EDGE_KC}"
chmod 600 "${EDGE_KC}"
sed -i "s|server:.*|server: https://${K0S_API_HOSTNAME}:${INGRESS_PORT}|" "${EDGE_KC}"
echo "Kubeconfig: kubeconfig-${CLUSTER_NAME}  (server: https://${K0S_API_HOSTNAME}:${INGRESS_PORT})"

# Onprem-only: pin the TLS hostnames on the mgmt VM's /etc/hosts so kubectl
# (and anything else on this host) can reach them via MGMT_NODE_IP. In
# cloud topology the LB sits on a different IP than MGMT_NODE_IP, so this
# entry would misroute traffic — real public DNS handles the resolution
# in cloud mode instead.
if [ "${INSTALL_TOPOLOGY:-onprem}" = "onprem" ]; then
    HOSTS_MARKER="# ais-edge phase2 tls hostnames"
    HOSTS_LINE="${MGMT_NODE_IP} ${SEAWEEDFS_HOSTNAME} ${K0S_API_HOSTNAME} ${KONNECTIVITY_HOSTNAME}"
    # Check for the ENTRY, not the marker. A marker left behind by an
    # incomplete teardown would otherwise make this skip, and the node then
    # cannot resolve its own child-cluster API — which surfaces much later as
    # the worker join timing out.
    if ! grep -qF "${K0S_API_HOSTNAME}" /etc/hosts; then
        sudo sed -i "\|${HOSTS_MARKER}|d" /etc/hosts 2>/dev/null || true
        echo "Adding Phase 2 hostnames to management /etc/hosts (sudo)..."
        echo -e "${HOSTS_MARKER}\n${HOSTS_LINE}" | sudo tee -a /etc/hosts >/dev/null
    fi
else
    echo "Cloud topology — skipping management /etc/hosts edit. Mgmt VM resolves"
    echo "  SNI hostnames via the real public DNS that points at the LB VIP."
fi

# Generate join token
kubectl delete jointokenrequest "${CLUSTER_NAME}-token" -n "${CLUSTER_NAME}" --ignore-not-found 2>/dev/null
kubectl delete secret "${CLUSTER_NAME}-token" -n "${CLUSTER_NAME}" --ignore-not-found 2>/dev/null
sleep 2
cat <<EOF | kubectl apply -f -
apiVersion: k0smotron.io/v1beta1
kind: JoinTokenRequest
metadata:
  name: ${CLUSTER_NAME}-token
  namespace: ${CLUSTER_NAME}
spec:
  clusterRef:
    name: ${CLUSTER_NAME}
    namespace: ${CLUSTER_NAME}
EOF

RETRIES=12
for i in $(seq 1 $RETRIES); do
    TOKEN=$(kubectl get secret "${CLUSTER_NAME}-token" -n "${CLUSTER_NAME}" \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || true)
    [ -n "$TOKEN" ] && break
    [ $i -eq $RETRIES ] && { echo "ERROR: Token not generated"; exit 1; }
    echo "  Waiting for token... ($i/$RETRIES)"
    sleep 5
done
# Phase 2: rewrite the URL inside the join token so the worker connects via
# https://${K0S_API_HOSTNAME}:${INGRESS_PORT} (nginx-ingress + SNI passthrough)
# instead of the NodePort. The /etc/hosts entry on the edge VM (added in step
# 06) makes the hostname resolve to MGMT_NODE_IP.
#
# Token format is base64(gzip(yaml-kubeconfig)). The "server:" line inside
# the kubeconfig is what k0s worker uses for the API URL.
if [ -n "${K0S_API_HOSTNAME:-}" ] && [ -n "${INGRESS_PORT:-}" ]; then
    NEW_URL="https://${K0S_API_HOSTNAME}:${INGRESS_PORT}"
    TOKEN=$(echo "$TOKEN" | base64 -d | gunzip \
        | sed "s|server: .*|server: ${NEW_URL}|" \
        | gzip | base64 -w0)
    echo "Join token rewritten: server -> ${NEW_URL}"
fi

echo "$TOKEN" > "${REPO_DIR}/join-token-${CLUSTER_NAME}"
chmod 600 "${REPO_DIR}/join-token-${CLUSTER_NAME}"
echo "Join token saved"

# Note: SeaweedFS S3 identities for edge users are provisioned by step 03
# (the s3.json ConfigMap is built from edge-nodes.env at install time).
# No per-edge step here — credentials defined in edge-nodes.env are already
# active in SeaweedFS by the time we reach this step.

echo "=== 05: Complete for ${CLUSTER_NAME} ==="
