#!/usr/bin/env bash
# =============================================================================
# Fetch the pinned CI tools into $CI_TOOL_DIR.
# =============================================================================
#   scripts/ci/tools.sh            helm + promtool   (everything `make ci` needs)
#   scripts/ci/tools.sh kind       additionally kind (greenfield job only)
#
# Every download is checked against a sha256 recorded in scripts/ci/lib.sh, so
# the pin is on the bytes rather than on a tag that can be moved. A mismatch is
# a hard failure — it is not retried and not warned about.
#
# Already-present binaries are reused only when their version matches the pin
# exactly.
# =============================================================================
set -euo pipefail

# shellcheck source=scripts/ci/lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

WANT_KIND=0
for arg in "$@"; do
  case "$arg" in
    kind) WANT_KIND=1 ;;
    *) echo "unknown argument: $arg (expected: kind)" >&2; exit 2 ;;
  esac
done

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) GOARCH=amd64 ;;
  aarch64|arm64) GOARCH=arm64 ;;
  *) echo "unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

# The sha256 pins in lib.sh are for linux/amd64 only. On any other platform
# the download still happens but the checksum cannot be asserted, and that is
# said out loud rather than skipped quietly.
PIN_PLATFORM="linux-amd64"
CAN_VERIFY=0
[ "$OS-$GOARCH" = "linux-amd64" ] && CAN_VERIFY=1

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

verify() { # verify <file> <sha256>
  if [ "$CAN_VERIFY" = 1 ]; then
    _ci_verify_sha256 "$1" "$2"
  else
    echo "  NOTE: sha256 not asserted — pins in lib.sh are for $PIN_PLATFORM, this host is $OS-$GOARCH" >&2
  fi
}

# -----------------------------------------------------------------------------
install_helm() {
  if ci_helm >/dev/null 2>&1; then
    echo "helm $CI_PIN_HELM_VERSION: already present at $(ci_helm)"
    return
  fi
  echo "helm $CI_PIN_HELM_VERSION: downloading"
  local tgz="$tmp/helm.tgz"
  _ci_fetch "https://get.helm.sh/helm-${CI_PIN_HELM_VERSION}-${OS}-${GOARCH}.tar.gz" "$tgz"
  verify "$tgz" "$CI_PIN_HELM_SHA256"
  tar -xzf "$tgz" -C "$tmp"
  install -m 0755 "$tmp/${OS}-${GOARCH}/helm" "$CI_TOOL_DIR/helm"
  echo "helm: $("$CI_TOOL_DIR/helm" version --short)"
}

install_promtool() {
  if ci_promtool >/dev/null 2>&1; then
    echo "promtool $CI_PIN_PROMETHEUS_VERSION: already present at $(ci_promtool)"
    return
  fi
  echo "promtool $CI_PIN_PROMETHEUS_VERSION: downloading"
  local tgz="$tmp/prom.tgz"
  local base="prometheus-${CI_PIN_PROMETHEUS_VERSION}.${OS}-${GOARCH}"
  _ci_fetch "https://github.com/prometheus/prometheus/releases/download/v${CI_PIN_PROMETHEUS_VERSION}/${base}.tar.gz" "$tgz"
  verify "$tgz" "$CI_PIN_PROMETHEUS_SHA256"
  tar -xzf "$tgz" -C "$tmp"
  install -m 0755 "$tmp/${base}/promtool" "$CI_TOOL_DIR/promtool"
  echo "promtool: $("$CI_TOOL_DIR/promtool" --version 2>&1 | head -1)"
}

install_kind() {
  if ci_kind >/dev/null 2>&1; then
    echo "kind $CI_PIN_KIND_VERSION: already present at $(ci_kind)"
    return
  fi
  echo "kind $CI_PIN_KIND_VERSION: downloading"
  local bin="$tmp/kind"
  _ci_fetch "https://github.com/kubernetes-sigs/kind/releases/download/${CI_PIN_KIND_VERSION}/kind-${OS}-${GOARCH}" "$bin"
  verify "$bin" "$CI_PIN_KIND_SHA256"
  install -m 0755 "$bin" "$CI_TOOL_DIR/kind"
  echo "kind: $("$CI_TOOL_DIR/kind" version)"
}

install_kubectl() {
  # Only the pinned build is checked for here — an already-present kubectl of
  # a different version is accepted by ci_kubectl at use time, so this only
  # avoids re-downloading the pinned one.
  if [ -x "$CI_TOOL_DIR/kubectl" ] \
     && "$CI_TOOL_DIR/kubectl" version --client 2>/dev/null | grep -q "$CI_PIN_KUBECTL_VERSION"; then
    echo "kubectl $CI_PIN_KUBECTL_VERSION: already present at $CI_TOOL_DIR/kubectl"
    return
  fi
  echo "kubectl $CI_PIN_KUBECTL_VERSION: downloading"
  local bin="$tmp/kubectl"
  _ci_fetch "https://dl.k8s.io/release/${CI_PIN_KUBECTL_VERSION}/bin/${OS}/${GOARCH}/kubectl" "$bin"
  verify "$bin" "$CI_PIN_KUBECTL_SHA256"
  install -m 0755 "$bin" "$CI_TOOL_DIR/kubectl"
  echo "kubectl: $("$CI_TOOL_DIR/kubectl" version --client 2>/dev/null | head -1)"
}

install_helm
install_promtool
# kubectl comes with kind: both, and only both, are needed by the greenfield
# job. Nothing else in the suite talks to a cluster.
if [ "$WANT_KIND" = 1 ]; then
  install_kind
  install_kubectl
fi

echo
echo "Tools in $CI_TOOL_DIR"
