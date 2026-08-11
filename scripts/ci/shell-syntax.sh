#!/usr/bin/env bash
# =============================================================================
# 4. bash -n over every shell script in scripts/ and charts/*/files/
# =============================================================================
# charts/*/files/ matters more than scripts/ here. Those scripts are loaded
# with .Files.Get into a ConfigMap and only ever execute inside a container, so
# a syntax error does not surface as a failed command — it surfaces as a
# CrashLoopBackOff on the S3 uploader or the staged-data reclaimer, on a node
# nobody is watching, some time after the install reported success.
#
# `bash -n` parses without executing. It catches unbalanced quotes, unclosed
# heredocs and broken if/fi — which is the class of damage a careless edit to a
# 200-line embedded script does.
#
# What it does NOT catch: unset variables, wrong logic, an `aws` call whose
# failure is swallowed by a pipe. It is a syntax gate, not a review.
#
# Files are discovered, never listed: a list is a thing that goes stale, and a
# new script silently outside CI is the failure mode this is meant to prevent.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "$HERE/lib.sh"

ci_heading "bash -n"

found=0
while IFS= read -r f; do
  rel="${f#"$REPO_ROOT"/}"
  found=$((found + 1))

  # Pick the interpreter from the shebang. `bash -n` on a POSIX-sh script is
  # still a valid parse check, but a genuinely /bin/sh script should be parsed
  # by sh so that a bashism does not slip through as "fine".
  shell="bash"
  first="$(head -1 "$f")"
  case "$first" in
    *"/bin/sh"|*"env sh") shell="sh" ;;
  esac

  if out="$("$shell" -n "$f" 2>&1)"; then
    ci_pass "$shell -n $rel"
  else
    ci_fail "$shell -n $rel"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
done < <(
  find "$REPO_ROOT/scripts" "$REPO_ROOT/charts" -type f \
       \( -name '*.sh' -o -name '*.bash' \) 2>/dev/null | sort
  # Extensionless scripts that are shell by shebang rather than by name.
  find "$REPO_ROOT/scripts" "$REPO_ROOT/charts" -type f ! -name '*.*' 2>/dev/null \
    | while IFS= read -r c; do
        head -1 "$c" | grep -qE '^#!.*(\bsh|\bbash)\b' && printf '%s\n' "$c"
      done
  # install.sh and friends at the repo root.
  find "$REPO_ROOT" -maxdepth 1 -type f -name '*.sh' 2>/dev/null | sort
)

if [ "$found" -eq 0 ]; then
  ci_fail "no shell scripts found — the discovery glob is broken, which reads as a clean pass"
else
  ci_pass "$found shell scripts parsed"
fi

# -----------------------------------------------------------------------------
# `yes ... |` inside a script that sets pipefail
# -----------------------------------------------------------------------------
# When the reader exits, `yes` is killed by SIGPIPE and reports 141. With
# `set -o pipefail` that becomes the PIPELINE's status, and with `set -e` the
# calling script then aborts — AFTER the piped-to command did its work and
# printed its success messages.
#
# install.sh had exactly this: `yes y | site-secrets.sh apply` created every
# Secret, printed "secrets applied", and then killed the installer before it
# reached the Helm steps. The run ended looking like it had simply finished,
# and `echo EXIT=$?` reported 0 because the abort happened inside a subshell
# that had already produced output. It cost a full install cycle to find.
#
# Feed a non-interactive flag instead of piping into a prompt.
pipe_yes=0
while IFS= read -r f; do
  [ -f "$f" ] || continue
  grep -q 'pipefail' "$f" || continue
  # Command position only: optional indent, then `yes`, then a pipe on the
  # same line. Matching the WORD anywhere hits every comment containing "yes"
  # — including the ones explaining this very check.
  if grep -qE '^[[:space:]]*yes([[:space:]]+[^|]*)?\|' "$f"; then
    ci_fail "$(basename "$f"): pipes \`yes\` into a command while set -o pipefail is on — SIGPIPE (141) becomes the pipeline status and aborts the script after the command succeeded"
    pipe_yes=1
  fi
done < <(
  find "$REPO_ROOT/scripts" -type f -name '*.sh' 2>/dev/null
  find "$REPO_ROOT" -maxdepth 1 -type f -name '*.sh' 2>/dev/null
)
[ "$pipe_yes" -eq 0 ] && ci_pass "no \`yes |\` pipelines under pipefail"


# =============================================================================
# verify-live's fallbacks must equal the chart's defaults.
# =============================================================================
# verify-live reads every path from sites/<site>/values.yaml — nothing is
# hardcoded, which is what lets a production machine put /data somewhere else.
# But each `cfg <path> <fallback>` carries a literal fallback for the case where
# the site file omits the key, and that literal is a SECOND copy of the chart's
# default.
#
# If the chart's default moves and the fallback does not, verify-live keeps
# checking the OLD path on every site that omits the key — and reports PASS
# against a directory the deployment no longer uses. A verifier that passes
# while looking at the wrong place is worse than one that fails.
ci_heading "verify-live fallbacks match the chart defaults"

vl="$REPO_ROOT/scripts/verify-live.sh"
chart_values="$REPO_ROOT/$(ci_obs_chart)/values.yaml"
if [ ! -f "$vl" ] || [ ! -f "$chart_values" ]; then
  ci_skip "no verify-live.sh or chart values in this checkout"
else
  out="$(python3 - "$vl" "$chart_values" <<'PY'
import re, sys, yaml
src = open(sys.argv[1]).read()
vals = yaml.safe_load(open(sys.argv[2])) or {}
def get(path):
    cur = vals
    for p in path.split("."):
        cur = cur.get(p) if isinstance(cur, dict) else None
        if cur is None:
            return None
    return cur
bad, checked = [], 0
for m in re.finditer(r'cfg ([a-zA-Z][\w.]*) ([^)"\n]+)\)', src):
    path, fallback = m.group(1), m.group(2).strip()
    actual = get(path)
    if actual is None:
        # A fallback for a key the chart does not declare at all: either the
        # key was renamed or the fallback is guessing.
        bad.append(f"{path} (fallback {fallback!r} but the chart declares no such key)")
        continue
    checked += 1
    if str(actual).lower() != str(fallback).lower():
        bad.append(f"{path} (chart {actual!r} vs fallback {fallback!r})")
print(("FAIL " + "; ".join(bad)) if bad else f"PASS {checked} fallback(s) equal the chart default")
PY
)"
  case "$out" in
    PASS*) ci_pass "${out#PASS }" ;;
    *)     ci_fail "verify-live would check the wrong value on any site that omits the key: ${out#FAIL }" ;;
  esac
fi

ci_summary "shell syntax"
