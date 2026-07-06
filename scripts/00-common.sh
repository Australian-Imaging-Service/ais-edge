#!/usr/bin/env bash
# =============================================================================
# Common functions and config loading — sourced by all other scripts
# =============================================================================
# TIER-1 (single node): the whole pipeline runs on ONE machine, so there is a
# single config file (config/management.env). The old per-edge list
# (edge-nodes.env) and the onprem/cloud topology renderer are gone.
# =============================================================================

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load config
cfg="${REPO_DIR}/config/management.env"
if [ ! -f "$cfg" ]; then
    echo "ERROR: $cfg not found. Copy from template:"
    echo "  cp ${cfg}.template ${cfg}"
    exit 1
fi
# shellcheck disable=SC1090
source "$cfg"

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
