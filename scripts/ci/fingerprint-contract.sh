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
# =============================================================================
# EXTERNAL_RECLAIM_STAGE must name a stage the table actually defines
# =============================================================================
# THE SAME DRIFT, ONE LAYER OVER, and the reason this check sits beside the
# fingerprint one. The env var names the ONE stage the engine must not call
# stuck, because the staged-reclaimer CronJob owns that tree's deletes under
# upload.mode=direct. It is PRODUCED in templates/data-policy.yaml and CONSUMED
# in files/data-policy.sh, which compares it against field 1 of the stages table.
# Two files, one value, nothing checking them against each other.
#
# They silently disagreed. The template emitted "assigned"; the table row is
# "derived.assigned". So
#
#     [ "$r_name" = "$EXTERNAL_RECLAIM_STAGE" ]
#
# was never true, the delegated branch never ran, and the terminal tree was
# reported stage_stuck every pass: the exact 3am page the mechanism exists to
# prevent. Rendering looked right, the engine's own unit tests passed (they set
# the variable directly and so could not see it), and CI was green.
echo
echo "== EXTERNAL_RECLAIM_STAGE names a defined stage =="

HELM_BIN="${HELM:-helm}"
for case in "orthanc:" "ingest:charts/edge/files/deid-specs.example"; do
    name="${case%%:*}"
    extra=""
    [ "$name" = "ingest" ] && extra="--set deid.engine=ingest \
        --set ingest.assign.tagMapping.project=StudyID \
        --set ingest.assign.tagMapping.subject=PatientID \
        --set ingest.assign.tagMapping.session=AccessionNumber \
        --set dataPolicy.derived.assigned.reclaim=onDeidentified \
        --set dataPolicy.derived.deidentified.reclaim=onUploaded \
        --set-file ingest.deidentify.specs.__default__/medimage/dicom-series=charts/edge/files/deid-specs.example/__default__/medimage/dicom-series"

    # shellcheck disable=SC2086
    out="$($HELM_BIN template t charts/edge -f sites/example-single/values.yaml \
        --set deid.policyReviewed=true \
        --set dataPolicy.enabled=true --set dataPolicy.dryRun=false $extra 2>/dev/null)" || {
        echo "  SKIP       engine=$name — chart did not render" ; continue ; }

    env_val="$(printf '%s' "$out" | grep -A2 'name: EXTERNAL_RECLAIM_STAGE' \
               | grep 'value:' | head -1 | sed 's/.*value: *//; s/"//g')"
    if [ -z "$env_val" ]; then
        echo "  ok         engine=$name: no delegated stage declared"
        continue
    fi
    rows="$(printf '%s' "$out" | grep -oE '^ *(originals|derived)\.[A-Za-z]+' | tr -d ' ' | sort -u)"
    if printf '%s\n' "$rows" | grep -qx "$env_val"; then
        echo "  matches    engine=$name: $env_val is a row in stages.tsv"
    else
        echo "  DIFFERS    engine=$name: EXTERNAL_RECLAIM_STAGE=$env_val is NOT a row in stages.tsv." >&2
        echo "             The delegated branch in data-policy.sh can never match, so that tree" >&2
        echo "             is reported stage_stuck for ever. Defined: $(printf '%s' "$rows" | tr '\n' ' ')" >&2
        rc=1
    fi
done

exit $rc
