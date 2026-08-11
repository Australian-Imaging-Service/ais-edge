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
# shellcheck source=scripts/ci/lib.sh
. "$HERE/lib.sh"

PROMTOOL="$(ci_promtool)"
RULES_DIR="$REPO_ROOT/$(ci_obs_chart)/files/prometheus-rules"

# Which alerts must exist depends on the TIER. s3-uploader and the S3 reclaimer
# do not exist on a single node, so naming them here would demand rules for
# components that were deliberately removed.
if [ "$(ci_obs_chart)" = "charts/mgmt" ]; then
    export LOOPING_LOG_ALERTS="S3UploaderRestartedRecently XNATAuthFailure XNATUploadSuccess"
    export ABSENCE_ALERTS="SessionStagedNotConfirmedInXNAT ReclaimerRunUnavailable"
else
    export LOOPING_LOG_ALERTS="XNATAuthFailure XNATUploadSuccess"
    export ABSENCE_ALERTS=""   # no reclaimer on a single node — nothing of this shape to check
fi
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
# Which render carries the PrometheusRule objects depends on the tier: tier-2
# renders them from charts/mgmt, tier-1 from charts/edge.
if [ -s "$CI_RENDER_DIR/mgmt-defaults.yaml" ]; then
  render="$CI_RENDER_DIR/mgmt-defaults.yaml"
else
  render="$CI_RENDER_DIR/edge-obsstack-on.yaml"
fi
if [ ! -s "$render" ]; then
  ci_fail "no render at $render — run scripts/ci/render.sh first (make ci does)"
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
    ci_fail "the render $(basename "$render") contains NO PrometheusRule objects"
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

# -----------------------------------------------------------------------------
# Recurring-log rules must out-range the emitter's loop period
# -----------------------------------------------------------------------------
# A log line that a looping process re-emits every pass is a LEVEL, not an
# event. If the rule's range is shorter than the gap between passes, the series
# goes empty between them and the alert resolves and re-fires on every loop.
# Alertmanager treats each re-fire as a new alert — grouping only collapses
# alerts firing at the same time — so the operator gets mail once per loop.
#
# This bit us for real: XNATUploadSuccess ran a [1m] range against an uploader
# that re-scans every ~62s, and one drop produced three mails. The rules below
# all match output that is re-emitted on a loop, so each needs headroom over
# that period rather than a range that merely "looks recent".
# -----------------------------------------------------------------------------
# LogQL absence must be expressed with `unless`, and joins must pin their labels
# -----------------------------------------------------------------------------
# promtool speaks PromQL, not LogQL, so nothing else in this suite can look at
# files/loki-ruler-rules.yaml. These two patterns both fail SILENTLY — the rule
# loads, reports healthy, and never fires — so they need catching by text.
#
# 1. `count_over_time(...) == 0` CANNOT EXPRESS ABSENCE. If the selector matches
#    nothing there is no series to compare with, so the result is EMPTY rather
#    than a series carrying 0. `X and (Y == 0)` is therefore empty in exactly the
#    case it was written to detect. Use `X unless on (...) Y`.
#
# 2. `and ignoring (<label>)` / `unless ignoring (<label>)` drops the label the
#    join should be pinned to, so one site's data satisfies another site's
#    condition. Measured on this deployment: an LHS holding edge-dev and mgmt
#    against an RHS holding mgmt alone returned BOTH series under
#    `and ignoring (cluster)`.
#
# XNATUploadFailingForAllSessions had both at once, and it is the only critical
# alert on the edge upload path. Verified live against Loki afterwards: the old
# form returned no series while the rewritten one fires on the same data.
ci_heading "LogQL rules express absence with unless, and pin their joins"
python3 - "$REPO_ROOT/$(ci_obs_chart)/files/loki-ruler-rules.yaml" <<'PY' > "$CI_WORK_DIR/logql-shape.txt" 2>&1 || true
import re, sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
checked = 0
for group in doc.get("groups", []):
    for rule in group.get("rules", []):
        name = rule.get("alert")
        if not name:
            continue
        # Strip comments so prose describing the antipattern is not flagged.
        expr = "\n".join(
            l for l in (rule.get("expr") or "").splitlines() if not l.strip().startswith("#")
        )
        if not expr.strip():
            continue
        checked += 1
        if re.search(r"==\s*0", expr):
            print(f"FAIL {name}: compares a range aggregation to 0. An empty LogQL result "
                  "is EMPTY, not zero, so this is silent exactly when the thing is absent "
                  "— express absence with `unless on (...)`")
        elif re.search(r"\b(and|unless|or)\s+ignoring\s*\(", expr):
            lbl = re.search(r"\bignoring\s*\(([^)]*)\)", expr).group(1).strip()
            print(f"FAIL {name}: joins with `ignoring ({lbl})`, which matches series across "
                  "sites — one cluster's data can satisfy another's condition. Pin the join "
                  "with `on (...)` instead")
        else:
            print(f"PASS {name}")

if checked == 0:
    print("FAIL no LogQL alert expressions were examined — the check is looking at nothing")
PY

if [ ! -s "$CI_WORK_DIR/logql-shape.txt" ]; then
  ci_fail "LogQL shape check produced no output"
else
  logql_bad=0
  while IFS= read -r line; do
    case "$line" in
      FAIL\ *) ci_fail "${line#FAIL }"; logql_bad=$((logql_bad+1)) ;;
      PASS\ *) : ;;
      *)       ci_fail "LogQL shape check error: $line"; logql_bad=$((logql_bad+1)) ;;
    esac
  done < "$CI_WORK_DIR/logql-shape.txt"
  [ "$logql_bad" -eq 0 ] && ci_pass "$(grep -c '^PASS' "$CI_WORK_DIR/logql-shape.txt") LogQL rule(s) express absence and joins correctly"
fi

ci_heading "recurring-log alert rules have a range above the emitter loop period"
MIN_RANGE_MINUTES=5
python3 - "$REPO_ROOT/$(ci_obs_chart)/files/loki-ruler-rules.yaml" "$MIN_RANGE_MINUTES" <<'PY' > "$CI_WORK_DIR/range-check.txt" 2>&1 || true
import re, sys, yaml

path, minimum = sys.argv[1], int(sys.argv[2])

# Alerts whose source log is re-emitted by a polling loop rather than fired once
# per real-world event. An alert NOT listed here may legitimately use a short
# range (a rate of genuinely distinct events, say).
# TIER-AWARE: s3-uploader does not exist on a single node, so demanding a rule
# for it would require an alert on a component that was deliberately removed.
import os
LOOPING = set(os.environ.get("LOOPING_LOG_ALERTS", "XNATUploadSuccess XNATAuthFailure").split())
UNITS = {"s": 1 / 60, "m": 1, "h": 60, "d": 1440}

doc = yaml.safe_load(open(path))
seen = set()
for group in doc.get("groups", []):
    for rule in group.get("rules", []):
        name = rule.get("alert")
        if name not in LOOPING:
            continue
        seen.add(name)
        ranges = [
            float(v) * UNITS[u]
            for v, u in re.findall(r"\[(\d+(?:\.\d+)?)([smhd])\]", rule.get("expr", ""))
        ]
        if not ranges:
            print(f"FAIL {name}: no range selector found")
        elif min(ranges) < minimum:
            print(
                f"FAIL {name}: range {min(ranges):g}m is under the {minimum}m floor — "
                "it will resolve between loops and re-notify on every pass"
            )
        else:
            print(f"PASS {name}: shortest range {min(ranges):g}m")

for missing in sorted(LOOPING - seen):
    print(f"FAIL {missing}: named as a looping-log rule but not present in the ruleset")
PY

if [ ! -s "$CI_WORK_DIR/range-check.txt" ]; then
  ci_fail "range check produced no output"
else
  while IFS= read -r line; do
    case "$line" in
      PASS\ *) ci_pass "${line#PASS }" ;;
      FAIL\ *) ci_fail "${line#FAIL }" ;;
      *)       ci_fail "range check error: $line" ;;
    esac
  done < "$CI_WORK_DIR/range-check.txt"
fi

# -----------------------------------------------------------------------------
# No change-detecting function over a constant-1 join metric
# -----------------------------------------------------------------------------
# kube-state-metrics publishes *_info, *_labels and *_annotations as JOIN
# metrics: the value is the constant 1 and every fact lives in a label. A new
# object creates a NEW SERIES at 1 — it never moves an existing value — so
# changes(), delta(), rate() and the rest are identically 0 over one of them
# and the rule is silent for its entire life.
#
# NewEdgeJoined shipped as `changes(kube_node_info[10m]) > 0` and never
# produced a single sample. THE UNIT TEST ABOVE IS WHY THIS CHECK IS HERE AND
# NOT THERE: it passed, because it drove kube_node_info "1+0x20 2+0x20" and
# kube-state-metrics never emits a 2. A test can supply a series that reality
# cannot, so no amount of promtool coverage rules this class out — and
# check-alert-inputs.sh could not either, since the metric does exist, it just
# never varies. The defect is visible only in the EXPRESSION, so that is what
# gets checked.
#
# Matched on the metric-name SUFFIX. No release name, namespace or site name
# appears here on purpose: CI renders under several, and a check that names one
# is a check that quietly stops applying to the others.
#
# KNOWN LIMIT, stated rather than papered over: the pattern reads the metric
# directly inside the function call, so a wrapped form such as
# changes(sum(kube_node_info)) slips past. Widening it to parse nested PromQL
# buys little — the mistake this class produces is written the short way — and
# costs a hand-rolled expression parser that would itself need tests.
ci_heading "no change-detecting function over a constant-1 join metric"
python3 - "$RULES_DIR" <<'PY' > "$CI_WORK_DIR/info-metric-check.txt" 2>&1 || true
import os, re, sys, yaml

rules_dir = sys.argv[1]

# kube-state-metrics naming conventions for metrics whose value is always 1.
CONSTANT_ONE = ("_info", "_labels", "_annotations")

# Functions that can only report a CHANGE in a value over a range. Every one of
# them evaluates to 0 on a series that never moves.
CHANGE_FN = ("changes", "delta", "idelta", "deriv", "resets",
             "rate", "irate", "increase")

CALL = re.compile(
    r"\b(" + "|".join(CHANGE_FN) + r")\s*\(\s*([a-zA-Z_:][a-zA-Z0-9_:]*)"
)

checked = 0
bad = 0
for fn in sorted(os.listdir(rules_dir)):
    if not fn.endswith((".yaml", ".yml")):
        continue
    doc = yaml.safe_load(open(os.path.join(rules_dir, fn)))
    if not isinstance(doc, dict):
        continue
    for grp in doc.get("groups") or []:
        for rule in grp.get("rules") or []:
            name = rule.get("alert") or rule.get("record")
            if not name:
                continue
            checked += 1
            for func, metric in CALL.findall(rule.get("expr", "")):
                if metric.endswith(CONSTANT_ONE):
                    bad += 1
                    print(
                        f"FAIL {fn}: {name} applies {func}() to {metric}, whose "
                        "value is the constant 1 — a new object appears as a new "
                        "SERIES, not as a changed value, so this is identically 0 "
                        "and the rule can never fire"
                    )

if not bad:
    print(f"PASS {checked} rule expressions, none over a constant-1 join metric")
PY

if [ ! -s "$CI_WORK_DIR/info-metric-check.txt" ]; then
  ci_fail "constant-1 join metric check produced no output"
else
  while IFS= read -r line; do
    case "$line" in
      PASS\ *) ci_pass "${line#PASS }" ;;
      FAIL\ *) ci_fail "${line#FAIL }" ;;
      *)       ci_fail "constant-1 join metric check error: $line" ;;
    esac
  done < "$CI_WORK_DIR/info-metric-check.txt"
fi

# -----------------------------------------------------------------------------
# The reclaimer silence guards
# -----------------------------------------------------------------------------
# THIS IS THE NEAREST THING TO A UNIT TEST THESE RULES CAN HAVE. promtool
# `test rules` evaluates PromQL; the rules below are LogQL, so pointing it at
# them would report confident nonsense (see the note at the top of this file).
# What CAN be asserted without a Loki ruler is the STRUCTURE the fix depends
# on, and that is where a regression would come from — nobody is going to
# rewrite these expressions, but someone will reasonably "tidy" a regex.
#
# The failure being guarded: on 2026-08-05/06 the reclaimer aborted its
# pre-flight twice and logged one reclaim_unavailable with session="" each
# time, and nothing alerted on either. SessionStagedNotConfirmedInXNAT filters
# `session != ""`, so an aborted run contributes nothing to its staged half.
# Those two isolated aborts did not actually mute it — its range is a 24h count
# and the healthy runs either side kept it fed — but a pre-flight that stays
# broken for a whole 24h window would, which is an absence alert silenced by
# the absence it exists to detect.
#
# Two properties keep that fixed, and each is one edit away from being undone:
#   1. the staged half matches event=~"reclaim_.*" — a narrowed list of the
#      "interesting" outcomes would drop the per-session reclaim_unavailable
#      events the reclaimer now fans out, and re-mute the alert;
#   2. ReclaimerRunUnavailable exists, counts RUNS (session = ""), and ranges
#      well past the hourly CronJob so one aborted run cannot resolve before
#      the next run reasserts it.
ci_heading "reclaimer pre-flight failure is visible in the Loki rules"
python3 - "$REPO_ROOT/$(ci_obs_chart)/files/loki-ruler-rules.yaml" <<'PY' > "$CI_WORK_DIR/reclaimer-silence.txt" 2>&1 || true
import re, sys, yaml

doc = yaml.safe_load(open(sys.argv[1]))
rules = {r["alert"]: r for g in doc.get("groups", []) for r in g.get("rules", []) if r.get("alert")}

# TIER-AWARE: the staging bucket and the reclaimer are tier-2 only, so on
# tier-1 the absence alert that matters is the backlog one instead.
import os
_ABS = os.environ.get("ABSENCE_ALERTS", "SessionStagedNotConfirmedInXNAT").split()
if not _ABS:
    print("SKIP absence-alert check: this tier has no reclaimer, so no rule of that shape exists")
    raise SystemExit
_absname = _ABS[0]
absence = rules.get(_absname)
if absence is None:
    print("FAIL %s is gone — the only absence alert in the ruleset" % _absname)
elif 'event=~"reclaim_.*"' not in absence.get("expr", ""):
    print(
        'FAIL %s no longer matches event=~"reclaim_.*" — ' % _absname +
        "narrowing it drops the per-session reclaim_unavailable events, so a reclaimer "
        "that cannot reach XNAT silences this alert instead of raising it"
    )
else:
    print('PASS %s is present as the absence alert' % _absname)

run = rules.get("ReclaimerRunUnavailable") if os.environ.get("ABSENCE_ALERTS","x").strip() else "SKIP"
if run is None:
    print(
        "FAIL ReclaimerRunUnavailable is missing — an aborted reclaim run would go "
        "unreported for the 48h the absence alert takes to notice"
    )
else:
    expr = run.get("expr", "")
    if 'event="reclaim_unavailable"' not in expr:
        print("FAIL ReclaimerRunUnavailable does not select event=\"reclaim_unavailable\"")
    elif 'session = ""' not in expr:
        print(
            "FAIL ReclaimerRunUnavailable does not filter session = \"\" — it would count "
            "the per-session fan-out and report one aborted run as many failures"
        )
    else:
        # The CronJob is hourly (dataPolicy.derived.s3Staged.reclaimSchedule).
        # A range at or below that resolves between runs and re-notifies every
        # cycle, which is the XNATUploadSuccess mistake in a new place.
        units = {"s": 1 / 3600, "m": 1 / 60, "h": 1, "d": 24}
        ranges = [float(v) * units[u] for v, u in re.findall(r"\[(\d+(?:\.\d+)?)([smhd])\]", expr)]
        if not ranges:
            print("FAIL ReclaimerRunUnavailable has no range selector")
        elif min(ranges) <= 1:
            print(
                f"FAIL ReclaimerRunUnavailable range {min(ranges):g}h does not clear the hourly "
                "reclaim schedule — it would resolve between runs and re-notify on every cycle"
            )
        else:
            print(f"PASS ReclaimerRunUnavailable counts runs over {min(ranges):g}h")
PY

if [ ! -s "$CI_WORK_DIR/reclaimer-silence.txt" ]; then
  ci_fail "reclaimer silence check produced no output"
else
  while IFS= read -r line; do
    case "$line" in
      PASS\ *) ci_pass "${line#PASS }" ;;
      FAIL\ *) ci_fail "${line#FAIL }" ;;
      SKIP\ *) ci_skip "${line#SKIP }" ;;
      *)       ci_fail "reclaimer silence check error: $line" ;;
    esac
  done < "$CI_WORK_DIR/reclaimer-silence.txt"
fi


# =============================================================================
# The Loki ruler file must satisfy Loki's OWN schema, not merely be valid YAML.
# =============================================================================
# Loki parses each file into rulefmt.RuleGroup. A rule that escapes its group —
# landing as a top-level entry under `groups:` with `alert`/`expr` keys instead
# of inside a group's `rules:` — is still perfectly valid YAML, still counts as
# an alert to anything that greps for `alert:`, and is what this repo produced
# by appending two alerts to the file as text.
#
# Loki's reaction is total, not partial:
#   unable to list rules ... error parsing /rules/fake/ais-edge-rules.yaml:
#   field alert not found in type rulefmt.RuleGroup
# It refuses the WHOLE file, so all 11 alerts stop existing — including the
# nine that were formatted correctly. Found by installing for real; every
# static check in this suite was green.
ci_heading "Loki ruler file matches rulefmt.RuleGroup"

for rules_file in "$REPO_ROOT"/charts/*/files/loki-ruler-rules.yaml; do
  [ -e "$rules_file" ] || continue
  rel="${rules_file#"$REPO_ROOT"/}"
  out="$(python3 - "$rules_file" <<'PY'
import sys, yaml
ALLOWED = {"name", "interval", "limit", "rules"}
try:
    doc = yaml.safe_load(open(sys.argv[1]))
except Exception as exc:
    print(f"FAIL not parseable as YAML: {exc}"); raise SystemExit
if not isinstance(doc, dict) or "groups" not in doc:
    print("FAIL top level must be a mapping with a `groups:` key"); raise SystemExit
groups = doc.get("groups") or []
if not groups:
    print("FAIL `groups:` is empty — Loki would evaluate nothing"); raise SystemExit
total = 0
for i, g in enumerate(groups):
    if not isinstance(g, dict):
        print(f"FAIL groups[{i}] is not a mapping"); raise SystemExit
    stray = sorted(set(g) - ALLOWED)
    if stray:
        who = g.get("alert") or g.get("record") or "<unnamed>"
        print(f"FAIL groups[{i}] ({who}) has keys Loki rejects on a RuleGroup: {stray}. "
              f"A rule escaped its group — it belongs under some group's `rules:`. "
              f"Loki refuses the ENTIRE file, so every other alert stops existing too.")
        raise SystemExit
    if not g.get("name"):
        print(f"FAIL groups[{i}] has no name"); raise SystemExit
    rules = g.get("rules") or []
    if not rules:
        print(f"FAIL group {g['name']!r} has no rules"); raise SystemExit
    for r in rules:
        if not (r.get("alert") or r.get("record")):
            print(f"FAIL a rule in {g['name']!r} has neither alert nor record"); raise SystemExit
        if not r.get("expr"):
            print(f"FAIL {r.get('alert') or r.get('record')} has no expr"); raise SystemExit
    total += len(rules)
print(f"PASS {len(groups)} group(s), {total} rule(s), every group a valid RuleGroup")
PY
)"
  case "$out" in
    PASS*) ci_pass "$rel: ${out#PASS }" ;;
    *)     ci_fail "$rel: ${out#FAIL }" ;;
  esac
done


# =============================================================================
# An alert that exists on BOTH tiers must differ only by namespace.
# =============================================================================
# The two tiers ship separate ruleset files because tier-2 has components
# tier-1 does not (s3-uploader, s3-reclaimer, a staging bucket). That is a good
# reason for the FILES to differ and a bad reason for a SHARED alert to.
#
# XNATUploadSuccess drifted exactly this way: tier-2 extracts the session with
# `regexp` and groups `by (cluster, session)`, so each completed session pages
# separately — which is the whole point, and what alertmanager-config.yaml's
# group_by ["alertname","cluster","session"] is built around. The tier-1 copy
# was rewritten to `by (cluster)` with no extraction while fixing an unrelated
# range-vs-loop-period problem. It still fired, still said "XNAT upload
# completed", and silently stopped naming the session — so every upload
# collapsed into ONE alertmanager group instead of one per session.
#
# Compared against the tier-2 file on `main` when that ref is available; skipped
# with a reason when it is not, so a shallow checkout cannot read as coverage.
ci_heading "shared alerts match the other tier"

t1_rules="$REPO_ROOT/charts/edge/files/loki-ruler-rules.yaml"
if [ ! -f "$t1_rules" ] || [ -d "$REPO_ROOT/charts/mgmt" ]; then
  ci_skip "not a single-node checkout — the cross-tier comparison runs from the tier-1 side"
elif ! git -C "$REPO_ROOT" cat-file -e main:charts/mgmt/files/loki-ruler-rules.yaml 2>/dev/null; then
  ci_skip "main:charts/mgmt/files/loki-ruler-rules.yaml is not fetched — cannot compare tiers"
else
  # The tier-2 file goes to a FILE, not a pipe. `python3 - <<'PY'` reads its
  # SCRIPT from stdin, so piping into it replaces the data with the script and
  # the comparison silently runs against nothing — the same trap this repo's
  # Loki test harness documents, and it produced a check that printed no
  # verdict at all rather than failing.
  t2_rules="$CI_WORK_DIR/tier2-loki-rules.yaml"
  git -C "$REPO_ROOT" show main:charts/mgmt/files/loki-ruler-rules.yaml > "$t2_rules" 2>/dev/null
  out="$(python3 - "$t1_rules" "$t2_rules" <<'PY'
import sys, yaml
def index(doc):
    return {x["alert"]: x for g in (doc or {}).get("groups", [])
            for x in (g.get("rules") or []) if x.get("alert")}
t1 = index(yaml.safe_load(open(sys.argv[1])))
t2 = index(yaml.safe_load(open(sys.argv[2])))
def norm(o):
    # The ONLY legitimate difference: tier-2 splits upload into its own
    # namespace, tier-1 has exactly one.
    return yaml.safe_dump(o, sort_keys=True).replace('xnat-upload', 'xnat-ingest')
# Divergences forced by the single-namespace collapse, not drift. Tier-2's
# xnat-upload namespace holds only the uploader; tier-1's one namespace also
# holds Loki, Grafana and Prometheus, so these two must select the component.
# Listed by name and PRINTED, so an exemption can never be silent.
FORCED = {
    "XNATUploadSuccess": "scoped to component=upload — a bare namespace selector matched Loki's own ruler-query log, which contains both the success phrase and the regexp, and fired an alert about its own evaluation",
    "XNATAuthFailure":   "scoped to component=upload — a bare namespace selector matched a 401/403 logged by any pod in the namespace",
}
bad = [n for n in sorted(set(t1) & set(t2))
       if n not in FORCED and norm(t1[n]) != norm(t2[n])]
# To STDERR: stdout is the verdict this check is parsed from, and a NOTE on it
# made the caller read "NOTE ..." as the result instead of PASS.
for n in sorted(FORCED):
    if n in t1:
        print(f"    note: {n} — {FORCED[n]}", file=sys.stderr)
shared = len(set(t1) & set(t2))
if bad:
    print("FAIL " + ", ".join(bad))
else:
    print(f"PASS {shared} shared alert(s) identical modulo namespace")
PY
)"
  case "$out" in
    PASS*) ci_pass "${out#PASS }" ;;
    *)     ci_fail "these alerts exist on both tiers but differ by more than the namespace: ${out#FAIL }. Port the tier-2 rule verbatim and change only the namespace, or give the divergence a reason in the file header." ;;
  esac
fi


# =============================================================================
# No tier-1 Loki rule may select the whole namespace.
# =============================================================================
# Tier-1 runs the pipeline AND the observability stack in one namespace, so
# {namespace="xnat-ingest"} with no component matches Loki, Grafana, Prometheus
# and Alertmanager as well as the pipeline. That is how XNATUploadSuccess came
# to match Loki logging its own ruler query and fire an alert whose session
# label was the regexp pattern.
ci_heading "no Loki rule selects the whole namespace"

for rules_file in "$REPO_ROOT"/charts/edge/files/loki-ruler-rules.yaml; do
  [ -e "$rules_file" ] || continue
  [ -d "$REPO_ROOT/charts/mgmt" ] && { ci_skip "tier-2 keeps the pipeline in its own namespace — this only applies to a single-node checkout"; continue; }
  out="$(python3 - "$rules_file" <<'PY'
import sys, re, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
bad = []
for g in d.get("groups", []):
    for r in (g.get("rules") or []):
        expr = " ".join(str(r.get("expr", "")).split())
        for sel in re.findall(r"\{[^}]*\}", expr):
            if "namespace=" in sel and "component=" not in sel and "app=" not in sel:
                bad.append(f"{r.get('alert')} {sel}")
print(("FAIL " + "; ".join(sorted(set(bad)))) if bad else "PASS every selector names a component or app")
PY
)"
  case "$out" in
    PASS*) ci_pass "${out#PASS }" ;;
    *)     ci_fail "these rules select the whole namespace, which on one node also matches Loki/Grafana/Prometheus logs: ${out#FAIL }" ;;
  esac
done

ci_summary "promtool"
