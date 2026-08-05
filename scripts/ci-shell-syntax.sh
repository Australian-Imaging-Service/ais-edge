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
# shellcheck source=scripts/ci-lib.sh
. "$HERE/ci-lib.sh"

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

ci_summary "shell syntax"
