#!/usr/bin/env bash
# =============================================================================
# Tier-1 (single-node) uninstall — removes the pipeline + observability from
# this node. Optionally resets k0s itself (fresh installs only).
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/config/management.env" 2>/dev/null || true

echo "============================================"
echo "This will remove from THIS node:"
echo "  - xnat-ingest namespace (Orthanc + sort)"
echo "  - xnat-upload namespace (upload pod)"
echo "  - observability namespace (Loki/Prometheus/Grafana/Alertmanager/Vector)"
echo "  - local staging data (/data/xnat-ingest/staging)"
echo "  - /data/facility-backup (original DICOMs) is LEFT INTACT"
echo "============================================"
if [ "${1:-}" = "-y" ] || [ "${1:-}" = "--yes" ]; then
    echo "Confirmation skipped (-y)."
else
    read -p "Are you sure? (y/N) " -r
    [[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

echo "=== Removing pipeline ==="
kubectl delete namespace xnat-ingest --ignore-not-found 2>/dev/null || true
kubectl delete namespace xnat-upload --ignore-not-found 2>/dev/null || true

echo "=== Removing observability ==="
helm uninstall vector       -n observability 2>/dev/null || true
helm uninstall loki         -n observability 2>/dev/null || true
helm uninstall kube-prometheus-stack -n observability 2>/dev/null || true
kubectl delete namespace observability --ignore-not-found 2>/dev/null || true

echo "=== Removing local staging ==="
sudo rm -rf /data/xnat-ingest/staging 2>/dev/null || true
echo "  (kept /data/facility-backup and /data/xnat-ingest/orthanc-storage)"

if [ "${INSTALL_MODE:-existing}" = "fresh" ]; then
    read -p "Also stop + reset k0s itself? (y/N) " -r
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        sudo k0s stop 2>/dev/null || true
        sudo k0s reset 2>/dev/null || true
        rm -f ~/.kube/config
        [ -d /opt/local-path-provisioner ] && sudo rm -rf /opt/local-path-provisioner/*
    fi
fi

echo "=== Uninstall complete ==="
