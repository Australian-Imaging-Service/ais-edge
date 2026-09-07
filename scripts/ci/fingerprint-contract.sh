#!/usr/bin/env bash
# =============================================================================
# fingerprint() must be identical everywhere it is defined
# =============================================================================
# THE UPLOADER WRITES IT; THE POLICY ENGINE RECOMPUTES IT. s3-uploader.sh writes
# a fingerprint of the bytes it uploaded into the session's state file, and
# data-policy.sh recomputes it to decide whether what is on disk now is what was
# uploaded then. That comparison is what stops a re-staged session inheriting an
# older session's permission to be deleted.
#
# If the two implementations drift, every session looks changed, the condition
# is never satisfied, and NOTHING IS EVER RECLAIMED. That fails safe, but
# silently, and a permanent never-reclaim is a symptom this repo has chased
# twice -- the second time it took a live cluster to notice.
#
# The risk is not ordinary duplication. The uploader is a different program on
# each branch (rclone on main, the AWS CLI on tier-1-solution), so someone
# editing one has no reason to open the other, and the branches are meant to
# converge later.
#
# Held by a comment until this existed.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

mapfile -t files < <(grep -rl '^fingerprint()' charts --include='*.sh' | sort)
if [ ${#files[@]} -lt 2 ]; then
    echo "fingerprint-contract: found ${#files[@]} definition(s); expected at least 2 (the uploader and the policy engine) — has one been renamed?" >&2
    exit 1
fi

ref=""; rc=0
for f in "${files[@]}"; do
    body="$(sed -n '/^fingerprint()/,/^}/p' "$f")"
    if [ -z "$ref" ]; then
        ref="$body"; refname="$f"
        echo "  reference  $f"
        continue
    fi
    if [ "$body" = "$ref" ]; then
        echo "  matches    $f"
    else
        echo "  DIFFERS    $f (against $refname)" >&2
        diff <(printf '%s\n' "$ref") <(printf '%s\n' "$body") >&2 || true
        rc=1
    fi
done
exit $rc
