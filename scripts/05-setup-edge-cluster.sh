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

# Configuration comes from sites/<site>/values.yaml, exported by install.sh.
# There is no second source: the `else parse_edge_entry "$1"` branch that used
# to sit here read config/edge-nodes.env, which could contradict the site file
# the charts were rendered from.
: "${CLUSTER_NAME:?install.sh must export CLUSTER_NAME}"
# `~` is expanded explicitly: it comes from a YAML value, so the shell never
# sees it in a position where tilde expansion happens, and ssh would be handed
# a literal "~/.ssh/id_ed25519" that does not exist.
SSH_KEY="${SSH_KEY/#\~/$HOME}"
EDGE_SSH="${SSH_USER}@${NODE_IP}"
SSH_KEY_OPT=""
[ -n "${SSH_KEY:-}" ] && SSH_KEY_OPT="-i ${SSH_KEY}"
EDGE_KC="${REPO_DIR}/kubeconfig-${CLUSTER_NAME}"

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
    # ALWAYS REWRITE. Two earlier guards were both wrong in the same way:
    # keying on the marker made a stale block permanent, and keying on
    # K0S_API_HOSTNAME being present only checked ONE of the three names — so
    # when the konnectivity prefix changed (konnect- -> konnectivity-, to match
    # what the chart actually serves) the API name still matched, this skipped,
    # and the line kept a konnectivity host that resolves to nothing.
    #
    # The old delete was also half a delete: `sed \|MARKER|d` removes the
    # comment but NOT the entry line under it, so a re-run orphaned the old
    # addresses and appended a second pair. `,+1d` takes both.
    echo "Pinning Phase 2 hostnames in management /etc/hosts (sudo)..."
    sudo sed -i "\|^${HOSTS_MARKER}\$|,+1d" /etc/hosts 2>/dev/null || true
    printf '%s\n%s\n' "${HOSTS_MARKER}" "${HOSTS_LINE}" | sudo tee -a /etc/hosts >/dev/null
else
    echo "Cloud topology — skipping management /etc/hosts edit. Mgmt VM resolves"
    echo "  SNI hostnames via the real public DNS that points at the LB VIP."
fi

# Generate join token
kubectl delete jointokenrequest "${CLUSTER_NAME}-token" -n "${CLUSTER_NAME}" --ignore-not-found 2>/dev/null
kubectl delete secret "${CLUSTER_NAME}-token" -n "${CLUSTER_NAME}" --ignore-not-found 2>/dev/null
sleep 2
# BOUND THE TOKEN'S LIFETIME. This is a bearer credential: whoever holds it can
# join a node to the cluster. It used to be minted with no expiry at all, which
# was survivable while it existed only for the few seconds between step 05 and
# step 06 inside one ssh session — and is not survivable now that `join: bundle`
# puts it in a file an operator carries to a hospital through email, a jump host
# or a console paste.
#
# 2h is deliberately short: the ssh path consumes it immediately, and install.sh
# re-mints on every run, so nothing normal is inconvenienced. A bundle that has
# to travel further than that should say so explicitly — set joinTokenTTL on the
# edge's entry rather than leaving a long-lived credential as the default.
JOIN_TOKEN_TTL="${JOIN_TOKEN_TTL:-2h}"
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
  expiry: ${JOIN_TOKEN_TTL}
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
# Record when it dies, next to it. The token itself is base64(gzip(kubeconfig))
# and carries no readable expiry, so `join: bundle` would otherwise have no way
# to tell an operator "this expired an hour ago" instead of letting them watch a
# join fail with a TLS error at the far end.
python3 - "$JOIN_TOKEN_TTL" "${REPO_DIR}/join-token-${CLUSTER_NAME}.expires" <<'PY'
import re, sys, time
ttl, out = sys.argv[1], sys.argv[2]
units = {"ms": 0.001, "s": 1, "m": 60, "h": 3600}
total = sum(float(v) * units[u] for v, u in re.findall(r"([0-9.]+)(ms|h|m|s)", ttl)) or 7200
open(out, "w").write("%d\n" % (time.time() + total))
PY
echo "Join token saved (valid for ${JOIN_TOKEN_TTL})"

# Note: SeaweedFS S3 identities for edge users are provisioned by charts/mgmt,
# which renders the s3.json ConfigMap from the `edges:` list in
# sites/<site>/values.yaml. No per-edge step here — every identity in that list
# is already active in SeaweedFS by the time we reach this step.

echo "=== 05: Complete for ${CLUSTER_NAME} ==="
