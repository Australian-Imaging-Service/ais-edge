#!/usr/bin/env bash
# =============================================================================
# Step 01: Install k0s management cluster (skip if INSTALL_MODE=existing)
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

if [ "${INSTALL_MODE}" = "existing" ]; then
    echo "=== 01: Using existing Kubernetes cluster ==="
    kubectl get nodes -o wide || { echo "ERROR: kubectl not configured"; exit 1; }
    if ! kubectl get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' | grep -q '.'; then
        echo "WARNING: No default StorageClass. PVCs may fail."
    fi
    exit 0
fi

echo "=== 01: Installing k0s management cluster ==="

# Install binary
#
# PINNED to the same version the charts build hosted control planes from
# (k0smotron.k0sVersion). Unpinned, two installs a fortnight apart land on
# different k0s minors while the operator is told they are identical — which is
# exactly the support problem a hospital appliance cannot afford. It is also the
# shape of the edge-worker bug: a version that came from "whatever upstream
# published today" rather than from anything this repo controls.
#
# K0S_VERSION MUST BE PASSED THROUGH sudo EXPLICITLY. get.k0s.sh honours the
# variable, but sudo runs with `Defaults env_reset`, which strips it before the
# script ever sees it. Measured:
#
#   K0S_VERSION=v1.2.3 bash -c 'export K0S_VERSION; sudo -n sh -c "echo [\$K0S_VERSION]"'
#   []
#
# So `export K0S_VERSION` in the caller pins nothing. Unset, get.k0s.sh still
# takes latest, so this stays safe for callers that do not set it.
if ! command -v k0s &>/dev/null; then
    curl -sSLf https://get.k0s.sh | sudo ${K0S_VERSION:+K0S_VERSION="$K0S_VERSION"} sh
fi
echo "k0s: $(k0s version)"

# Where k0s keeps its state: containerd's image store, etcd/kine, and kubelet's
# root-dir, which k0s places under <data-dir>/kubelet. One flag moves all three.
#
# INSTALL-TIME ONLY. `k0s install controller --help` says "DO NOT CHANGE for an
# existing setup, things will break!" — it is baked into the systemd unit, so it
# cannot retrofit a running cluster. That is why it sits inside the `k0s status`
# guard: on a node that already has k0s, this block is skipped entirely and the
# existing data-dir stays authoritative.
K0S_DATA_DIR="${DATA_ROOT:+${DATA_ROOT}/k0s}"

# Start cluster
if ! sudo k0s status &>/dev/null; then
    sudo mkdir -p /etc/k0s
    sudo cp "${REPO_DIR}/config/k0s-controller.yaml" /etc/k0s/k0s.yaml
    if [ -n "$K0S_DATA_DIR" ]; then
        echo "  k0s data-dir: ${K0S_DATA_DIR}  (root filesystem holds the OS only)"
        sudo mkdir -p "$K0S_DATA_DIR"
        sudo k0s install controller --single -c /etc/k0s/k0s.yaml --data-dir "$K0S_DATA_DIR"
    else
        sudo k0s install controller --single -c /etc/k0s/k0s.yaml
    fi
    sudo k0s start
    echo "Waiting for k0s to start..."
    sleep 15
fi

# Wait for Ready
RETRIES=30
for i in $(seq 1 $RETRIES); do
    sudo k0s kubectl get nodes 2>/dev/null | grep -q "Ready" && { echo "Node Ready!"; break; }
    [ $i -eq $RETRIES ] && { echo "ERROR: Node not Ready"; exit 1; }
    echo "  Waiting... ($i/$RETRIES)"
    sleep 10
done

# Kubeconfig
mkdir -p ~/.kube
sudo k0s kubeconfig admin > ~/.kube/config
chmod 600 ~/.kube/config

# kubectl + helm
if ! command -v kubectl &>/dev/null; then
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm -f kubectl
fi
if ! command -v helm &>/dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Local-path provisioner
#
# v0.0.36, not the v0.0.30 that was here. v0.0.30 is affected by
# CVE-2025-62878 (CVSS 9.9 — `parameters.pathPattern` on a StorageClass is
# not sanitised, so a traversal sequence provisions a PV anywhere on the host
# filesystem; pathPattern handling is present in v0.0.30, so it is genuinely
# in range) and CVE-2026-44543 (helperPod.yaml template injection). Both need
# cluster-scoped write to exploit, so this is hardening rather than an open
# door — but this provisioner backs the Prometheus, Grafana and Alertmanager
# PVCs on the internet-facing management node, and the fix is a version
# number. v0.0.36 is the lowest release fixing both; v0.0.37 is a day old.
#
# NOTE THE `if` ABOVE: this only runs when the StorageClass is absent, so it
# does NOT upgrade a cluster that already has v0.0.30 — see the manual step in
# the CVE audit. Checked before changing the version, since a live cluster's
# existing PVs depend on all of it: StorageClass name (`local-path`),
# provisioner (`rancher.io/local-path`), reclaimPolicy (Delete) and node path
# (/opt/local-path-provisioner) are byte-identical between the two manifests.
# The only other difference is upstream fully-qualifying its image names.
if ! kubectl get sc local-path &>/dev/null; then
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.36/deploy/local-path-storage.yaml
    kubectl patch storageclass local-path \
        -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

    # Every PVC on this node lands under this path — Prometheus 20Gi, Loki 10Gi,
    # Grafana, Alertmanager, each hosted control plane's etcd. The upstream
    # default is /opt/local-path-provisioner, i.e. the root disk. Point it at
    # the data volume instead when one is configured.
    #
    # This is the provisioner's own nodePathMap setting, not a mount: the PV
    # path is written into each PV object, so it must be set BEFORE the first
    # PVC binds. Changing it later strands existing volumes at the old path.
    if [ -n "${DATA_ROOT:-}" ]; then
        echo "  local-path PVC root: ${DATA_ROOT}/local-path"
        sudo mkdir -p "${DATA_ROOT}/local-path"
        kubectl -n local-path-storage patch configmap local-path-config --type merge \
            -p "$(printf '{"data":{"config.json":"{\\n  \\"nodePathMap\\":[\\n    {\\"node\\":\\"DEFAULT_PATH_FOR_NON_LISTED_NODES\\",\\"paths\\":[\\"%s/local-path\\"]}\\n  ]\\n}\\n"}}' "$DATA_ROOT")"
        # The provisioner reads config.json at startup and watches it, but a
        # restart makes the change deterministic rather than eventually-applied.
        kubectl -n local-path-storage rollout restart deploy/local-path-provisioner
        kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=120s
    fi
fi

echo "=== 01: Complete ==="
kubectl get nodes -o wide
