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
# There is exactly ONE source of configuration, and it is the site file.
# =============================================================================
# config/management.env and config/edge-nodes.env were a second one. `source`
# assigns unconditionally, so a stale copy left over from before the Helm
# consolidation silently overwrote the values install.sh had just exported from
# sites/<site>/values.yaml, and the install steps then acted on a different node
# IP, hostname or edge than the charts were rendered with. Nothing failed; the
# wrong thing was configured.
#
# Guarding each call site was not enough — 05, 06, 06b and 06c each grew an
# `if AIS_CONFIG_FROM_SITE ... else` pair for exactly this, and the second
# source still existed for anyone who ran a script directly. So the files are
# gone, and this keeps them gone.
ci_heading "one source of configuration"

cfg_bad=0
while IFS= read -r f; do
  [ -e "$f" ] || continue
  # `source`/`.` of anything under config/ — the mechanism itself.
  if grep -nE '^[[:space:]]*(source|\.)[[:space:]]+.*config/[A-Za-z0-9_.-]+\.env' "$f" >/dev/null; then
    ci_fail "$(basename "$f") sources a config/*.env file — that is a second source of truth that can silently override sites/<site>/values.yaml"
    cfg_bad=1
  fi
done < <(
  find "$REPO_ROOT/scripts" -type f -name '*.sh' 2>/dev/null
  find "$REPO_ROOT" -maxdepth 1 -type f -name '*.sh' 2>/dev/null
)

# And the files themselves must not come back.
for dead in config/management.env.template config/edge-nodes.env.template config/orthanc; do
  if [ -e "$REPO_ROOT/$dead" ]; then
    ci_fail "$dead is back. Configuration belongs in sites/<site>/values.yaml and sites/<site>/secrets.enc.yaml; config/ holds only k0s-controller.yaml, which install.sh copies to /etc/k0s/k0s.yaml"
    cfg_bad=1
  fi
done

[ "$cfg_bad" -eq 0 ] && ci_pass "config/ holds only k0s-controller.yaml, and no script sources a config/*.env"


# =============================================================================
# k0s is never installed unpinned.
# =============================================================================
# A worker whose k0s MINOR differs from its control plane bootstraps fine, has
# its CSR approved, then asks for `worker-config-default-<its minor>` — a
# ConfigMap the older control plane never created, and whose RBAC does not cover
# it. The Node authorizer denies it, k0s exits 1, systemd restarts it forever,
# and the node never appears, so the installer just waits with nothing to show.
#
# It is a LATENT bug that activates on upstream's release schedule, not on any
# change here: the charts pinned v1.35.2 months ago, `get.k0s.sh` started
# serving 1.36, and the same unchanged script produced a broken node. Hit on
# cai-lfs3.
#
# So: every k0s install must name a version. One deliberate fallback is marked
# `# UNPINNED-OK` with its reasoning; anything else is a regression.
ci_heading "k0s is never installed unpinned"

k0s_bad=0
while IFS= read -r f; do
  [ -e "$f" ] || continue
  # Lines that actually RUN the installer, not comments about it.
  while IFS=: read -r n line; do
    case "$line" in
      *K0S_VERSION*) continue ;;
    esac
    prev="$(sed -n "$((n>4?n-4:1)),$((n-1))p" "$f" 2>/dev/null)"
    case "$prev" in
      *UNPINNED-OK*) continue ;;
    esac
    ci_fail "$(basename "$f"):$n installs k0s without a version. A worker one minor from its control plane crash-loops on a worker-config ConfigMap that does not exist, and the node never appears."
    k0s_bad=1
  done < <(grep -nE '^[^#]*curl[^#]*get\.k0s\.sh[^#]*\|' "$f" 2>/dev/null)
done < <(
  find "$REPO_ROOT/scripts" -type f -name '*.sh' 2>/dev/null
  find "$REPO_ROOT" -maxdepth 1 -type f -name '*.sh' 2>/dev/null
)
[ "$k0s_bad" -eq 0 ] && ci_pass "every k0s install names a version (or is marked UNPINNED-OK with a reason)"

ci_summary "shell syntax"
