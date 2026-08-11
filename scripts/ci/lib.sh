#!/usr/bin/env bash
# =============================================================================
# Shared plumbing for the scripts/ci/*.sh checks.
# =============================================================================
# Sourced, never executed. Provides:
#   * paths      REPO_ROOT, CI_WORK_DIR, CI_TOOL_DIR
#   * reporting  ci_pass / ci_fail / ci_skip / ci_summary, with an exit code
#                derived from the failure count
#   * tools      ci_need_tool, which resolves a PINNED binary or explains
#                exactly how to get it
#
# Every check script sources this, so a failure counted anywhere shows up in
# one place at the end. The scripts deliberately do NOT `exit 1` at the first
# problem: a run that stops at the first failure hides the other five.
# =============================================================================

# shellcheck disable=SC2034  # several of these are consumed by the callers.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Work directory is deliberately OUTSIDE the repository. Build artefacts inside
# the tree are one `git add -A` away from being committed, and .gitignore is
# not maintained by these scripts.
#
# IT IS ALSO KEYED TO THIS CHECKOUT, and that is not cosmetic. The path used to
# be a single fixed directory, so two copies of the repo running CI at the same
# time silently destroyed each other's work: the second run's render.sh
# cleared and rewrote the render directory the first run was still reading.
#
# The symptom is baffling rather than obvious. `render` reports 40 passed, and
# then `pvc-retention` fails on the very charts that just rendered while
# `runtime-templates` reports the render directory empty — so it reads as a
# broken chart, not as two processes colliding. It was found while five agents
# built in parallel.
#
# Hashing the checkout path gives every working copy its own directory, which is
# exactly the case that occurs in practice (parallel agents, git worktrees, a
# second clone). Two concurrent runs in the SAME checkout still share one
# directory and still conflict; fixing that needs a per-invocation id threaded
# from the Makefile through every stage, and has not been worth the plumbing.
# Set CI_WORK_DIR explicitly if you need it.
_ci_checkout_key="$(printf '%s' "$REPO_ROOT" | cksum | cut -d' ' -f1)"
CI_WORK_DIR="${CI_WORK_DIR:-${TMPDIR:-/tmp}/ais-edge-ci-${_ci_checkout_key}}"
CI_VALUES_DIR="$CI_WORK_DIR/values"
CI_RENDER_DIR="$CI_WORK_DIR/render"
CI_TOOL_DIR="${CI_TOOL_DIR:-$HOME/.cache/ais-edge-ci/bin}"

mkdir -p "$CI_WORK_DIR" "$CI_TOOL_DIR"

# -----------------------------------------------------------------------------
# Pinned tool versions.
# -----------------------------------------------------------------------------
# Pinned, not floating, for the same reason Chart.yaml pins its dependencies:
# a check whose tool changed under it is a check whose result changed for a
# reason nobody can see in the diff. The sha256 is checked on download, so the
# pin is on the BYTES, not on a tag someone can move.
#
# HELM        matches the helm that these charts were developed and verified
#             against. Helm 4 is out; nothing here has been run on it.
# PROMETHEUS  supplies promtool. kube-prometheus-stack 87.19.2 ships Prometheus
#             3.x, so the rule/test syntax accepted here is the syntax the
#             cluster will evaluate.
# KIND        greenfield install target.
CI_PIN_HELM_VERSION="v3.20.1"
CI_PIN_HELM_SHA256="0165ee4a2db012cc657381001e593e981f42aa5707acdd50658326790c9d0dc3"

CI_PIN_PROMETHEUS_VERSION="3.13.2"
CI_PIN_PROMETHEUS_SHA256="0e8c4d46101bd025ea8265e377d2caabc57f488fc1be1c367f37db69ea41be6f"

CI_PIN_KIND_VERSION="v0.32.0"
CI_PIN_KIND_SHA256="50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54"

# kubectl, used only by the greenfield job. Pinned rather than taken from the
# runner image or the developer's box for the same reason as everything else
# here: a client version that drifts from the kind node image changes what the
# job proves without changing anything in the diff. Matched to
# CI_PIN_KIND_NODE_IMAGE below, not to k0smotron.k0sVersion — this client talks
# to the kind cluster, not to a child cluster.
CI_PIN_KUBECTL_VERSION="v1.35.5"
CI_PIN_KUBECTL_SHA256="90f75ea6ecc9ea5633262e1c0b83a40560003b30fc94a04cb099404fcef0c224"

# Digest-pinned so the node image cannot be re-tagged under us. v1.35.5 is the
# closest kind node image to k0smotron.k0sVersion (v1.35.2+k0s.0) in
# charts/mgmt/values.yaml.
CI_PIN_KIND_NODE_IMAGE="kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95"

# Cluster-scoped prerequisites for a greenfield mgmt install. Both are things
# the chart REFERENCES but does not install by default:
#   cert-manager   certManager.enabled defaults to false (it is already present
#                  on every cluster we have), so its CRDs must exist first.
#   k0smotron      the operator is installed out of band by scripts/02.
# Version-pinned here because scripts/02 fetches them from /latest/ and
# /stable/ URLs, which is the reproducibility problem this chart exists to fix;
# CI must not inherit it.
CI_PIN_CERT_MANAGER_VERSION="v1.20.3"
CI_PIN_K0SMOTRON_VERSION="v2.0.3"

# -----------------------------------------------------------------------------
# Reporting
# -----------------------------------------------------------------------------
CI_PASS_COUNT=0
CI_FAIL_COUNT=0
CI_SKIP_COUNT=0
CI_FAILURES=()
CI_SKIPS=()

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  _C_RED=$'\033[31m'; _C_GRN=$'\033[32m'; _C_YEL=$'\033[33m'
  _C_BLD=$'\033[1m';  _C_OFF=$'\033[0m'
else
  _C_RED=""; _C_GRN=""; _C_YEL=""; _C_BLD=""; _C_OFF=""
fi

ci_heading() { printf '\n%s== %s ==%s\n' "$_C_BLD" "$*" "$_C_OFF"; }

ci_pass() {
  CI_PASS_COUNT=$((CI_PASS_COUNT + 1))
  printf '  %sPASS%s  %s\n' "$_C_GRN" "$_C_OFF" "$*"
}

ci_fail() {
  CI_FAIL_COUNT=$((CI_FAIL_COUNT + 1))
  CI_FAILURES+=("$*")
  printf '  %sFAIL%s  %s\n' "$_C_RED" "$_C_OFF" "$*"
}

# A skip is NOT a pass. It is recorded separately and reprinted in the summary
# so that a green run never reads as "everything was checked".
ci_skip() {
  CI_SKIP_COUNT=$((CI_SKIP_COUNT + 1))
  CI_SKIPS+=("$*")
  printf '  %sSKIP%s  %s\n' "$_C_YEL" "$_C_OFF" "$*"
}

ci_summary() {
  local label="$1"
  printf '\n%s%s:%s %d passed, %d failed, %d skipped\n' \
    "$_C_BLD" "$label" "$_C_OFF" "$CI_PASS_COUNT" "$CI_FAIL_COUNT" "$CI_SKIP_COUNT"
  if [ "$CI_SKIP_COUNT" -gt 0 ]; then
    printf '%sNOT CHECKED:%s\n' "$_C_YEL" "$_C_OFF"
    printf '  - %s\n' "${CI_SKIPS[@]}"
  fi
  if [ "$CI_FAIL_COUNT" -gt 0 ]; then
    printf '%sFAILURES:%s\n' "$_C_RED" "$_C_OFF"
    printf '  - %s\n' "${CI_FAILURES[@]}"
    return 1
  fi
  return 0
}

# -----------------------------------------------------------------------------
# Tools
# -----------------------------------------------------------------------------
_ci_verify_sha256() {
  local file="$1" want="$2" got
  got="$(sha256sum "$file" | cut -d' ' -f1)"
  if [ "$got" != "$want" ]; then
    echo "sha256 mismatch for $file: expected $want, got $got" >&2
    return 1
  fi
}

_ci_fetch() {
  local url="$1" dest="$2"
  curl --fail --silent --show-error --location --retry 3 --output "$dest" "$url"
}

# helm, at the pinned version. An already-installed helm is used only if its
# version matches exactly, so a developer's newer helm cannot make a local
# `make ci` disagree with the workflow.
ci_helm() {
  if [ -n "${CI_HELM_BIN:-}" ]; then echo "$CI_HELM_BIN"; return 0; fi
  local candidate
  for candidate in "$CI_TOOL_DIR/helm" "$(command -v helm 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" version --short 2>/dev/null | grep -q "^$CI_PIN_HELM_VERSION"; then
      CI_HELM_BIN="$candidate"; echo "$CI_HELM_BIN"; return 0
    fi
  done
  echo "helm $CI_PIN_HELM_VERSION not found; run scripts/ci/tools.sh" >&2
  return 1
}

ci_promtool() {
  if [ -n "${CI_PROMTOOL_BIN:-}" ]; then echo "$CI_PROMTOOL_BIN"; return 0; fi
  local candidate
  for candidate in "$CI_TOOL_DIR/promtool" "$(command -v promtool 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" --version 2>&1 | grep -q "$CI_PIN_PROMETHEUS_VERSION"; then
      CI_PROMTOOL_BIN="$candidate"; echo "$CI_PROMTOOL_BIN"; return 0
    fi
  done
  echo "promtool $CI_PIN_PROMETHEUS_VERSION not found; run scripts/ci/tools.sh" >&2
  return 1
}

ci_kind() {
  if [ -n "${CI_KIND_BIN:-}" ]; then echo "$CI_KIND_BIN"; return 0; fi
  local candidate
  for candidate in "$CI_TOOL_DIR/kind" "$(command -v kind 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" version 2>&1 | grep -q "$CI_PIN_KIND_VERSION"; then
      CI_KIND_BIN="$candidate"; echo "$CI_KIND_BIN"; return 0
    fi
  done
  echo "kind $CI_PIN_KIND_VERSION not found; run scripts/ci/tools.sh" >&2
  return 1
}

# kubectl. Unlike the three above, an already-present kubectl of a DIFFERENT
# version is accepted, with the version reported by the caller. kubectl is
# supported one minor version either side of the server, so requiring an exact
# match would make the greenfield job skip on most developer machines for no
# real reason — and a skip that could have been a run is how coverage
# evaporates. The pinned build is still preferred and is what CI fetches.
ci_kubectl() {
  if [ -n "${CI_KUBECTL_BIN:-}" ]; then echo "$CI_KUBECTL_BIN"; return 0; fi
  local candidate
  for candidate in "$CI_TOOL_DIR/kubectl" "$(command -v kubectl 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    CI_KUBECTL_BIN="$candidate"; echo "$CI_KUBECTL_BIN"; return 0
  done
  echo "kubectl not found; run scripts/ci/tools.sh kind" >&2
  return 1
}

# =============================================================================
# ci_charts_present — drop cases for charts this branch does not ship
# =============================================================================
# The case tables in scripts/ci/values.sh are shared between tiers and name a
# chart in column 2. TIER-1 SHIPS ONLY charts/edge: it is a single-node
# appliance, so there is no management plane, no charts/mgmt, and every mgmt-*
# case is meaningless here rather than broken.
#
# Filtering keeps ONE case table across both tiers, so a case added for tier-2
# is not silently missing from tier-1's copy and vice versa — the alternative
# was deleting rows on this branch, which diverges the file and makes the next
# merge a manual reconciliation.
#
# IT REPORTS WHAT IT DROPPED. A filter that quietly removes half the suite
# turns a green run into a lie; the count is printed once per stage so "21
# passed" can never be mistaken for full coverage.
ci_charts_present() {
    local repo dropped=0 kept=0 line chart
    repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        chart="$(printf '%s' "$line" | cut -f2)"
        if [ -n "$chart" ] && [ ! -d "${repo}/${chart}" ]; then
            dropped=$((dropped + 1)); continue
        fi
        kept=$((kept + 1))
        printf '%s\n' "$line"
    done
    [ "$dropped" -gt 0 ] && \
        printf '  (%d case(s) skipped: this branch ships no charts/mgmt; %d ran)\n' \
               "$dropped" "$kept" >&2
    return 0
}

# =============================================================================
# ci_obs_chart — which chart ships the observability content on THIS branch
# =============================================================================
# Tier-2 keeps the alert rules, dashboards and Alertmanager config in
# charts/mgmt; tier-1 has no management chart and ships them in charts/edge.
# Stages that check that content hardcoded charts/mgmt, so on tier-1 they failed
# with FileNotFoundError rather than checking the files that actually exist.
ci_obs_chart() {
    local repo; repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    if [ -d "${repo}/charts/mgmt/files/prometheus-rules" ]; then echo "charts/mgmt"
    else echo "charts/edge"; fi
}

# =============================================================================
# ci_renders_present — drop expectation rows whose render does not exist
# =============================================================================
# The runtime-template expectation table is keyed by RENDER NAME in column 1 and
# is shared between tiers. A single-node branch renders no mgmt-* cases, so every
# mgmt row is checking a file that was never produced — a false failure, not a
# missing template.
#
# REPORTS THE COUNT, like ci_charts_present. A filter that silently removes most
# of a table turns a green run into a lie.
ci_renders_present() {
    local dropped=0 kept=0 line case_name
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case_name="$(printf '%s' "$line" | cut -f1)"
        if [ -n "$case_name" ] && [ ! -s "${CI_RENDER_DIR}/${case_name}.yaml" ]; then
            dropped=$((dropped + 1)); continue
        fi
        kept=$((kept + 1)); printf '%s\n' "$line"
    done
    [ "$dropped" -gt 0 ] && \
        printf '  (%d expectation(s) skipped: no render for them on this branch; %d checked)\n' \
               "$dropped" "$kept" >&2
    return 0
}
