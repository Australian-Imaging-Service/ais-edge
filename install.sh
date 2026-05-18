#!/usr/bin/env bash
# =============================================================================
# k0s + k0smotron + SeaweedFS Edge Setup — Interactive Installer
# =============================================================================
# Calls each script in order. Only edit config files — never edit scripts.
#
# Config files:
#   config/management.env   — Management node, SeaweedFS, XNAT settings
#   config/edge-nodes.env   — Edge node list (supports multiple sites)
#
# Usage:
#   cp config/management.env.template config/management.env
#   cp config/edge-nodes.env.template config/edge-nodes.env
#   vim config/management.env config/edge-nodes.env
#   ./install.sh           # interactive — prompts before each step
#   ./install.sh -y        # auto-confirm (non-interactive / CI)
#   yes y | ./install.sh   # also non-interactive (stdin not a TTY → auto-confirm)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/00-common.sh"

# Detect non-interactive mode:
#   * --yes / -y on the command line, OR
#   * stdin is not a TTY (piped, redirected, run by an automation tool).
# In non-interactive mode we run every step without asking. In interactive
# mode we prompt at every step (legacy behaviour, useful when triaging).
INTERACTIVE=true
for arg in "$@"; do
    case "$arg" in
        -y|--yes) INTERACTIVE=false ;;
    esac
done
[ -t 0 ] || INTERACTIVE=false

# Forwarded to child scripts (e.g. 07c's deid-policy review prompt). When
# install.sh is non-interactive, child scripts should auto-confirm too.
if ! $INTERACTIVE; then export AIS_AUTO_CONFIRM="yes"; fi

confirm() {
    local prompt="$1"
    if ! $INTERACTIVE; then
        echo "$prompt y (auto)"
        REPLY=y
        return 0
    fi
    REPLY=""
    read -p "$prompt " -r || REPLY=y
}

# --- Validate required config ---
for var in MGMT_NODE_IP XNAT_URL XNAT_USER XNAT_PASS \
           S3_ADMIN_ACCESS_KEY S3_ADMIN_SECRET_KEY S3_BUCKET \
           INTERNAL_DOMAIN SEAWEEDFS_HOSTNAME K0S_API_HOSTNAME \
           KONNECTIVITY_HOSTNAME INGRESS_PORT AIS_DEID_HMAC_SALT; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: ${var} is not set in config/management.env"
        [ "$var" = "AIS_DEID_HMAC_SALT" ] && echo "       Generate one with: openssl rand -hex 32"
        exit 1
    fi
done

# Orthanc per-site config is edited by hand. Fail fast here rather than
# 10 minutes into mgmt setup at step 07c.
if [ ! -f "${SCRIPT_DIR}/config/orthanc/routing.json" ]; then
    echo "ERROR: config/orthanc/routing.json not found"
    echo "       Copy from the template and fill in AETMap:"
    echo "         cp config/orthanc/routing.json.template config/orthanc/routing.json"
    echo "         vim config/orthanc/routing.json"
    exit 1
fi
# Deidentification profile must be filled in. Ships as a .template; the
# Site admin copies it from the template and customises to the site's deid policy.
if [ ! -f "${SCRIPT_DIR}/config/orthanc/deidentification-profile.json" ]; then
    echo "ERROR: config/orthanc/deidentification-profile.json not found"
    echo "       Copy the template and customise to your site's deid policy:"
    echo "         cp config/orthanc/deidentification-profile.json.template \\"
    echo "            config/orthanc/deidentification-profile.json"
    echo "         vim config/orthanc/deidentification-profile.json"
    exit 1
fi
if [ ${#EDGE_NODES[@]} -eq 0 ]; then
    echo "ERROR: No edge nodes defined in config/edge-nodes.env"
    exit 1
fi

# --- Show plan ---
echo ""
echo "============================================"
echo " k0s + k0smotron + SeaweedFS Edge Setup"
echo "============================================"
echo ""
echo " Management node:    ${MGMT_NODE_IP}"
echo " Install mode:       ${INSTALL_MODE}"
echo " Internal domain:    ${INTERNAL_DOMAIN}"
echo " Edge ingress port:  ${INGRESS_PORT} (TLS, single outbound)"
echo " SeaweedFS host:     ${SEAWEEDFS_HOSTNAME}"
echo " k0s API host:       ${K0S_API_HOSTNAME}"
echo " konnectivity host:  ${KONNECTIVITY_HOSTNAME}"
echo " XNAT target:        ${XNAT_URL}"
echo ""
echo " Edge nodes (${#EDGE_NODES[@]}):"
for entry in "${EDGE_NODES[@]}"; do
    IFS='|' read -r name ip _ _ project _ _ <<< "$entry"
    echo "   - ${name} → ${ip} (project: ${project})"
done
echo ""
echo " Steps:"
echo "   01.  Install k0s management cluster (or use existing)"
echo "   02.  Install cert-manager + k0smotron operator"
echo "   02b. Bootstrap self-signed CA (Phase 2 TLS)"
echo "   02c. Install nginx-ingress on host :443 (Phase 2 single port)"
echo "   03.  Deploy SeaweedFS (ClusterIP + TLS Ingress)"
echo "   04.  Deploy XNAT upload pod (in-cluster: SeaweedFS → XNAT)"
echo "   For each edge node:"
echo "     05. Create hosted k0s control plane (with built-in Ingress)"
echo "     06. Install k0s worker (sets /etc/hosts + patches CoreDNS)"
echo "     07. Deploy xnat-ingest (sort in REST-pull mode + s3-uploader)"
echo "     07b. Deploy Vector log shipper (skipped if observability disabled)"
echo "     07c. Deploy Orthanc DICOM receiver + deid hook"
echo ""
echo "============================================"
confirm "Proceed with installation? (y/N) "
[[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ============================================================================
echo ""
echo "========================================"
echo " Phase 1: Management Cluster"
echo "========================================"

echo ""
echo "--- Step 01: k0s management cluster ---"
confirm "Run step 01? (y/s to skip) "
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/01-install-k0s.sh"

echo ""
echo "--- Step 02: cert-manager + k0smotron ---"
confirm "Run step 02? (y/s to skip) "
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/02-install-k0smotron.sh"

echo ""
echo "--- Step 02b: Bootstrap self-signed CA ---"
confirm "Run step 02b? (y/s to skip) "
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/02b-bootstrap-ca.sh"

echo ""
echo "--- Step 02c: Install nginx-ingress (hostNetwork :443) ---"
confirm "Run step 02c? (y/s to skip) "
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/02c-install-nginx-ingress.sh"

echo ""
echo "--- Step 03: SeaweedFS ---"
confirm "Run step 03? (y/s to skip) "
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/03-deploy-seaweedfs.sh"

echo ""
echo "--- Step 04: XNAT upload pod ---"
confirm "Run step 04? (y/s to skip) "
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/04-deploy-xnat-upload.sh"

echo ""
echo "--- Step 02d: Observability (Loki + Prom + Grafana + Vector) ---"
echo "  (skipped automatically if ALERT_EMAIL_TO is empty)"
confirm "Run step 02d? (y/s to skip) "
[[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/02d-install-observability.sh"

# ============================================================================
echo ""
echo "========================================"
echo " Phase 2 & 3: Edge Nodes"
echo "========================================"

for entry in "${EDGE_NODES[@]}"; do
    IFS='|' read -r name ip _ _ project _ _ <<< "$entry"
    echo ""
    echo "========================================"
    echo " Edge: ${name} (${ip}) → project: ${project}"
    echo "========================================"

    echo ""
    echo "--- Step 05: Create hosted cluster '${name}' ---"
    confirm "Run step 05 for ${name}? (y/s to skip) "
    [[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/05-setup-edge-cluster.sh" "$entry"

    echo ""
    echo "--- Step 06: Install k0s worker on ${ip} ---"
    confirm "Run step 06 for ${name}? (y/s to skip) "
    [[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/06-join-edge-worker.sh" "$entry"

    echo ""
    echo "--- Step 07: Deploy xnat-ingest on ${name} ---"
    confirm "Run step 07 for ${name}? (y/s to skip) "
    [[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/07-deploy-edge-ingest.sh" "$entry"

    echo ""
    echo "--- Step 07b: Deploy Vector log shipper on ${name} (observability) ---"
    echo "    (skipped automatically if observability stack not installed)"
    confirm "Run step 07b for ${name}? (y/s to skip) "
    [[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/07b-deploy-edge-observability.sh" "$entry"

    echo ""
    echo "--- Step 07c: Deploy Orthanc DICOM receiver + deid hook on ${name} ---"
    confirm "Run step 07c for ${name}? (y/s to skip) "
    [[ $REPLY =~ ^[Ss]$ ]] || bash "${SCRIPT_DIR}/scripts/07c-deploy-edge-orthanc.sh" "$entry"
done

# ============================================================================
echo ""
echo "============================================"
echo " Installation Complete!"
echo "============================================"
echo ""
echo " Management cluster:    kubectl get pods -A"
echo ""
echo " ---- Edge-facing endpoints (single TLS port :${INGRESS_PORT}) ----"
echo " SeaweedFS S3:          https://${SEAWEEDFS_HOSTNAME}     (CA: ais-edge-ca.crt)"
echo " k0s API (per cluster): https://${K0S_API_HOSTNAME}       (kubeconfig server URL)"
echo " konnectivity:          https://${KONNECTIVITY_HOSTNAME}   (worker tunnel back)"
echo ""
echo " ---- Admin endpoints (kubectl port-forward) ----"
echo " SeaweedFS S3 admin:    kubectl port-forward -n seaweedfs svc/seaweedfs 8333:8333"
echo " SeaweedFS master UI:   kubectl port-forward -n seaweedfs svc/seaweedfs 9333:9333"
echo " SeaweedFS filer UI:    kubectl port-forward -n seaweedfs svc/seaweedfs 8888:8888"
echo "                        (admin key: ${S3_ADMIN_ACCESS_KEY})"
echo ""
echo " ---- Distribute to edge VMs ----"
echo " ais-edge-ca.crt is at: ${SCRIPT_DIR}/ais-edge-ca.crt"
echo " Copy it to each edge for verifying server certs."
echo ""
for entry in "${EDGE_NODES[@]}"; do
    IFS='|' read -r name ip _ _ _ _ _ <<< "$entry"
    echo " Edge '${name}' (${ip}):"
    echo "   Nodes:   kubectl --kubeconfig kubeconfig-${name} get nodes"
    echo "   Pods:    kubectl --kubeconfig kubeconfig-${name} get pods -n xnat-ingest"
    echo "   Sort:    kubectl --kubeconfig kubeconfig-${name} logs -n xnat-ingest -l component=sort -f"
    echo "   Upload:  kubectl --kubeconfig kubeconfig-${name} logs -n xnat-ingest -l component=s3-uploader -f"
    echo "   Test:    scp file.dcm ${ip}:/data/xnat-ingest/incoming/"
    echo ""
done
echo " XNAT upload (mgmt): kubectl logs -n xnat-upload -l component=upload -f"
echo ""
