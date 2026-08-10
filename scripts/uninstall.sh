#!/usr/bin/env bash
# =============================================================================
# Uninstall — return this node to a clean slate
# =============================================================================
#   scripts/uninstall.sh <site>                  full reset
#   scripts/uninstall.sh -y <site>               no prompt
#   scripts/uninstall.sh --keep-cluster <site>   remove workloads, keep k0s
#
# Reads sites/<site>/values.yaml — the same single source of truth install.sh
# uses — so it removes what THIS site actually installed rather than a hardcoded
# list that drifts. The previous version hardcoded three namespaces
# (xnat-ingest, xnat-upload, observability) and three Helm releases; the
# consolidated chart is ONE release in ONE namespace, so all of that addressed
# things that no longer exist, silently.
#
# TIER-1 IS ONE MACHINE. No edge to reach over SSH, no child cluster, no
# management plane — so this is simpler than tier-2's by design.
#
# A PARTIAL TEARDOWN IS WORSE THAN NONE. The failure modes this repo keeps
# producing are leftovers: a namespace Helm cannot adopt because it lacks
# ownership metadata, CRDs without their operator, PVs that still bind. Each
# makes the NEXT install fail in a way that looks like a chart bug.
#
# WHAT IS DELIBERATELY NOT REMOVED
#   * ~/.config/sops/age/keys.txt — the ONLY key that can decrypt every
#     sites/*/secrets.enc.yaml. Deleting it makes those files permanently
#     unreadable, and no reinstall can regenerate it.
#   * sites/<site>/ — your configuration.
#   * The k0s BINARY. install.sh reuses it; removing it only forces a download.
#
# THIS DELETES PATIENT DATA. The facility backup is the archive of record, the
# only identifiable copy, and on tier-1 the only copy ANYWHERE — there is no
# management side holding staged sessions. On anything that is not a scratch
# machine, copy it somewhere else first.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ASSUME_YES=false
KEEP_CLUSTER=false
SITE=""
for arg in "$@"; do
    case "$arg" in
        -y|--yes)       ASSUME_YES=true ;;
        --keep-cluster) KEEP_CLUSTER=true ;;
        -*)             echo "unknown flag: $arg" >&2; exit 1 ;;
        *)              SITE="$arg" ;;
    esac
done

info() { echo "[uninstall] $*"; }
warn() { echo "[uninstall] WARNING: $*" >&2; }

[ -n "$SITE" ] || { echo "usage: $0 [-y] [--keep-cluster] <site>" >&2; exit 1; }
VALUES="${SCRIPT_DIR}/sites/${SITE}/values.yaml"
[ -f "$VALUES" ] || { echo "no such site: sites/${SITE}" >&2; exit 1; }

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

NS="$(cfg namespace xnat-ingest)"
RELEASE="${AIS_RELEASE:-$SITE}"
PIPE_PATH="$(cfg storage.pipeline.hostPath /data/xnat-ingest)"
FB_PATH="$(cfg storage.facilityBackup.hostPath /data/facility-backup)"

if command -v kubectl >/dev/null 2>&1; then K="kubectl"
elif command -v k0s >/dev/null 2>&1; then K="k0s kubectl"
else K="kubectl"; fi

echo "============================================"
echo " UNINSTALL — $([ "$KEEP_CLUSTER" = true ] && echo 'workloads only' || echo 'FULL RESET')"
echo "============================================"
echo "  site      : ${SITE}"
echo "  release   : ${RELEASE}  (namespace ${NS})"
echo
echo "  This removes:"
echo "    - the ${RELEASE} Helm release and the ${NS} namespace"
echo "    - every PersistentVolume and PVC this site created"
echo "    - ${PIPE_PATH}"
echo "    - ${FB_PATH}"
echo "      THE FACILITY BACKUP: identifiable originals, and the only copy that"
echo "      exists on this tier. Copy it elsewhere first if this is not scratch."
[ "$KEEP_CLUSTER" = false ] && \
echo "    - k0s itself (k0s reset)"
echo
echo "  It KEEPS: your age key, sites/${SITE}/, the k0s binary."
echo "============================================"

if [ "$ASSUME_YES" != true ]; then
    read -rp "  Type the site name to confirm: " r
    [ "$r" = "$SITE" ] || { echo "aborted"; exit 1; }
fi

# --- 1. workloads -------------------------------------------------------------
echo
echo "--- workloads ---"
if $K version >/dev/null 2>&1; then
    helm uninstall "$RELEASE" -n "$NS" --wait --timeout 5m >/dev/null 2>&1 \
        && info "release ${RELEASE} removed" \
        || warn "release ${RELEASE} not removed (already gone?)"

    # The chart marks the pipeline PV/PVC pairs with resource-policy: keep and
    # Retain, so that an UPGRADE can never delete patient data. That is exactly
    # right for an upgrade and exactly wrong here, so they go explicitly.
    $K delete pvc --all -n "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    $K delete pv -l "app.kubernetes.io/instance=${RELEASE}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    $K delete ns "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    info "namespace, PVCs and PVs removed"

    # kube-prometheus-stack's CRDs outlive `helm uninstall` by design. Left
    # behind with no operator, the next install's Prometheus and Alertmanager
    # objects apply successfully and then do nothing at all.
    if [ "$KEEP_CLUSTER" = false ]; then
        for crd in $($K get crd -o name 2>/dev/null | grep -E 'monitoring\.coreos\.com'); do
            $K delete "$crd" --ignore-not-found --wait=false >/dev/null 2>&1 || true
        done
        info "prometheus-operator CRDs removed"
    fi
else
    warn "no reachable cluster — skipping workload removal"
fi

# --- 2. host data -------------------------------------------------------------
echo
echo "--- host data ---"
for p in "$PIPE_PATH" "$FB_PATH"; do
    [ -n "$p" ] || continue
    if sudo test -e "$p"; then sudo rm -rf "$p" && info "removed $p"; fi
done
sudo rm -rf /var/lib/vector 2>/dev/null || true

# --- 3. k0s -------------------------------------------------------------------
if [ "$KEEP_CLUSTER" = false ]; then
    echo
    echo "--- k0s ---"
    sudo k0s stop 2>/dev/null || true
    sudo k0s reset 2>/dev/null || true
    sudo rm -rf /var/lib/k0s /etc/k0s 2>/dev/null || true
    rm -f "$HOME/.kube/config" 2>/dev/null || true
    info "k0s reset"
fi

# --- summary ------------------------------------------------------------------
echo
echo "============================================"
echo " Remaining state"
echo "============================================"
for p in /var/lib/k0s /etc/k0s "$PIPE_PATH" "$FB_PATH"; do
    printf '  %-34s %s\n' "$p" "$(sudo test -e "$p" && echo 'STILL PRESENT' || echo gone)"
done
# `wc -l` always prints a number; `grep -c` would print 0 AND exit 1, so a
# `|| echo 0` fallback would fire on top of it and emit two zeros.
ns_left=$($K get ns "$NS" --no-headers 2>/dev/null | wc -l)
printf '  %-34s %s\n' "namespace ${NS}" "$([ "${ns_left:-0}" -gt 0 ] && echo 'STILL PRESENT' || echo gone)"
echo
echo "  KEPT (deliberately):"
printf '    %-30s %s\n' "age key" "$([ -f "$HOME/.config/sops/age/keys.txt" ] && echo present || echo 'MISSING — encrypted secrets are unreadable')"
printf '    %-30s %s\n' "sites/${SITE}/" "$(ls "${SCRIPT_DIR}/sites/${SITE}" 2>/dev/null | tr '\n' ' ')"
echo
if [ "$KEEP_CLUSTER" = false ]; then
    echo "  A reboot is recommended: k0s reset does not remove CNI interfaces or"
    echo "  iptables rules already in the kernel."
fi
echo "  Reinstall with:  ./install.sh ${SITE}"
