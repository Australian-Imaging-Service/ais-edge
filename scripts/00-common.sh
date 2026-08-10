#!/usr/bin/env bash
# =============================================================================
# Common functions and config loading — sourced by all other scripts
# =============================================================================

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load config
#
# SKIPPED when install.sh has already supplied the configuration from
# sites/<site>/values.yaml, which is the normal path now. Sourcing these files
# in that case would be actively harmful, not merely redundant: `source`
# assigns unconditionally, so a stale config/management.env would OVERWRITE the
# values install.sh just exported from the site file, and the scripts below
# would quietly act on different hostnames, a different node IP or a different
# edge than the charts were rendered with. The single source of truth has to be
# single at the point of use, not just on paper.
#
# Running one of these scripts standalone still works: nothing sets
# AIS_CONFIG_FROM_SITE, so the files load exactly as before.
if [ "${AIS_CONFIG_FROM_SITE:-0}" = "1" ]; then
    : "${MGMT_NODE_IP:?install.sh must export MGMT_NODE_IP when AIS_CONFIG_FROM_SITE=1}"
else
    for cfg in "${REPO_DIR}/config/management.env" "${REPO_DIR}/config/edge-nodes.env"; do
        if [ ! -f "$cfg" ]; then
            echo "ERROR: $cfg not found. Copy from template:"
            echo "  cp ${cfg}.template ${cfg}"
            echo
            echo "Or install from a site file instead, which is the supported path:"
            echo "  ./install.sh <site>        # reads sites/<site>/values.yaml"
            exit 1
        fi
        source "$cfg"
    done
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

# Parse an EDGE_NODES entry into variables.
#
# THE canonical parser — every script must call this rather than running its
# own `IFS='|' read`. scripts/03 used to carry a second, 7-field copy of this
# line while this one read 6; against a 6-field entry that silently produced
# accessKey=<the secret> / secretKey="" in the SeaweedFS identities file, so
# the edge uploader and the S3 gateway ended up with different credentials.
# The failure was invisible until step 03 was re-run. One parser, one shape.
#
# Layout (6 fields):
#   CLUSTER_NAME|NODE_IP|SSH_USER|SSH_KEY|S3_ACCESS_KEY|S3_SECRET_KEY
#
# There is no PROJECT field. Older example lines in edge-nodes.env.template
# carried one in position 5; project/subject/session are now derived from the
# DICOM ClinicalTrial* tags, so a 7-field line is stale config and is rejected.
parse_edge_entry() {
    local entry="$1"

    # Fail loudly on the wrong shape rather than binding empty credentials.
    local _n
    _n=$(awk -F'|' '{print NF}' <<< "$entry")
    if [ "$_n" -ne 6 ]; then
        echo "ERROR: malformed EDGE_NODES entry — expected 6 pipe-separated fields, got ${_n}:" >&2
        echo "         ${entry}" >&2
        echo "       Expected: CLUSTER_NAME|NODE_IP|SSH_USER|SSH_KEY|S3_ACCESS_KEY|S3_SECRET_KEY" >&2
        [ "$_n" -eq 7 ] && echo "       (7 fields = stale PROJECT field in position 5; delete it.)" >&2
        exit 1
    fi

    IFS='|' read -r CLUSTER_NAME NODE_IP SSH_USER SSH_KEY EDGE_ACCESS_KEY EDGE_SECRET_KEY <<< "$entry"

    if [ -z "$CLUSTER_NAME" ] || [ -z "$EDGE_ACCESS_KEY" ] || [ -z "$EDGE_SECRET_KEY" ]; then
        echo "ERROR: EDGE_NODES entry has an empty CLUSTER_NAME or S3 key:" >&2
        echo "         ${entry}" >&2
        exit 1
    fi

    EDGE_SSH="${SSH_USER}@${NODE_IP}"
    SSH_KEY_OPT=""
    [ -n "${SSH_KEY}" ] && SSH_KEY_OPT="-i ${SSH_KEY}"
    EDGE_KC="${REPO_DIR}/kubeconfig-${CLUSTER_NAME}"
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
