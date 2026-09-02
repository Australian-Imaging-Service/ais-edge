#!/usr/bin/env bash
# =============================================================================
# Shared-file drift
# =============================================================================
# Some files are deliberately carried in BOTH charts because Helm cannot read
# across chart directories: charts/mgmt/files/reclaim-staged.sh reclaims the S3
# staging prefix for tier-2, and charts/edge/files/reclaim-staged.sh reclaims
# the terminal stage directory for tier-1. They are the SAME script, selected at
# run time by STORAGE.
#
# That is the point, and it is also the risk. If the copies drift, the two tiers
# stop deciding "is it safe to delete this session" the same way, and the tier
# that is not being tested is the one that changes. Nothing else in CI would
# notice: each copy parses, each renders, each passes its own stage.
#
# So: byte-for-byte identical, or fail with the diff.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "$HERE/lib.sh"

ci_heading "shared files identical across charts"

# relative path under charts/<chart>/
SHARED_FILES="files/reclaim-staged.sh"

for rel in $SHARED_FILES; do
  a="$REPO_ROOT/charts/mgmt/$rel"
  b="$REPO_ROOT/charts/edge/$rel"
  if [ ! -f "$a" ]; then ci_fail "missing $a"; continue; fi
  if [ ! -f "$b" ]; then ci_fail "missing $b"; continue; fi
  if cmp -s "$a" "$b"; then
    ci_pass "$rel identical in charts/mgmt and charts/edge"
  else
    ci_fail "$rel DIFFERS between charts/mgmt and charts/edge — the two tiers would decide differently about deleting a session"
    diff -u "$a" "$b" | head -40 | sed 's/^/        /' || true
  fi
done

ci_summary "shared-files"
