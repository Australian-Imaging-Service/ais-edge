#!/usr/bin/env bash
# =============================================================================
# Edge S3 uploader — pushes assigned sessions to the central staging bucket.
# =============================================================================
# Replaces the previous `minio/mc` implementation. The S3 client is now the
# AWS CLI so that every site — edge, management and any future cloud target —
# speaks the same client with the same credential and endpoint conventions.
#
# THE LOG SCHEMA BELOW IS A PUBLIC INTERFACE. DO NOT CHANGE IT CASUALLY.
#
# Each meaningful event is one line of JSON:
#     {"ts", "component":"s3-uploader", "edge", "event", "session", "message", ...}
#
# These three event names are matched by Loki alert rules, and changing or
# dropping any of them disables the corresponding alert SILENTLY — no error,
# just an alert that never fires again:
#
#     upload_started    EdgeUploadStalled       (started with no completed)
#     upload_completed  EdgeUploadsFailing, EdgeUploadStalled, S3ToXNATBacklog
#     upload_failed     EdgeUploadsFailing, EdgeUploadRetrying
#
# The numeric fields (bytes, files, dicoms, duration_s) feed the dashboards.
# `files` counts every object uploaded (DICOMs + __MANIFEST__.json + __METADATA__.json);
# `dicoms` counts only the image files. Both are reported so a panel author
# can pick the right one.
#
# Renamed from the mc implementation: alias_configured / alias_retrying /
# alias_failed are now endpoint_ready / endpoint_retrying / endpoint_failed,
# because "alias" was an mc concept that no longer exists. No alert rule or
# dashboard matched those names (checked); they are operator diagnostics.
# =============================================================================
set -uo pipefail

ASSIGNED_DIR="${ASSIGNED_DIR:-/data/assigned}"
STATE_DIR="${STATE_DIR:-/data/LOGS/s3-uploader-state}"
# The root the stage directories live under. The marker sweep looks for the
# session under any of them rather than only this stage's.
PIPELINE_ROOT="${PIPELINE_ROOT:-/data}"
INTERVAL="${INTERVAL:-60}"
SETTLE_MINUTES="${SETTLE_MINUTES:-5}"
# onUploaded -> remove the local copy after a verified upload.
# never      -> keep it; the fingerprint state file stops re-uploading.
RECLAIM="${RECLAIM:-onUploaded}"
DRY_RUN="${DRY_RUN:-false}"

: "${S3_BUCKET:?S3_BUCKET required}"
: "${EDGE_NAME:?EDGE_NAME required}"
S3_PREFIX="${S3_PREFIX:-staged}"

mkdir -p "$STATE_DIR"

jlog() {
    # $1=event  $2=session  $3=message  $4=extra JSON (leading comma)
    printf '{"ts":"%s","component":"s3-uploader","edge":"%s","event":"%s","session":"%s","message":"%s"%s}\n' \
        "$(date -Iseconds)" "${EDGE_NAME}" "$1" "${2:-}" "${3:-}" "${4:-}"
}

jlog startup "" "s3-uploader starting endpoint=${AWS_ENDPOINT_URL:-<unset>} bucket=${S3_BUCKET} prefix=${S3_PREFIX} reclaim=${RECLAIM}"

# -----------------------------------------------------------------------------
# Pre-flight. Refuse to enter the upload loop against an endpoint we cannot
# reach, so a broken endpoint crashloops the pod visibly instead of quietly
# doing nothing.
#
# The mc version needed this guard for a sharper reason: mc treated an
# unresolved alias as a LOCAL path, so a failed `alias set` made `mc mirror`
# copy into ./edge/<bucket>/... , exit 0, and the script then deleted the
# staged data having uploaded nothing. The AWS CLI has no such failure mode —
# a bad endpoint is a hard error — but failing fast is still right, and DNS
# or pod-startup races deserve a few retries rather than an instant crashloop.
# -----------------------------------------------------------------------------
probe_endpoint() {
    local err
    err=$(aws s3api head-bucket --bucket "$S3_BUCKET" 2>&1) || {
        echo "head-bucket ${S3_BUCKET}: ${err}" >&2
        return 1
    }
}

attempt=0
until probe_endpoint; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 12 ]; then
        jlog endpoint_failed "" "bucket probe failed after 12 attempts (60s) — refusing to start upload loop"
        sleep 15
        exit 1
    fi
    jlog endpoint_retrying "" "attempt ${attempt}/12 — endpoint not ready, retrying in 5s"
    sleep 5
done
jlog endpoint_ready "" "bucket probe OK"

# Content fingerprint, resolved THROUGH symlinks (-L): assigned sessions are
# hardlink/symlink trees, and we care about the bytes that would be uploaded,
# not the link metadata.
fingerprint() {
    # NO `find -printf` HERE, AND THAT IS NOT A STYLE CHOICE. The data-policy
    # engine runs on curlimages/curl, which is Alpine: BusyBox find has no
    # -printf and fails with "unrecognized: -printf". With the error swallowed
    # by 2>/dev/null that produced the md5 of an EMPTY string, identical every
    # time and never equal to the uploader's value -- so onUploaded could never
    # be satisfied on any real deployment and nothing would ever be reclaimed,
    # silently. Caught by tests/data-policy, which is the only stage that runs
    # this script in the image it actually ships in.
    #
    # `cd` first so %n is relative: the uploader and the engine must agree on
    # the value, and they do not necessarily see the tree at the same path.
    # %Y rather than %T@ because BusyBox stat has no fractional seconds.
    ( cd "$1" 2>/dev/null && find -L . -type f -exec stat -c '%n %s %Y' {} + 2>/dev/null \
        | sort | md5sum | cut -d' ' -f1 )
}

while true; do
    for session_dir in "$ASSIGNED_DIR"/*/; do
        [ -d "$session_dir" ] || continue
        session_name=$(basename "$session_dir")

        # Internal directories created by xnat-ingest, not sessions.
        case "$session_name" in
            __build__|__invalid__|__metadata__|'*') continue ;;
        esac

        # Settle guard: assign may still be writing into this session.
        if find "$session_dir" -mmin -"$SETTLE_MINUTES" -print -quit 2>/dev/null | grep -q .; then
            continue
        fi

        # Never upload a session whose link targets have gone. Uploading a
        # tree of dangling links would produce a session in XNAT that is
        # missing files, which is worse than not uploading it at all.
        if find "$session_dir" -xtype l -print -quit 2>/dev/null | grep -q .; then
            jlog upload_skipped "$session_name" "dangling symlinks — source removed before upload; leaving in place"
            continue
        fi

        fp=$(fingerprint "$session_dir")
        state_file="${STATE_DIR}/${session_name}"
        if [ -f "$state_file" ] && [ "$(cat "$state_file")" = "$fp" ]; then
            # Already uploaded and unchanged. Emit NOTHING — a per-cycle event
            # here is exactly what produced two days of duplicate
            # "upload completed" alert mail.
            continue
        fi

        bytes=$(du -sb "$session_dir" 2>/dev/null | cut -f1)
        bytes=${bytes:-0}
        files=$(find -L "$session_dir" -type f 2>/dev/null | wc -l)
        dicoms=$(find -L "$session_dir" -type f \( -iname '*.dcm' \) 2>/dev/null | wc -l)

        jlog upload_started "$session_name" "" ",\"bytes\":${bytes},\"files\":${files},\"dicoms\":${dicoms}"
        start_ts=$(date +%s)

        # Re-probe immediately before the transfer. If the endpoint went away
        # mid-loop this skips the session — and, critically, skips the reclaim
        # below — so the local copy survives for the next attempt.
        if ! aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
            jlog upload_skipped "$session_name" "endpoint probe failed — preserving local copy for next retry"
            continue
        fi

        # NOTE: DRY_RUN does NOT gate the upload.
        #
        # It used to. That was wrong in a way that only shows up when someone
        # does the careful thing: dataPolicy is about what is KEPT and what is
        # RECLAIMED, and uploading is neither — it is the pipeline's whole job.
        # With the upload behind this flag, setting
        #     dataPolicy: {enabled: true, dryRun: true}
        # to preview reclaim decisions stopped the edge shipping to S3
        # altogether. Turning on the safety mode silently halted delivery.
        # Only the reclaim below is a data-policy action, so only the reclaim
        # is gated.
        if aws s3 sync "$session_dir" "s3://${S3_BUCKET}/${S3_PREFIX}/${session_name}/" --only-show-errors; then
            duration=$(( $(date +%s) - start_ts ))
            jlog upload_completed "$session_name" "" \
                ",\"bytes\":${bytes},\"files\":${files},\"dicoms\":${dicoms},\"duration_s\":${duration}"
            echo "$fp" > "$state_file"

            # dataPolicy.derived.assigned.reclaim. Only ever reached after a
            # zero-exit sync. The bytes also exist in Orthanc storage and the
            # facility backup, both governed by the `originals` rules.
            if [ "$RECLAIM" = "onUploaded" ]; then
                if [ "$DRY_RUN" = "true" ]; then
                    jlog reclaim_skipped "$session_name" "dataPolicy dryRun/disabled — uploaded, but leaving the local copy in place"
                else
                    rm -rf "$session_dir"
                fi
            fi
        else
            duration=$(( $(date +%s) - start_ts ))
            jlog upload_failed "$session_name" "aws s3 sync non-zero exit; will retry next cycle" \
                ",\"bytes\":${bytes},\"files\":${files},\"dicoms\":${dicoms},\"duration_s\":${duration}"
        fi
    done

    # Drop state only when NOTHING IN THE PIPELINE CAN STILL ASK ABOUT IT.
    #
    # The marker is the only evidence that a session was uploaded, and
    # data-policy reads it to decide whether a local copy may be reclaimed.
    # Sweeping it as soon as THIS stage's directory was gone meant that when the
    # uploader did its own reclaim, the marker was written and removed in the
    # same pass: data-policy would look, find nothing, and log "condition
    # onUploaded not satisfied" for ever.
    #
    # NO TIMER, DELIBERATELY. A retention window has to be longer than the
    # slowest session, and the slowest session is not knowable: a large study on
    # a slow link can outlive any constant, and the marker would then expire
    # before the engine acted -- the same failure, reached later and harder to
    # diagnose. So the question asked here is not "how old is this marker" but
    # "does any stage still hold a session by this name". While one does, the
    # marker is still load-bearing. When none does, no consumer can ask about it
    # again, and a session re-staged later under the same name gets a fresh
    # marker rather than inheriting this one's authority.
    #
    # Depth 2 is <pipeline-root>/<stage>/<session>, which is every stage
    # directory without needing to know their names.
    for state_file in "$STATE_DIR"/*; do
        [ -f "$state_file" ] || continue
        sname=$(basename "$state_file")
        if find "$PIPELINE_ROOT" -mindepth 2 -maxdepth 2 -type d -name "$sname" \
                -print -quit 2>/dev/null | grep -q .; then
            continue
        fi
        rm -f "$state_file"
        jlog marker_retired "$sname" "upload marker dropped: no stage directory holds this session any more, so nothing can ask about it again"
    done

    sleep "$INTERVAL"
done
