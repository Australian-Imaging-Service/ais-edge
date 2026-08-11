#!/usr/bin/env bash
# =============================================================================
# Step 06c: management-side work that follows a worker join
#           Usage: ./06c-post-join.sh <edge-name>
# =============================================================================
# Everything here runs on the MANAGEMENT node against the child cluster's
# kubeconfig. None of it needs to reach the edge, which is precisely why it is
# split out: it has to run identically whether the worker was joined by
# `join: ssh` (scripts/06 pushed it) or by `join: bundle` (an operator carried
# it). Leaving it inside scripts/06 would have made the bundle path skip the
# CoreDNS patch, and the symptom of that is konnectivity-agent failing to
# resolve the management hostnames — on the edge, hours later, looking like a
# site DNS fault.
#
#   1. wait for the node to register and go Ready
#   2. patch the child cluster's CoreDNS so PODS can resolve the management
#      hostnames (pods do not read the node's /etc/hosts)
#   3. bounce coredns + konnectivity-agent so the new path takes effect now
#
# WAIT_MINUTES tunes step 1. The ssh path knows the join just finished, so the
# default is short. The bundle path passes a long one, because it is waiting for
# a human to walk the bundle to a hospital.
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

[ $# -ge 1 ] || { echo "Usage: $0 <edge-name>" >&2; exit 1; }

# Configuration comes from sites/<site>/values.yaml, exported by install.sh.
# There is no second source: the `else parse_edge_entry "$1"` branch that used
# to sit here read config/edge-nodes.env, which could contradict the site file
# the charts were rendered from.
: "${CLUSTER_NAME:?install.sh must export CLUSTER_NAME}"
EDGE_KC="${REPO_DIR}/kubeconfig-${CLUSTER_NAME}"

WAIT_MINUTES="${WAIT_MINUTES:-3}"
DEADLINE=$(( $(date +%s) + WAIT_MINUTES * 60 ))

echo "Verifying node joined (up to ${WAIT_MINUTES}m)..."
JOINED=false
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    if KUBECONFIG="$EDGE_KC" kubectl get nodes --no-headers 2>/dev/null | grep -q ' Ready'; then
        JOINED=true; break
    fi
    printf '  waiting for %s to appear in its cluster... (%dm left)\n' \
        "$CLUSTER_NAME" "$(( (DEADLINE - $(date +%s)) / 60 ))"
    sleep 15
done

if [ "$JOINED" != "true" ]; then
    echo "ERROR: ${CLUSTER_NAME} has not joined." >&2
    echo "       If this site uses 'join: bundle', the bundle has not been run on the edge yet." >&2
    echo "       Re-run the installer once it has, or check:  KUBECONFIG=${EDGE_KC} kubectl get nodes" >&2
    exit 1
fi
echo "Node joined and Ready!"
KUBECONFIG="$EDGE_KC" kubectl get nodes -o wide

# PODS DO NOT READ THE NODE'S /etc/hosts. konnectivity-agent resolves through
# cluster CoreDNS, so without this it fails with
# "lookup konnectivity-<edge>.<domain> on 10.96.0.10:53: no such host".
if [ "${INSTALL_TOPOLOGY:-onprem}" = "onprem" ]; then
    for _v in MGMT_NODE_IP SEAWEEDFS_HOSTNAME K0S_API_HOSTNAME KONNECTIVITY_HOSTNAME; do
        [ -n "${!_v:-}" ] || { echo "ERROR: ${_v} is empty — refusing to patch CoreDNS"; exit 1; }
    done
    COREDNS_TMP=$(mktemp /tmp/coredns-corefile-XXXXXX)
    trap 'rm -f "$COREDNS_TMP"' EXIT
    cat > "$COREDNS_TMP" <<EOF
.:53 {
    errors
    health
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
      pods insecure
      ttl 30
      fallthrough in-addr.arpa ip6.arpa
    }
    hosts {
        ${MGMT_NODE_IP} ${SEAWEEDFS_HOSTNAME} ${K0S_API_HOSTNAME} ${KONNECTIVITY_HOSTNAME}
        fallthrough
    }
    prometheus :9153
    forward . /etc/resolv.conf
    cache 30
    loop
    reload
    loadbalance
}
EOF
    echo "Patching child cluster CoreDNS Corefile with mgmt-side hostnames..."
    KUBECONFIG="$EDGE_KC" kubectl create configmap coredns \
        --from-file=Corefile="$COREDNS_TMP" \
        --namespace kube-system \
        --dry-run=client -o yaml \
        | KUBECONFIG="$EDGE_KC" kubectl apply -f -
else
    echo "Cloud topology — leaving child cluster CoreDNS at chart defaults."
    echo "  In-pod resolution of ${SEAWEEDFS_HOSTNAME} etc. uses the standard"
    echo "  upstream chain (CoreDNS forward → kubelet's /etc/resolv.conf → public DNS)."
fi

# CoreDNS's reload plugin would pick this up, but restarting is deterministic in
# installer logs, which is what someone reads when a join looks wrong.
KUBECONFIG="$EDGE_KC" kubectl rollout restart deployment/coredns -n kube-system 2>/dev/null || true
KUBECONFIG="$EDGE_KC" kubectl rollout restart daemonset/konnectivity-agent -n kube-system 2>/dev/null || true

echo "=== 06c: Complete for ${CLUSTER_NAME} ==="
