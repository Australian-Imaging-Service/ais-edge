#!/usr/bin/env bash
# =============================================================================
# Common functions and config loading — sourced by all other scripts
# =============================================================================

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load config
for cfg in "${REPO_DIR}/config/management.env" "${REPO_DIR}/config/edge-nodes.env"; do
    if [ ! -f "$cfg" ]; then
        echo "ERROR: $cfg not found. Copy from template:"
        echo "  cp ${cfg}.template ${cfg}"
        exit 1
    fi
    source "$cfg"
done

# Template renderer: replaces {{KEY}} with value
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

# Parse an EDGE_NODES entry into variables
parse_edge_entry() {
    local entry="$1"
    IFS='|' read -r CLUSTER_NAME NODE_IP SSH_USER SSH_KEY PROJECT_ID EDGE_ACCESS_KEY EDGE_SECRET_KEY <<< "$entry"
    EDGE_SSH="${SSH_USER}@${NODE_IP}"
    SSH_KEY_OPT=""
    [ -n "${SSH_KEY}" ] && SSH_KEY_OPT="-i ${SSH_KEY}"
    EDGE_KC="${REPO_DIR}/kubeconfig-${CLUSTER_NAME}"
}
