#!/usr/bin/env bash
# =============================================================================
# 3. promtool check rules + promtool test rules
# =============================================================================
# Three passes:
#
#   a) check   the source rule files in charts/mgmt/files/prometheus-rules/
#   b) test    the unit tests in .../prometheus-rules/tests/
#   c) check   the rules AS RENDERED into the PrometheusRule objects
#
# (c) is not redundant. The rules reach the cluster through
# `.Files.Get $path | nindent 2` in templates/observability.yaml; an
# indentation change there produces a PrometheusRule that helm prints happily,
# Kubernetes accepts as an opaque spec, and Prometheus then refuses to load —
# with the only symptom being alerts that never fire. Checking the source files
# alone cannot see that.
#
# NOT COVERED HERE, deliberately: files/loki-ruler-rules.yaml. Those are LogQL
# and promtool only speaks PromQL, so pointing it at them would report
# confident nonsense. Testing them needs a running Loki ruler and is a separate
# job, not this one.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci-lib.sh
. "$HERE/ci-lib.sh"

PROMTOOL="$(ci_promtool)"
RULES_DIR="$REPO_ROOT/charts/mgmt/files/prometheus-rules"
TESTS_DIR="$RULES_DIR/tests"

# -----------------------------------------------------------------------------
ci_heading "promtool check rules (source)"
shopt -s nullglob
rule_files=("$RULES_DIR"/*.yaml)
if [ "${#rule_files[@]}" -eq 0 ]; then
  ci_fail "no rule files in $RULES_DIR — the alerting stack would be empty and nothing else here would notice"
fi
for f in "${rule_files[@]}"; do
  if out="$("$PROMTOOL" check rules "$f" 2>&1)"; then
    ci_pass "check $(basename "$f") — $(printf '%s' "$out" | grep -o '[0-9]* rules found' | head -1)"
  else
    ci_fail "check $(basename "$f")"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
done

# -----------------------------------------------------------------------------
ci_heading "promtool test rules"
test_files=("$TESTS_DIR"/*_test.yaml)
if [ "${#test_files[@]}" -eq 0 ]; then
  ci_fail "no unit tests in $TESTS_DIR — SeaweedFSDiskFull shipped selecting a metric series that does not exist and was green its whole life; these tests are what catches that"
fi
for f in "${test_files[@]}"; do
  # rule_files inside a test file are relative to the test file, so run from
  # its directory.
  if out="$(cd "$TESTS_DIR" && "$PROMTOOL" test rules "$(basename "$f")" 2>&1)"; then
    ci_pass "test $(basename "$f")"
  else
    ci_fail "test $(basename "$f")"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
done

# -----------------------------------------------------------------------------
# Rule files with no unit test. Not a failure by default — writing the tests is
# separate work — but it IS reported in the summary's NOT CHECKED list, because
# an untested alert rule reads as coverage and is the exact defect this suite
# exists for. Set CI_REQUIRE_RULE_TESTS=1 to make it a failure.
ci_heading "rule-test coverage"
for f in "${rule_files[@]}"; do
  base="$(basename "$f" .yaml)"
  if [ -f "$TESTS_DIR/${base}_test.yaml" ]; then
    ci_pass "$base.yaml has ${base}_test.yaml"
  elif [ "${CI_REQUIRE_RULE_TESTS:-0}" = "1" ]; then
    ci_fail "$base.yaml has no ${base}_test.yaml — every rule needs a test that proves it fires on the condition it claims to detect"
  else
    ci_skip "$base.yaml has no ${base}_test.yaml: its rules are syntax-checked but NOT proven to fire"
  fi
done

# -----------------------------------------------------------------------------
ci_heading "promtool check rules (as rendered into PrometheusRule objects)"
render="$CI_RENDER_DIR/mgmt-defaults.yaml"
if [ ! -s "$render" ]; then
  ci_fail "no render at $render — run scripts/ci-render.sh first (make ci does)"
else
  extract_dir="$CI_WORK_DIR/rendered-rules"
  rm -rf "$extract_dir"; mkdir -p "$extract_dir"
  count="$(python3 -c '
import sys, yaml, os
src, dest = sys.argv[1], sys.argv[2]
n = 0
for d in yaml.safe_load_all(open(src)):
    if not d or d.get("kind") != "PrometheusRule":
        continue
    name = d["metadata"]["name"]
    spec = d.get("spec") or {}
    if not spec.get("groups"):
        raise SystemExit(f"PrometheusRule {name} has no groups — it renders as an empty rule set")
    with open(os.path.join(dest, name + ".yaml"), "w") as fh:
        yaml.safe_dump(spec, fh, default_flow_style=False)
    n += 1
print(n)
' "$render" "$extract_dir" 2>&1)" || { ci_fail "extracting PrometheusRules: $count"; count=0; }

  if [ "$count" = "0" ]; then
    ci_fail "the mgmt render contains NO PrometheusRule objects"
  else
    for f in "$extract_dir"/*.yaml; do
      if out="$("$PROMTOOL" check rules "$f" 2>&1)"; then
        ci_pass "rendered $(basename "$f" .yaml)"
      else
        ci_fail "rendered $(basename "$f" .yaml) is not a loadable rule set"
        printf '%s\n' "$out" | sed 's/^/        /'
      fi
    done
  fi
fi

ci_summary "promtool"
