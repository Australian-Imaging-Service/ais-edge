#!/usr/bin/env bash
# =============================================================================
# 1. helm lint + helm template across the values matrix, for BOTH charts.
# =============================================================================
# Every case in scripts/ci-values.sh must lint clean and render. The rendered
# output is kept in $CI_RENDER_DIR/<case>.yaml and is the input to the
# PVC-retention and runtime-template checks, so those assert against exactly
# what CI rendered rather than re-rendering with slightly different values.
#
# The render is also parsed as YAML. `helm template` succeeding does not mean
# the output is valid YAML — an indentation bug in a `nindent` produces
# something helm is happy to print and the API server rejects.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci-values.sh
. "$HERE/ci-values.sh"

HELM="$(ci_helm)"
rm -rf "$CI_RENDER_DIR"
mkdir -p "$CI_RENDER_DIR"

ci_heading "helm lint"
# Lint once per chart per DISTINCT values combination: lint runs the templates,
# so a combination that only renders under `helm template` is not proven.
#
# MEASURED, and the reason the output is inspected rather than the exit code:
# with helm v3.20.1 and a chart that has subcharts, a `fail` raised inside a
# template is reported as
#     engine.go:227: [INFO] Fail: <message>
#     1 chart(s) linted, 0 chart(s) failed
# and `helm lint` EXITS 0. Trusting the exit code alone would have made every
# guard in charts/mgmt invisible to the lint stage. `helm template` below does
# fail correctly, which is why both run.
while IFS=$'\t' read -r name chart valuesfiles; do
  [ -n "$name" ] || continue
  args=()
  for v in $valuesfiles; do args+=(-f "$CI_VALUES_DIR/$v"); done
  rc=0
  out="$("$HELM" lint "$REPO_ROOT/$chart" "${args[@]}" 2>&1)" || rc=$?
  bad=0
  [ "$rc" -ne 0 ] && bad=1
  printf '%s\n' "$out" | grep -qE '\[ERROR\]|\] Fail:' && bad=1
  if [ "$bad" -eq 1 ]; then
    ci_fail "lint $name (exit $rc)"
    printf '%s\n' "$out" | sed 's/^/        /'
  else
    ci_pass "lint $name"
  fi
done < <(ci_positive_cases)

ci_heading "helm template"
while IFS=$'\t' read -r name chart valuesfiles; do
  [ -n "$name" ] || continue
  args=()
  for v in $valuesfiles; do args+=(-f "$CI_VALUES_DIR/$v"); done
  # Release name differs per chart so the release-name-derived labels and
  # hostnames are exercised, not defaulted away.
  release="mgmt"; ns="ais-mgmt"
  case "$chart" in */edge) release="edge"; ns="xnat-ingest" ;; esac

  dest="$CI_RENDER_DIR/$name.yaml"
  if out="$("$HELM" template "$release" "$REPO_ROOT/$chart" "${args[@]}" \
              --namespace "$ns" 2>&1 >"$dest")"; then
    :
  else
    ci_fail "template $name"
    printf '%s\n' "$out" | sed 's/^/        /'
    rm -f "$dest"
    continue
  fi

  if [ ! -s "$dest" ]; then
    ci_fail "template $name produced NO output — a chart that renders nothing passes every other check in this suite"
    continue
  fi

  # Parse it. `helm template` will happily emit YAML the API server rejects.
  if err="$(python3 -c '
import sys, yaml
docs = list(yaml.safe_load_all(open(sys.argv[1])))
n = len([d for d in docs if d])
if n == 0:
    raise SystemExit("no Kubernetes objects in the render")
print(n)
' "$dest" 2>&1)"; then
    ci_pass "template $name ($err objects)"
  else
    ci_fail "template $name rendered invalid YAML: $err"
  fi
done < <(ci_positive_cases)

ci_summary "render"
