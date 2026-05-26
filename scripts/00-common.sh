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

# Parse an EDGE_NODES entry into variables
parse_edge_entry() {
    local entry="$1"
    IFS='|' read -r CLUSTER_NAME NODE_IP SSH_USER SSH_KEY PROJECT_ID EDGE_ACCESS_KEY EDGE_SECRET_KEY <<< "$entry"
    EDGE_SSH="${SSH_USER}@${NODE_IP}"
    SSH_KEY_OPT=""
    [ -n "${SSH_KEY}" ] && SSH_KEY_OPT="-i ${SSH_KEY}"
    EDGE_KC="${REPO_DIR}/kubeconfig-${CLUSTER_NAME}"
}
