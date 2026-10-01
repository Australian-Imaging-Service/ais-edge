#!/usr/bin/env bash
# =============================================================================
# AIS Edge — TIER-1 installer (single node)
# =============================================================================
#   ./install.sh <site>          interactive, step by step
#   ./install.sh -y <site>       non-interactive
#
#   e.g.  ./install.sh my-hospital
#
# ONE SOURCE OF TRUTH: sites/<site>/values.yaml
#
# That file is read by this script AND passed to the Helm release, so a fact is
# stated once. It replaces config/management.env plus the three JSON config
# files, which were a second, parallel configuration the chart could not see.
#
# THREE STEPS, NOT SEVEN. Tier-2 needs seven because it builds a management
# plane, a hosted control plane per edge, an object store, a CA, and then joins
# a worker over the network. Tier-1 is one machine:
#
#   1  k0s (single-node), kubectl, helm, and local-path if observability is on
#   2  site Secrets, SOPS -> cluster, plaintext never on disk
#   3  the edge chart, with upload.mode=direct
#
# There is no join step, no cert-sync, no S3 identity to distribute and no
# second machine to reach — which is also why there is no `join: bundle`
# equivalent here. Everything happens on the box you are typing on.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# PIN EVERYTHING FETCHED FROM THE INTERNET. Tier-1 is an appliance handed to a
# hospital: two installs a fortnight apart landing on different k0s minors is a
# support problem nobody can reproduce. get.k0s.sh honours K0S_VERSION.
K0S_VERSION="${K0S_VERSION:-v1.35.2+k0s.0}"
export K0S_VERSION

ASSUME_YES=false
SITE=""
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=true ;;
        -*)       echo "unknown flag: $arg" >&2; exit 1 ;;
        *)        SITE="$arg" ;;
    esac
done
[ -t 0 ] || ASSUME_YES=true

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[install] $*"; }

[ -n "$SITE" ] || die "usage: $0 [-y] <site>    (a directory under sites/)

  Create one first:   scripts/site-secrets.sh new <name> single"

SITE_DIR="${SCRIPT_DIR}/sites/${SITE}"
VALUES="${SITE_DIR}/values.yaml"
SECRETS="${SITE_DIR}/secrets.enc.yaml"
[ -d "$SITE_DIR" ] || die "no such site: sites/${SITE}"
[ -f "$VALUES" ]   || die "missing ${VALUES}"

step() {
    echo
    echo "--- $1 ---"
    $ASSUME_YES && { echo "Run this step? (y/s to skip) y (auto)"; return 0; }
    read -rp "Run this step? (y/s to skip) " r
    [[ "$r" =~ ^[Ss]$ ]] && return 1
    return 0
}

# --- read the site file -------------------------------------------------------
cfg() {
    python3 - "$VALUES" "$1" "${2:-}" <<'PY'
import sys, yaml
try: cur = yaml.safe_load(open(sys.argv[1])) or {}
except Exception: print(sys.argv[3] if len(sys.argv) > 3 else ""); raise SystemExit
for p in sys.argv[2].split('.'):
    cur = cur.get(p) if isinstance(cur, dict) else None
    if cur is None: break
print(cur if cur not in (None, '') else (sys.argv[3] if len(sys.argv) > 3 else ''))
PY
}

CLUSTER_LABEL="$(cfg clusterLabel "$SITE")"
NAMESPACE="$(cfg namespace xnat-ingest)"
NODE_IP="$(cfg nodeIP)"
INSTALL_MODE="$(cfg installMode fresh)"
UPLOAD_MODE="$(cfg upload.mode direct)"
OBS_STACK="$(cfg observability.stack.enabled false)"
GRAFANA_PORT="$(cfg observability.stack.grafana.nodePort 30030)"
RELEASE="${AIS_RELEASE:-$SITE}"

# TIER-1 IS upload.mode=direct BY DEFINITION. s3 needs a SeaweedFS and a
# management-side reclaimer that do not exist here, and the failure is silent:
# the uploader would retry an endpoint that never answers while the pipeline
# quietly filled the disk.
# The old installer checked every required value up front and named the missing
# one. Without this, an empty nodeIP surfaces much later inside a sourced library
# as "MGMT_NODE_IP: install.sh must export MGMT_NODE_IP" — a message that blames
# the installer rather than the site file.
[ -n "$NODE_IP" ] || die "nodeIP is not set in sites/${SITE}/values.yaml.
       It is this machine's address: modalities C-STORE to it, and it is what
       the installer prints as the DICOM endpoint."

[ "$UPLOAD_MODE" = "direct" ] || die "upload.mode is '${UPLOAD_MODE}' — tier-1 requires 'direct'.
       upload.mode: s3 needs the tier-2 management plane (SeaweedFS, staging
       bucket, management-side reclaimer). None of that exists on a single node."

for t in kubectl helm python3; do
    command -v "$t" >/dev/null 2>&1 || MISSING="${MISSING:-} $t"
done

echo "============================================"
echo " AIS Edge — tier-1 install (single node)"
echo "============================================"
echo "  site          : ${SITE}"
echo "  values        : sites/${SITE}/values.yaml"
echo "  release/ns    : ${RELEASE} / ${NAMESPACE}"
echo "  node          : ${NODE_IP:-<not set>}"
echo "  install mode  : ${INSTALL_MODE}"
echo "  upload        : direct to XNAT (no S3 hop)"
echo "  observability : $([ "$OBS_STACK" = "True" ] || [ "$OBS_STACK" = "true" ] && echo "local stack, Grafana on :${GRAFANA_PORT}" || echo "off")"
echo "  k0s           : ${K0S_VERSION}   (pinned)"
echo "============================================"

# Secrets must be encrypted, and must not still hold the shipped placeholders.
# The file is ENCRYPTED by the check above, so its values are ciphertext and a
# plain `grep REPLACE_` over it can only ever match the template's own COMMENTS —
# which every correct site still carries. Decrypt to a pipe and check the VALUES.
if [ -f "$SECRETS" ]; then
    grep -q '^sops:' "$SECRETS" || die "sites/${SITE}/secrets.enc.yaml is NOT encrypted. Run: scripts/site-secrets.sh encrypt ${SITE}"
    # NOT `if command -v sops` — that made the placeholder check silently
    # conditional on a tool being present, so on a box without sops an unfilled
    # REPLACE_XNAT_PASSWORD sailed through and step 2 failed only AFTER k0s had
    # been installed. sops is required to apply the secrets at all.
    command -v sops >/dev/null 2>&1 || die "sops is required — the site secrets are SOPS-encrypted.
       https://github.com/getsops/sops/releases"
    if true; then
        UNFILLED="$(sops --config "${SCRIPT_DIR}/.sops.yaml" -d "$SECRETS" 2>/dev/null \
                    | grep -nE '^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*REPLACE_' || true)"
        [ -n "$UNFILLED" ] && die "sites/${SITE}/secrets.enc.yaml still has unfilled placeholder VALUES:
${UNFILLED}
       Fix with: scripts/site-secrets.sh edit ${SITE}"
    fi
else
    die "no sites/${SITE}/secrets.enc.yaml.
       The chart references xnat-credentials and orthanc-deid-salt BY NAME and
       creates neither, so every pipeline pod would sit in
       CreateContainerConfigError while helm --wait blocked for ten minutes.
       The old installer refused up front for exactly this reason.
         scripts/site-secrets.sh new ${SITE} single
         scripts/site-secrets.sh encrypt ${SITE}"
fi

[ -n "${MISSING:-}" ] && [ "$INSTALL_MODE" != "fresh" ] && die "missing required tools:${MISSING}"

$ASSUME_YES || { read -rp "Proceed? (y/N) " r; [[ "$r" =~ ^[Yy]$ ]] || exit 0; }

# =============================================================================
# 1 — k0s
# =============================================================================
if step "1/3  single-node k0s (k0s, kubectl, helm, local-path)"; then
    # The same script tier-2 uses for its management node: that is also a
    # `k0s install controller --single`, so this is reuse rather than a variant.
    #
    # It installs local-path unconditionally. Strictly, tier-1's PIPELINE does
    # not need it — charts/edge creates its own hostPath PVs on
    # `hostpath-pipeline` with provisioner kubernetes.io/no-provisioner — and
    # only the optional observability PVCs bind against it. Left unconditional
    # anyway: it is idempotent, costs one small Deployment, and gating it would
    # mean turning observability on later silently produces Pending PVCs.
    # AIS_CONFIG_FROM_SITE=1 IS LOAD-BEARING, NOT DECORATION.
    #
    # 01-install-k0s.sh sources scripts/00-common.sh, and that file's default
    # branch loads config/management.env AND config/edge-nodes.env, exiting 1 if
    # either is missing. Those are the tier-2-era env files this site model
    # replaces. Without this flag the step works only while a stale
    # config/management.env happens to still be on disk, and dies on any fresh
    # clone — after the k0s binary has been fetched but before anything is
    # installed, which reads as a broken installer rather than a missing file.
    #
    # The flag is 00-common.sh's own documented escape hatch; it then requires
    # MGMT_NODE_IP, which on tier-1 is the site's nodeIP.
    # INSTALL_MODE IS NOT OPTIONAL HERE. 01-install-k0s.sh runs under
    # `set -euo pipefail` and branches on "${INSTALL_MODE}" with no default, so
    # an unset variable aborts the whole install on its line 8 with
    # `INSTALL_MODE: unbound variable` — before k0s, kubectl, helm or local-path
    # are touched. The old installer never hit this because 00-common.sh sourced
    # config/management.env, whose template exports it; the AIS_CONFIG_FROM_SITE
    # branch deliberately does not source that file.
    #
    # Passing it also makes `installMode: existing` mean something again: it
    # selects 01's verify-instead-of-build branch, so a site file can say "there
    # is already a cluster here" without an operator having to remember to
    # answer `s` at the prompt — and without `-y` running
    # `k0s install controller --single` on a host that already runs Kubernetes.
    AIS_CONFIG_FROM_SITE=1 \
    MGMT_NODE_IP="$NODE_IP" \
    INSTALL_MODE="$INSTALL_MODE" \
    INSTALL_TOPOLOGY=onprem \
        bash "${SCRIPT_DIR}/scripts/01-install-k0s.sh"
fi

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# =============================================================================
# 2 — Secrets, before the workloads
# =============================================================================
# A pod that starts without its Secret sits in CreateContainerConfigError, so
# the chart deliberately does NOT create the namespace holding operator-supplied
# credentials — site-secrets.sh does, which is what makes secrets-before-
# workloads possible on a bare cluster.
if [ -f "$SECRETS" ] && step "2/3  site Secrets (SOPS -> cluster, plaintext never on disk)"; then
    SITE_SECRETS_ASSUME_YES=1 bash "${SCRIPT_DIR}/scripts/site-secrets.sh" apply "$SITE"
fi

# =============================================================================
# 3 — the chart
# =============================================================================
if step "3/3  helm: the pipeline (Orthanc, de-id, group, assign, direct upload)"; then
    helm upgrade --install "$RELEASE" "${SCRIPT_DIR}/charts/edge" \
        --namespace "$NAMESPACE" --create-namespace \
        -f "$VALUES" \
        --wait --timeout 10m
fi

echo
echo "============================================"
echo " Installed"
echo "============================================"
echo "  kubectl get pods -n ${NAMESPACE}"
echo
echo "  DICOM endpoint : AET=$(cfg orthanc.aet AISEDGE)  ${NODE_IP}:4242   (C-STORE target)"
if [ "$OBS_STACK" = "True" ] || [ "$OBS_STACK" = "true" ]; then
echo "  Grafana        : http://${NODE_IP}:${GRAFANA_PORT}"
fi
echo
echo "  Prove it works : scripts/verify-live.sh ${SITE}"
echo
echo "  Data retention is OFF on a fresh install (dataPolicy.enabled: false,"
echo "  dryRun: true). Nothing is expired or reclaimed until you turn it on."
echo "  This node holds the ONLY copy of the facility backup — read the dryRun"
echo "  decisions for a week before enabling anything."
