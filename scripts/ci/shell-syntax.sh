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

ci_summary "shell syntax"
