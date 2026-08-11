#!/usr/bin/env bash
# =============================================================================
# Common functions and config loading — sourced by all other scripts
# =============================================================================

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Config contract
#
# Configuration comes from sites/<site>/values.yaml. Nothing else. Callers say
# which of the two ways they satisfy that:
#
#   AIS_CONFIG_FROM_SITE=1   install.sh has already read the site file and
#                            exported the values. The numbered install steps
#                            (01, 05, 06, 06b, 06c) run this way.
#   AIS_NO_CONFIG=1          the caller takes a <site> argument and reads the
#                            site file itself, and wants only the helpers
#                            below. rotate-ca.sh and clear-staged-s3.sh.
#
# Neither set is an error, not a fallback — see the comment on that branch.
if [ "${AIS_NO_CONFIG:-0}" = "1" ]; then
    # The caller resolves its own configuration from sites/<site>/values.yaml
    # and wants only the helper functions below. scripts/rotate-ca.sh and
    # scripts/clear-staged-s3.sh do this: they take a <site> argument, so
    # loading anything here could only contradict what they already read.
    :
elif [ "${AIS_CONFIG_FROM_SITE:-0}" = "1" ]; then
    : "${MGMT_NODE_IP:?install.sh must export MGMT_NODE_IP when AIS_CONFIG_FROM_SITE=1}"
else
    # THERE IS ONLY ONE SOURCE OF CONFIGURATION, and it is the site file.
    #
    # This branch used to `source config/management.env` and
    # config/edge-nodes.env. That was a SECOND source of truth for the same
    # facts, and `source` assigns unconditionally — so a stale env file left
    # over from before the Helm consolidation would silently overwrite the
    # values install.sh had just exported from sites/<site>/values.yaml, and
    # every script below would act on a different node IP, hostname or edge
    # than the charts were rendered with.
    #
    # It is not enough to guard against that at each call site (05, 06, 06b and
    # 06c each had an `if AIS_CONFIG_FROM_SITE ... else parse_edge_entry` pair
    # for exactly this reason). While the files can still be loaded at all,
    # the second source exists and someone will reach it.
    echo "ERROR: no configuration. These scripts are steps of an install and" >&2
    echo "       take their configuration from a site file:" >&2
    echo >&2
    echo "         ./install.sh <site>        # reads sites/<site>/values.yaml" >&2
    echo >&2
    echo "       config/management.env and config/edge-nodes.env are gone. They" >&2
    echo "       duplicated the site file and could silently override it." >&2
    echo "       Everything they held now lives in sites/<site>/values.yaml and" >&2
    echo "       sites/<site>/secrets.enc.yaml." >&2
    exit 1
fi

# Template renderer: replaces {{KEY}} with value.
render() {
    local file="$1"; shift
    local content
    content=$(cat "$file")
    while [ $# -ge 2 ]; do
        content="${content//\{\{$1\}\}/$2}"
        shift 2
    done
    echo "$content"
}

# Topology-aware renderer: same as render() PLUS strips lines between
# {{#ONPREM_ONLY}} / {{/ONPREM_ONLY}} markers when INSTALL_TOPOLOGY=cloud.
# In onprem mode the markers themselves are removed but the content is kept.
#
# Use this for templates that have onprem-only constructs (notably the
# hostAliases blocks in edge pods, which point at MGMT_NODE_IP and have no
# meaning when edges resolve hostnames via real DNS).
#
# Symmetrical {{#CLOUD_ONLY}} / {{/CLOUD_ONLY}} blocks behave the opposite
# way for any cloud-specific resources.
render_with_topology() {
    local file="$1"; shift
    local rendered
    rendered=$(render "$file" "$@")
    # Anchored regexes — the marker MUST be the only non-whitespace content
    # on its line. This way a template doc-comment that mentions the marker
    # token (e.g. "the {{#ONPREM_ONLY}} block is stripped...") doesn't get
    # mistaken for a real marker and silently eat the following lines.
    if [ "${INSTALL_TOPOLOGY:-onprem}" = "cloud" ]; then
        # Strip onprem-only blocks; strip cloud-only markers (keep content).
        echo "$rendered" | awk '
            /^[[:space:]]*\{\{#ONPREM_ONLY\}\}[[:space:]]*$/ {skip=1; next}
            /^[[:space:]]*\{\{\/ONPREM_ONLY\}\}[[:space:]]*$/ {skip=0; next}
            skip {next}
            /^[[:space:]]*\{\{#CLOUD_ONLY\}\}[[:space:]]*$/ {next}
            /^[[:space:]]*\{\{\/CLOUD_ONLY\}\}[[:space:]]*$/ {next}
            {print}
        '
    else
        # Strip cloud-only blocks; strip onprem-only markers (keep content).
        echo "$rendered" | awk '
            /^[[:space:]]*\{\{#CLOUD_ONLY\}\}[[:space:]]*$/ {skip=1; next}
            /^[[:space:]]*\{\{\/CLOUD_ONLY\}\}[[:space:]]*$/ {skip=0; next}
            skip {next}
            /^[[:space:]]*\{\{#ONPREM_ONLY\}\}[[:space:]]*$/ {next}
            /^[[:space:]]*\{\{\/ONPREM_ONLY\}\}[[:space:]]*$/ {next}
            {print}
        '
    fi
}

# =============================================================================
# stage_edge_join_payload <outdir>
# =============================================================================
# Produce the three files an edge needs to join, into <outdir>:
#
#   k0s-ca.crt            the child cluster's internal CA certificate
#   haproxy-server.pem    a server cert+key for the k0smotron-haproxy DaemonSet,
#                         signed by that CA
#   join-token            the worker join token minted by step 05
#
# SHARED BY BOTH JOIN PATHS. scripts/06-join-edge-worker.sh scps these to the
# edge; scripts/06b-make-bootstrap.sh embeds them in a carry-over bundle. The
# cert generation lived inline in 06, so adding a second caller meant either a
# second copy or this function — and a second copy of a certificate routine is
# how you get a bundle-joined edge whose pods fail x509 verification while the
# ssh-joined ones are fine.
#
# Requires CLUSTER_NAME and NODE_IP to be set, and kubectl pointed at the
# management cluster.
stage_edge_join_payload() {
    local out="$1"
    : "${CLUSTER_NAME:?stage_edge_join_payload needs CLUSTER_NAME}"
    : "${NODE_IP:?stage_edge_join_payload needs NODE_IP}"
    mkdir -p "$out"; chmod 0700 "$out"

    local cakey csr crt key conf
    cakey="${out}/.ca.key"; key="${out}/.srv.key"; csr="${out}/.srv.csr"
    crt="${out}/.srv.crt";  conf="${out}/.srv.cnf"

    # k0smotron generates one CA per Cluster CR, as <clusterName>-ca in the
    # cluster's namespace.
    kubectl get secret -n "${CLUSTER_NAME}" "${CLUSTER_NAME}-ca" \
        -o jsonpath='{.data.tls\.crt}' | base64 -d > "${out}/k0s-ca.crt"
    kubectl get secret -n "${CLUSTER_NAME}" "${CLUSTER_NAME}-ca" \
        -o jsonpath='{.data.tls\.key}' | base64 -d > "$cakey"

    # SANs cover everything inside the child cluster that might TLS-dial the
    # worker-local haproxy on 127.0.0.1:7443.
    cat > "$conf" <<EOF
[req]
distinguished_name=req
req_extensions=v3_req
[v3_req]
subjectAltName=@alt
[alt]
DNS.1=localhost
DNS.2=kubernetes
DNS.3=kubernetes.default
DNS.4=kubernetes.default.svc
DNS.5=kubernetes.default.svc.cluster.local
IP.1=127.0.0.1
IP.2=10.96.0.1
IP.3=${NODE_IP}
EOF
    openssl genrsa -out "$key" 2048 2>/dev/null
    openssl req -new -key "$key" -subj "/CN=k0smotron-haproxy" \
        -out "$csr" -config "$conf" 2>/dev/null
    openssl x509 -req -in "$csr" -CA "${out}/k0s-ca.crt" -CAkey "$cakey" \
        -CAcreateserial -out "$crt" -days 3650 \
        -extensions v3_req -extfile "$conf" 2>/dev/null
    cat "$crt" "$key" > "${out}/haproxy-server.pem"

    [ -s "${REPO_DIR}/join-token-${CLUSTER_NAME}" ] || {
        echo "ERROR: ${REPO_DIR}/join-token-${CLUSTER_NAME} is missing — run step 05 first" >&2
        return 1
    }
    install -m 0600 "${REPO_DIR}/join-token-${CLUSTER_NAME}" "${out}/join-token"

    # The CA PRIVATE KEY must never leave this machine: it signs cluster
    # identities. Only the public cert and the server pem are for the edge.
    shred -u "$cakey" "$key" "$csr" "$crt" "$conf" 2>/dev/null || \
        rm -f "$cakey" "$key" "$csr" "$crt" "$conf"
    rm -f "${out}/.srv.srl" "${out}/k0s-ca.srl" 2>/dev/null || true
    chmod 0600 "${out}/join-token"
}
