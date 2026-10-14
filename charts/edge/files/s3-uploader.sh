#!/usr/bin/env bash
# =============================================================================
# Edge S3 uploader — pushes assigned sessions to the central staging bucket.
# =============================================================================
# The S3 client is rclone. It replaced the AWS CLI, which had replaced
# `minio/mc`. The conventions did NOT change with it: still SigV4 access keys
# against an explicit endpoint, still one client for edge, management and any
# future cloud target. Only the binary moved.
#
# THE CLIENT AND THE USERLAND DELIBERATELY COME FROM DIFFERENT IMAGES.
# `rclone/rclone` is Alpine, so its userland is busybox, and busybox `find`
# has neither `-printf` nor `-xtype`. MEASURED in rclone/rclone:1.75.0:
# fingerprint() below returns d41d8cd98f00b204e9800998ecf8427e — the md5 of
# nothing — for EVERY session, and the dangling-symlink guard never fires.
# Both failures are silent, and both are precisely what the migration off
# busybox-based `minio/mc` fixed (docs/components/mc.md, "A full userland").
# So charts/edge/templates/upload.yaml stages the rclone BINARY out of the
# pinned rclone image with an initContainer and runs this loop in a GNU/bash
# image. rclone is a static Go binary and runs there unchanged — verified
# end to end against SeaweedFS 4.34.
#
# THE LOG SCHEMA BELOW IS A PUBLIC INTERFACE. DO NOT CHANGE IT CASUALLY.
#
# Each meaningful event is one line of JSON:
#     {"ts", "component":"s3-uploader", "edge", "event", "session", "message", ...}
#
# These four event names are matched by Loki alert rules, and changing or
# dropping any of them disables the corresponding alert SILENTLY — no error,
# just an alert that never fires again:
#
#     upload_started    SessionUploadStalled    (started with no completed)
#     upload_completed  XNATUploadFailingForAllSessions, SessionUploadStalled
#     upload_failed     XNATUploadFailingForAllSessions, S3UploaderRetryStorm
#     recopy_claimed    RecopyLoop              (the same session more than 3 times in 24h)
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

# Where upload.yaml's initContainer stages the rclone binary. PREPENDED, not
# assigned: the loop still needs the GNU coreutils/findutils on the image's own
# PATH, and prepending a directory that does not exist is harmless, so this
# script also still runs unchanged in any image that already ships rclone.
PATH="/opt/rclone:${PATH}"

ASSIGNED_DIR="${ASSIGNED_DIR:-/data/assigned}"
STATE_DIR="${STATE_DIR:-/data/LOGS/s3-uploader-state}"
# The root the stage directories live under. The marker sweep looks for the
# session under any of them rather than only this stage's.
PIPELINE_ROOT="${PIPELINE_ROOT:-/data}"
INTERVAL="${INTERVAL:-60}"
SETTLE_MINUTES="${SETTLE_MINUTES:-5}"
# THIS SCRIPT COPIES. It deletes nothing: the staged-reclaimer CronJob retires a local
# session after proving each file in the bucket (PROOF=s3), under the writer lock.
# A file that fails the proof leaves a repair request in RECOPY_DIR, and the next
# pass copies that session again (recopy_claimed / recopy_done below).
WRITER_LOCK="${WRITER_LOCK:?WRITER_LOCK required}"   # the upload-tree writer lock: held for each rclone copy
LOCK_WAIT="${LOCK_WAIT:-600}"                        # seconds to wait for it before the session is skipped this pass
RECOPY_DIR="${RECOPY_DIR:-${STATE_DIR}/recopy}"     # the reclaimer's repair requests, one file per session
S3_CHUNK_SIZE="${S3_CHUNK_SIZE:-64Mi}"               # multipart part size; the reclaimer computes the same ETag form
PASSES="${PASSES:-0}"                                # 0: loop for ever; N: stop after N passes (tests)

: "${S3_BUCKET:?S3_BUCKET required}"
: "${EDGE_NAME:?EDGE_NAME required}"
S3_PREFIX="${S3_PREFIX:-staged}"

mkdir -p "$STATE_DIR"

jlog() {
    # $1=event  $2=session  $3=message  $4=extra JSON (leading comma)
    printf '{"ts":"%s","component":"s3-uploader","edge":"%s","event":"%s","session":"%s","message":"%s"%s}\n' \
        "$(date -Iseconds)" "${EDGE_NAME}" "$1" "${2:-}" "${3:-}" "${4:-}"
}

# Client-certificate state, worked out ONCE and reported in two places.
#
# RCLONE_CLIENT_CERT / RCLONE_CLIENT_KEY are rclone's --client-cert /
# --client-key; upload.yaml sets them only when upload.s3.requireClientCert is
# on. They are INDEPENDENT of RCLONE_CA_CERT, which is server trust: on cloud
# the SeaweedFS server certificate can come from a public CA (no CA bundle
# needed) while our own identity still comes from the fleet CA via cert-sync.
#
# This is diagnostic text only — nothing branches on it. The uploader stays
# topology-independent and mTLS-agnostic: rclone either has an identity to
# present or it does not.
#
# WHY IT IS WORTH THE LINES. MEASURED against nginx with
# `ssl_verify_client on` (what the auth-tls-* annotations render to) and
# rclone 1.75.0:
#
#   no certificate sent      the TLS handshake SUCCEEDS — under TLS 1.3 the
#                            client certificate goes after the server's
#                            Finished, so nginx cannot refuse the connection
#                            and refuses the REQUEST instead: HTTP 400
#                            "No required SSL certificate was sent", an HTML
#                            body. rclone tries to parse it as an S3 error and
#                            reports `error while deserializing xml error
#                            response : XML syntax error ... element <hr>`.
#   wrong CA                 identical HTTP 400, identical XML noise.
#   CN outside match-cn      HTTP 403, identical XML noise.
#   cert file missing        the one loud case: rclone exits with
#                            `CRITICAL: Failed to load --client-cert/--client-key pair`.
#
# So three of the four mTLS failures reach an operator as a malformed-S3-
# response error naming neither certificates nor authentication, on a probe
# whose event name is `endpoint_failed`. Without this text the obvious reading
# is a broken endpoint, and the actual cause is never mentioned anywhere.
if [ -n "${RCLONE_CLIENT_CERT:-}" ]; then
    mtls_state="on cert=${RCLONE_CLIENT_CERT}"
    # No quotes, no newlines: this string is interpolated into the JSON below.
    if [ -r "${RCLONE_CLIENT_CERT}" ] && [ -r "${RCLONE_CLIENT_KEY:-}" ]; then
        mtls_hint="a client certificate IS configured and readable, so suspect the certificate itself — expired, signed by a CA the endpoint does not verify against (arrives as HTTP 400), or a CN the endpoint does not accept (HTTP 403). Both reach rclone as an S3 XML parse failure, never as an auth error"
    else
        mtls_hint="a client certificate is configured at ${RCLONE_CLIENT_CERT} but it or its key is MISSING OR UNREADABLE — rclone reports CRITICAL: Failed to load --client-cert/--client-key pair on stderr. Check the s3-client-tls Secret that cert-sync delivers"
    fi
else
    mtls_state="off"
    mtls_hint="no client certificate is configured (RCLONE_CLIENT_CERT unset). If the endpoint now requires one, the handshake still SUCCEEDS and the endpoint answers HTTP 400 No required SSL certificate was sent, whose HTML body rclone reports as an S3 XML parse failure — which is exactly what the errors above would look like"
fi

mkdir -p "$RECOPY_DIR"
# A request claimed by a run that died: back to pending, so it is served again.
for f in "$RECOPY_DIR"/*.claimed; do
    [ -f "$f" ] || continue
    [ -f "${f%.claimed}" ] && rm -f "$f" || mv -f "$f" "${f%.claimed}"
    jlog recopy_requeued "$(basename "${f%.claimed}")" "a repair request claimed by an earlier run goes back to pending"
done
jlog startup "" "s3-uploader starting endpoint=${RCLONE_CONFIG_SW_ENDPOINT:-<unset>} bucket=${S3_BUCKET} prefix=${S3_PREFIX} chunk=${S3_CHUNK_SIZE} client_cert=${mtls_state}; copies only, the staged-reclaimer deletes"

# -----------------------------------------------------------------------------
# Pre-flight. Refuse to enter the upload loop against an endpoint we cannot
# reach, so a broken endpoint crashloops the pod visibly instead of quietly
# doing nothing.
#
# The mc version needed this guard for a sharper reason: mc treated an
# unresolved alias as a LOCAL path, so a failed `alias set` made `mc mirror`
# copy into ./edge/<bucket>/... , exit 0, and the script then deleted the
# staged data having uploaded nothing. Neither the AWS CLI nor rclone has that
# failure mode — measured with every RCLONE_CONFIG_SW_* unset, `sw:` is
# "CRITICAL: ... didn't find section in config file", exit 1, nothing written
# locally. But failing fast is still right, and DNS or pod-startup races
# deserve a few retries rather than an instant crashloop.
#
# `rclone lsd sw:<bucket>` AND NOT `rclone about sw:`. MEASURED against
# SeaweedFS 4.34: `about` answers "S3 root doesn't support about" and exits 1
# no matter how healthy the endpoint is — `about` is optional in the S3 API
# and SeaweedFS does not implement it — so a probe built on it would fail all
# 12 attempts and crashloop the pod against a working bucket. `lsd` on the
# bucket asserts exactly what this probe is for, which is also exactly what
# `aws s3api head-bucket` asserted: the endpoint answers, AND this site's
# credential can see THIS site's bucket. Measured: exit 0 on the site's own
# bucket, exit 1 with AccessDenied on a bucket its identity is not scoped to.
#
# --log-level ERROR because rclone otherwise opens every invocation with
# NOTICE "Config file ... not found - using defaults" — true, expected (the
# remote comes entirely from RCLONE_CONFIG_SW_* env), and pure noise in a
# diagnostic. Errors still reach $err.
# -----------------------------------------------------------------------------
probe_endpoint() {
    local err
    err=$(rclone lsd "sw:${S3_BUCKET}" --log-level ERROR 2>&1) || {
        echo "lsd sw:${S3_BUCKET}: ${err}" >&2
        return 1
    }
}

attempt=0
until probe_endpoint; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 12 ]; then
        # "refusing to start upload loop" IS MATCHED BY A LOKI RULE.
        # charts/mgmt/files/loki-ruler-rules.yaml selects
        # `refusing to start upload loop|alias_failed|endpoint_failed` for
        # S3UploaderRestartedRecently, so that phrase is as contractual as the
        # event name. Extend this message; do not reword that clause.
        #
        # THE CLIENT-CERTIFICATE HINT IS THE POINT OF THE REST OF IT. With mTLS
        # on the endpoint this probe is the FIRST thing a bad or missing client
        # certificate breaks, and — measured, see the block above — it breaks as
        # an S3 XML parse failure on a 400 or 403, which names neither
        # certificates nor authentication. Without this text an operator reading
        # these logs has nothing pointing at certificates at all. The rclone
        # error itself goes to stderr from probe_endpoint; it can contain quotes
        # and newlines, so it must not be interpolated into this JSON.
        jlog endpoint_failed "" "bucket probe failed after 12 attempts (60s) — refusing to start upload loop. Endpoint mTLS: ${mtls_hint}. The rclone error for each attempt is on stderr above; an mTLS refusal arrives there as a 400/403 with an unparseable XML body, not as an auth error"
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
        # A repair request (the reclaimer found an object missing or different):
        # claimed by a rename, so a request written during this copy keeps the
        # plain name and is served next pass. Copied with --ignore-times, so every
        # file goes again whatever the modification times say.
        request="${RECOPY_DIR}/${session_name}"; recopy=""
        if [ -f "$request" ] && mv -f "$request" "${request}.claimed" 2>/dev/null; then
            recopy="--ignore-times"
            jlog recopy_claimed "$session_name" "$(head -c 200 "${request}.claimed" | tr -d '\n')"
        elif [ -f "$state_file" ] && [ "$(cat "$state_file")" = "$fp" ]; then
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
        if ! rclone lsd "sw:${S3_BUCKET}" --log-level ERROR >/dev/null 2>&1; then
            jlog upload_skipped "$session_name" "endpoint probe failed — preserving local copy for next retry"
            [ -n "$recopy" ] && mv -f "${request}.claimed" "$request" 2>/dev/null
            continue
        fi

        # Uploading is never gated by dataPolicy: it is the pipeline's whole job.
        # (It used to be, and a dryRun meant to preview reclaim decisions stopped
        # the edge shipping to S3.) What dataPolicy governs is the local copy,
        # and that is the staged-reclaimer's, not this script's.

        # `rclone copy`, NEVER `rclone sync`. This is the one line where the
        # port from `aws s3 sync` is not a rename: `aws s3 sync` never deletes
        # at the destination, `rclone sync` deletes there BY DEFAULT. The
        # destination is the staging bucket holding DICOM that XNAT has not
        # confirmed yet, and s3Staged.reclaim=onXnatConfirmed removes objects
        # from it on its own schedule — so a session re-uploaded here while the
        # reclaimer is mid-reconcile would take the reclaimer's objects with
        # it. Measured against SeaweedFS 4.34 with an unrelated object sitting
        # under the same prefix: `copy` left it, `sync` deleted it.
        #
        # --copy-links IS LOAD-BEARING, not tuning. Assigned sessions are
        # symlink/hardlink trees into orthanc-storage (see fingerprint()'s
        # `find -L`). `aws s3 sync` followed symlinks by default; rclone SKIPS
        # them by default and still exits 0. Measured on a 4-file session with
        # 2 symlinked DICOMs: without this flag rclone uploaded 2 objects,
        # exited 0, and --log-level ERROR suppressed the warning — so the run
        # would emit upload_completed with the full bytes/files/dicoms counts
        # (they come from `find -L`, which does follow) and write the state file,
        # while the bucket held 2 of 4 files. The reclaimer's proof would then
        # keep the 2 unproved files, but the session would never be delivered
        # whole: the flag is what makes the copy complete. With it: 4 objects.
        #
        # A dangling link under --copy-links is a hard error (exit 6, measured),
        # which lands in the else branch — no state file, no reclaim.
        #
        # UNDER THE WRITER LOCK for the whole copy: the writer stage and the
        # staged-reclaimer take the same lock, so a session is never copied while
        # it is being written or deleted, and every PUT and multipart completion
        # of this copy is finished before a delete can start.
        #
        # The multipart flags are the contract with the reclaimer's proof: a part
        # size it knows (S3_CHUNK_SIZE, or rclone's 5 MiB default when rclone
        # raises it above --s3-max-upload-parts), and the multipart ETag kept.
        if ! exec 8>>"$WRITER_LOCK" || ! flock -w "$LOCK_WAIT" 8; then
            jlog upload_skipped "$session_name" "the upload-tree writer lock was not free within ${LOCK_WAIT}s; next pass"
            [ -n "$recopy" ] && mv -f "${request}.claimed" "$request" 2>/dev/null
            exec 8>&-
            continue
        fi
        if rclone copy "$session_dir" "sw:${S3_BUCKET}/${S3_PREFIX}/${session_name}/" \
             --copy-links --transfers 4 --checkers 8 --retries 3 --log-level ERROR \
             --s3-chunk-size "$S3_CHUNK_SIZE" --s3-max-upload-parts 10000 --s3-use-multipart-etag=true $recopy; then
            exec 8>&-
            duration=$(( $(date +%s) - start_ts ))
            jlog upload_completed "$session_name" "" \
                ",\"bytes\":${bytes},\"files\":${files},\"dicoms\":${dicoms},\"duration_s\":${duration}"
            echo "$fp" > "$state_file"
            if [ -n "$recopy" ]; then
                rm -f "${request}.claimed"
                jlog recopy_done "$session_name" "copied again on the reclaimer's request" ",\"duration_s\":${duration}"
            fi
        else
            exec 8>&-
            duration=$(( $(date +%s) - start_ts ))
            jlog upload_failed "$session_name" "rclone copy non-zero exit; will retry next cycle" \
                ",\"bytes\":${bytes},\"files\":${files},\"dicoms\":${dicoms},\"duration_s\":${duration}"
            # the request goes back to pending, unless a newer one arrived meanwhile
            [ -n "$recopy" ] && { [ -f "$request" ] && rm -f "${request}.claimed" || mv -f "${request}.claimed" "$request"; }
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

    if [ "$PASSES" -gt 0 ]; then
        PASSES=$((PASSES - 1)); [ "$PASSES" -eq 0 ] && exit 0
    fi
    sleep "$INTERVAL"
done
