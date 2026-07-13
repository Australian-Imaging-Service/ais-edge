#!/usr/bin/env bash
# =============================================================================
# Tier-1 (single-node) edge ingest — installer
# =============================================================================
# One machine runs the whole pipeline:
#   modality --C-STORE--> Orthanc (deid) --> xnat-ingest group-orthanc -->
#   xnat-ingest assign --> xnat-ingest upload --> XNAT (HTTPS). No SeaweedFS,
#   no k0smotron, no separate worker.
#   Observability (Loki/Prometheus/Grafana/Alertmanager/Vector) runs locally.
#
# Only edit config/management.env — never edit scripts.
#   cp config/management.env.template config/management.env && $EDITOR ...
#   ./install.sh        # interactive
#   ./install.sh -y     # auto-confirm (non-interactive / CI)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/00-common.sh"

INTERACTIVE=true
for arg in "$@"; do case "$arg" in -y|--yes) INTERACTIVE=false ;; esac; done
[ -t 0 ] || INTERACTIVE=false
if ! $INTERACTIVE; then export AIS_AUTO_CONFIRM="yes"; fi

confirm() {
    local prompt="$1"
    if ! $INTERACTIVE; then echo "$prompt y (auto)"; REPLY=y; return 0; fi
    REPLY=""; read -p "$prompt " -r || REPLY=y
}

# --- Validate required config ---
for var in MGMT_NODE_IP XNAT_URL XNAT_USER XNAT_PASS PROJECT_ID AIS_DEID_HMAC_SALT; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: ${var} is not set in config/management.env"
        [ "$var" = "AIS_DEID_HMAC_SALT" ] && echo "       Generate one with: openssl rand -hex 32"
        exit 1
    fi
done
for f in routing.json deidentification-profile.json; do
    if [ ! -f "${SCRIPT_DIR}/config/orthanc/${f}" ]; then
        echo "ERROR: config/orthanc/${f} not found — copy from the .template and fill it in."
        exit 1
    fi
done

# --- Show plan ---
if [ -n "${ALERT_EMAIL_TO:-}" ]; then obs="enabled -> ${ALERT_EMAIL_TO}"; else obs="disabled (ALERT_EMAIL_TO empty)"; fi
cat <<EOF

============================================
 Tier-1 (single-node) edge ingest
============================================
 Node:           ${MGMT_NODE_IP}
 Install mode:   ${INSTALL_MODE}
 XNAT target:    ${XNAT_URL}   (project: ${PROJECT_ID})
 Observability:  ${obs}

 Steps:
   01.  Install/verify single-node k0s (+ local-path storage)
   07c. Deploy Orthanc DICOM receiver + deid hook
   07.  Deploy xnat-ingest group-orthanc + assign (Orthanc REST-pull -> staging)
   04.  Deploy xnat-ingest upload (local staging -> XNAT)
   02d. Observability (skipped automatically if ALERT_EMAIL_TO is empty)
============================================
EOF
confirm "Proceed with installation? (y/N) "
[[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

run_step() {
    local label="$1" script="$2"
    echo; echo "--- ${label} ---"
    confirm "Run ${label}? (y/s to skip) "
    [[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/${script}"
}

run_step "Step 01: single-node k0s"        01-install-k0s.sh
run_step "Step 07c: Orthanc + deid hook"   07c-deploy-edge-orthanc.sh
run_step "Step 07: xnat-ingest group+assign" 07-deploy-edge-ingest.sh
run_step "Step 04: xnat-ingest upload"     04-deploy-xnat-upload.sh
run_step "Step 02d: observability"         02d-install-observability.sh

# ============================================================================
echo
cat <<EOF
============================================
 Installation complete
============================================
 All pods:       kubectl get pods -A
 DICOM endpoint: AET=AISEDGE  ${MGMT_NODE_IP}:4242   (modality C-STORE target)

 Logs:
   Orthanc:      kubectl logs -n xnat-ingest deploy/orthanc -f
   Group:        kubectl logs -n xnat-ingest -l component=group -f
   Assign:       kubectl logs -n xnat-ingest -l component=assign -f
   Upload:       kubectl logs -n xnat-upload -l component=upload -f
EOF
[ -n "${ALERT_EMAIL_TO:-}" ] && \
  echo " Grafana:        http://${MGMT_NODE_IP}:${GRAFANA_NODEPORT:-30030}  (user: ${GRAFANA_ADMIN_USER})"
echo
