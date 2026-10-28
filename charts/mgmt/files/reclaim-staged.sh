#!/usr/bin/env bash
# =============================================================================
# S3 staging reclaimer — the ONLY component that deletes from s3://<bucket>/staged
# =============================================================================
# GUIDING: xnat-ingest upload has no S3 retention of its own — it relists the
# staging prefix every loop and never removes what it sent, so a delivered
# session gets re-uploaded and re-alerted forever without this job. Full
# design write-up: docs/TOUR.md, docs/components/seaweedfs.md.
#
# -----------------------------------------------------------------------------
# THE DOCTRINE: THIS SCRIPT DELETES PATIENT DATA. IT IS WRONG TO GUESS.
# -----------------------------------------------------------------------------
# A staged session not confirmed in XNAT is UNDELIVERED DATA. Every
# uncertainty — failed listing, non-200, unparseable response, malformed
# session ID, missing tool — resolves to KEEP. No code path here deletes
# because something could not be checked.
#
#   * CAUTION: an uploader exit code, or the experiment merely EXISTING in
#     XNAT, is NOT confirmation. XNAT creates the experiment on the first
#     resource POST, so a 3-of-400-scans upload leaves a correctly-labelled
#     but empty experiment. Confirmation means COUNTING every file the
#     staged __MANIFEST__.json says it contains against XNAT.
#   * CAUTION: an object is deleted one by one, with If-Match set to the ETag
#     this run listed before the proof, so a rewritten object stays (412).
#     Folders are NEVER deleted: a filer folder delete can drop a child
#     written after its check, and the uploader's listing skips empty
#     folders. See docs/components/seaweedfs.md, "Deleting staged objects".
#   * CAUTION: never decide from `weed shell` TEXT — its inline prompt
#     ("> FIRST_ENTRY") once made a session that held data look empty.
#     Every decision here comes from the S3 API or from XNAT.
#
# -----------------------------------------------------------------------------
# THE LOG SCHEMA BELOW IS A PUBLIC INTERFACE. DO NOT CHANGE IT CASUALLY.
# -----------------------------------------------------------------------------
# One line of JSON per meaningful event, same shape as the edge s3-uploader
# (charts/edge/files/s3-uploader.sh) so both ends of the pipeline parse
# identically in Loki:
#     {"ts", "component":"s3-reclaimer", "cluster", "event", "session", "message", ...}
# The identity field is `cluster` rather than the uploader's `edge`: this runs
# on the management plane, which is not an edge. The Loki ruler selects streams
# by the POD labels (namespace / component / cluster / app), not by this field.
#
#     reclaim_skipped    not eligible yet (too young), or dry-run
#     reclaim_confirmed  XNAT positively reported holding this session
#     reclaim_removed    every object (or file) of this session was deleted
#     reclaim_kept       deliberately NOT removed — undelivered, or uncertain
#     reclaim_failed     reclaim-files.py stopped with an exit code it does not define
#     recopy_requested   PROOF=s3: a local file is not in the bucket as it is here;
#                        the uploader is asked to copy the session again
#     reclaim_unavailable  pre-flight failed; nothing was DECIDED. Emitted once
#                        with session="" for the run, then once per staged
#                        session — see the pre-flight note below for why the
#                        per-session copies are not redundant.
#     reclaim_finished   the run walked staging to the end. NEVER emitted by an
#                        aborted run: "could not decide" and "decided there was
#                        nothing to do" must not look alike in the log.
# =============================================================================
set -uo pipefail

# Run the data worker as a tracked child. TERM must reach it even when this
# shell is PID 1. Its Python handler runs finally blocks, then the shell's
# EXIT trap closes the borrowed XNAT login. No new session starts after a stop.
RECLAIM_PID=""
stop_reclaim() {
    local sig="$1" status="$2"
    trap '' TERM INT
    if [ -n "$RECLAIM_PID" ]; then
        kill -s "$sig" "$RECLAIM_PID" 2>/dev/null || true
        wait "$RECLAIM_PID" 2>/dev/null || true
    fi
    exit "$status"
}
trap 'stop_reclaim TERM 143' TERM
trap 'stop_reclaim INT 130' INT
run_files_helper() {
    python3 "$FILES_HELPER" "$@" &
    RECLAIM_PID=$!
    local rc=0
    wait "$RECLAIM_PID" || rc=$?
    RECLAIM_PID=""
    return "$rc"
}

# --- required -----------------------------------------------------------------
# STORAGE is read HERE, before anything else, because it decides which of the
# variables below are required at all. Reading it further down (where the rest of
# the configuration is resolved) made the filesystem backend impossible to start:
# the script died on a missing S3_BUCKET before it ever learned it was not going
# to talk to S3. Its value is VALIDATED further down, next to the backend it
# selects; this is only the read.
STORAGE="${STORAGE:-s3}"

: "${CLUSTER_LABEL:?CLUSTER_LABEL required}"
if [ "$STORAGE" = "s3" ]; then
    : "${S3_BUCKET:?S3_BUCKET required}"
    # Base URL of the SeaweedFS FILER HTTP API (port 8888), e.g.
    #   http://mgmt-seaweedfs.seaweedfs.svc.cluster.local:8888
    # Read only: the pre-flight gate reads the bucket's attributes from it
    # (the empty-folder cleaner opted out, and the activation attested).
    : "${FILER_ENDPOINT:?FILER_ENDPOINT required}"
else
    # The filesystem backend removes directories with rm -r on a mounted volume,
    # so it needs neither a bucket nor the filer. STAGED_ROOT takes their place
    # and is checked, including for paths too broad to delete within, in the
    # pre-flight below.
    : "${STAGED_ROOT:?STAGED_ROOT required when STORAGE=filesystem}"
fi

S3_PREFIX="${S3_PREFIX:-staged}"
# The filesystem backend's decision and delete (see "FILESYSTEM BACKEND" below).
FILES_HELPER="${FILES_HELPER:-$(dirname "$0")/reclaim-files.py}"

# dataPolicy.derived.s3Staged.reclaim. `never` should never reach this script
# (the template renders nothing at all in that case); the check is defence in
# depth against a CronJob left behind by a partial upgrade.
RECLAIM="${RECLAIM:-never}"
MIN_AGE="${MIN_AGE:-1d}"
VERIFY_XNAT="${VERIFY_XNAT:-true}"
DRY_RUN="${DRY_RUN:-true}"
XNAT_VERIFY_SSL="${XNAT_VERIFY_SSL:-true}"

# Blast radius cap. A bug that decided "delete everything" is bounded to this
# many sessions per run, leaving the rest for an operator to notice first. At
# the hourly default schedule this still drains ~1200 sessions/day.
MAX_REMOVALS="${MAX_REMOVALS:-50}"
# Nothing here is quick-and-cheap; every external call gets a hard deadline so
# a hung filer or a hung XNAT cannot pin the job open until the next one is due.
HTTP_TIMEOUT="${HTTP_TIMEOUT:-30}"
EXEC_TIMEOUT="${EXEC_TIMEOUT:-120}"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
# Strip everything that would break the one-JSON-object-per-line contract.
# A raw `weed shell` or curl error goes into `message`, and those can contain
# quotes, backslashes and newlines; an unescaped one turns the line into
# garbage that Loki's `| json` stage drops silently — taking the alert with it.
jsan() {
    printf '%s' "${1:-}" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-400
}

jlog() {
    # $1=event  $2=session  $3=message  $4=extra JSON (leading comma)
    printf '{"ts":"%s","component":"s3-reclaimer","cluster":"%s","event":"%s","session":"%s","message":"%s"%s}\n' \
        "$(date -Iseconds)" "${CLUSTER_LABEL}" "$1" "$(jsan "${2:-}")" "$(jsan "${3:-}")" "${4:-}"
}

# `reclaim_kept` is the fail-safe outcome and carries a machine-readable reason
# so a dashboard can separate "not in XNAT yet" (expected, transient) from
# "we could not tell" (an operator has to look).
# $1=session $2=reason $3=message $4=extra JSON (leading comma, optional)
keep() { jlog reclaim_kept "$1" "$3" ",\"reason\":\"$2\"${4:-}"; }

fs_list_prefixes() {
    [ -d "$STAGED_ROOT" ] || return 1
    # -mindepth/-maxdepth 1: sessions are the immediate children, and a name
    # beginning with __ is a build or invalid tree that no stage owns.
    find "$STAGED_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
        | grep -v '^__' || true
    return 0
}

# EVERY listing goes through here, including the two outside the main pass: the
# per-session copies in unavailable(), and the post-removal verification at the
# end. Both called s3_list_prefixes directly and it took an armed run on a real
# tier-1 box to show it: the removal itself succeeded, then verification died on
# `S3_BUCKET: unbound variable` and reported reclaim_failed for a session that
# had in fact been removed correctly. A false failure on the delete path is worse
# than a real one, because it sends someone looking for data that is gone on
# purpose.
st_list_prefixes()  { case "$STORAGE" in filesystem) fs_list_prefixes ;;  *) python3 "$FILES_HELPER" --list ;; esac; }

# -----------------------------------------------------------------------------
# Aborting the run: emits run-level AND per-session reclaim_unavailable, never
# reclaim_finished. WHY: docs/alerting-architecture.md, "The reclaimer's
# pre-flight abort".
# CAUTION: this is not redundant with the run-level line — an isolated
# pre-flight failure is absorbed by SessionStagedNotConfirmedInXNAT's 24h
# window, but a SUSTAINED one would leave every session staged in that window
# invisible to it without the per-session fan-out.
# -----------------------------------------------------------------------------

# Cap on the per-session fan-out. A pre-flight that fails every hour against a
# large staging prefix would otherwise push tens of thousands of lines a day at
# Loki, and a stream that trips an ingestion limit is DROPPED — restoring the
# silence this exists to prevent. Truncation is reported rather than implied.
# Env-overridable but not a chart value: nothing in the chart should need it.
UNAVAILABLE_SESSION_CAP="${UNAVAILABLE_SESSION_CAP:-500}"

# $1=reason slug (machine-readable, stable)  $2=operator-facing message
unavailable() {
    local slug="$1" msg="$2" listed session n=0
    jlog reclaim_unavailable "" "$msg" ",\"reason\":\"${slug}\""

    if listed=$(st_list_prefixes 2>/dev/null); then
        while IFS= read -r session; do
            [ -n "$session" ] || continue
            # Our own state prefix is not a session. The main pass matches the
            # literal `.reclaim-state` only (its charset guard catches any
            # other dot-prefix and logs a reclaim_kept for it); this path has
            # no charset guard because it names rather than deletes, so it
            # the two. Erring towards naming one prefix too few here costs a
            # missing alert on a directory that is not a session anyway.
            case "$session" in
                .reclaim-state) continue ;;   # the old two-run marker folder of earlier releases
            esac
            if [ "$n" -ge "$UNAVAILABLE_SESSION_CAP" ]; then
                jlog reclaim_unavailable "" "reported ${n} staged sessions and stopped at the cap — staging holds more than are named above" \
                    ",\"reason\":\"${slug}\",\"truncated\":true"
                break
            fi
            n=$((n + 1))
            # No shell interpolation of $session happens anywhere on this path
            # (the filer is never called), so an unsafe prefix name is safe to
            # NAME here; jsan strips control characters and escapes quotes.
            jlog reclaim_unavailable "$session" "staged, and this run could not decide anything about it: ${msg}" \
                ",\"reason\":\"${slug}\""
        done <<EOF
${listed}
EOF
    fi
    exit 1
}

# -----------------------------------------------------------------------------
# Pre-flight. Every failure below aborts the WHOLE run before a single
# decision is taken, rather than degrading into a run that keeps everything:
# a reclaimer that silently examines nothing looks exactly like a reclaimer
# with nothing to do.
# -----------------------------------------------------------------------------
# =============================================================================
# WHERE THE STAGED COPY LIVES. Everything below the XNAT probe is the same on
# both tiers: ask XNAT what it holds, compare it against what is staged here,
# and delete only when they agree. The ONLY thing that differs is the medium.
#
#   s3          tier-2. The edge syncs to a bucket and this runs centrally.
#   filesystem  tier-1. There is no bucket and no s3-uploader, so the terminal
#               tree on the node IS the staged copy.
#
# WHY TIER-1 NEEDS THIS AT ALL. Its reclaim conditions are unsatisfiable
# without it: `onUploaded` tests for a marker written only by the s3-uploader,
# which upload.mode=direct never renders, so /data/assigned (and, under the
# ingest engine, /data/deidentified) grow for ever with nothing able to retire
# them. A marker would only be a local claim that an upload happened; asking
# XNAT for the count and bytes it actually holds is stronger evidence, and the
# code for it is already here.
case "$STORAGE" in
    s3|filesystem) : ;;
    *) unavailable bad_storage "STORAGE=${STORAGE} is not one of s3, filesystem — refusing to run" ;;
esac
# The root the filesystem backend may look at and delete within. Every path it
# touches is built from this and a single validated session name, and nothing
# outside it is ever passed to rm.
STAGED_ROOT="${STAGED_ROOT:-}"

if [ "$RECLAIM" != "onXnatConfirmed" ]; then
    unavailable reclaim_disabled "reclaim=${RECLAIM} is not onXnatConfirmed — refusing to remove anything"
fi

# python3 is in this list on purpose. It runs reclaim-files.py (the listing,
# the proof and every delete), and the xnat-ingest image, the pin the uploader
# uses, has it with boto3. If a future base image dropped it, nothing would be
# examined and the reclaimer would quietly keep everything forever. That is
# safe, and it is also indistinguishable from "there was nothing to reclaim".
# Fail loudly instead.
REQUIRED_TOOLS="curl date timeout python3"
for tool in $REQUIRED_TOOLS; do
    command -v "$tool" >/dev/null 2>&1 || {
        # If python3 itself is what is missing, the fan-out inside `unavailable`
        # finds nothing to list and the run-level line stands alone. Nothing to
        # do about that from in here; it is why the run-level line exists.
        unavailable missing_tool "required tool '${tool}' is not in this image — the reclaimer needs curl (the XNAT probe and session, the filer health check), python3 with boto3 (reclaim-files.py: the S3 listing, the proof, every delete), date and timeout; nothing was examined and nothing was removed"
    }
done

# Filer reachability. Checked up front so an unreachable filer aborts the run
# rather than surfacing as a per-session removal failure after the XNAT
# confirmations have already been spent.
if [ "$STORAGE" = "s3" ]; then
    if ! filer_code=$(timeout "$HTTP_TIMEOUT" curl -sS -o /dev/null -w '%{http_code}' \
            "${FILER_ENDPOINT%/}/buckets/?limit=1" 2>&1); then
        unavailable filer_unreachable "filer at ${FILER_ENDPOINT} is unreachable: ${filer_code}"
    fi
    case "$filer_code" in
        2*|3*) : ;;
        *) unavailable filer_unhealthy "filer at ${FILER_ENDPOINT} answered HTTP ${filer_code} — refusing to run" ;;
    esac
fi

if [ "$STORAGE" = "filesystem" ]; then
    # A MISSING ROOT IS NOT AN EMPTY ROOT. If the path is absent or is not a
    # directory the correct answer is "I cannot examine anything", never "there
    # is nothing to reclaim" -- the second would look like a healthy quiet run.
    [ -n "$STAGED_ROOT" ] || \
        unavailable staged_root_unset "STORAGE=filesystem needs STAGED_ROOT — nothing was examined"
    [ -d "$STAGED_ROOT" ] || \
        unavailable staged_root_missing "STAGED_ROOT=${STAGED_ROOT} is not a directory — nothing was examined and nothing removed"
    case "$STAGED_ROOT" in
        /|/data|/data/|"") unavailable staged_root_unsafe "STAGED_ROOT=${STAGED_ROOT} is too broad to delete within — point it at one stage directory" ;;
    esac
    # Armed: every delete happens inside the upload-tree writer lock. Without its
    # paths there is no safe delete, so refuse the run, loudly.
    if [ "$DRY_RUN" != "true" ] && { [ -z "${WRITER_LOCK:-}" ] || [ -z "${WRITER_ALIVE:-}" ]; }; then
        unavailable writer_lock_unset "WRITER_LOCK and WRITER_ALIVE must be set to delete on the filesystem; nothing was examined"
    fi
fi

# minAge -> seconds. An unparseable value must NOT collapse to 0: that would
# make every staged session instantly eligible.
# GUIDING: both charts pass minAge through as written, so THIS is its parser.
# BASE 10 (10#). Plain $(( )) reads a leading zero as octal: "010d" was 8 days,
# and "08d" an arithmetic error that left MIN_AGE_S empty, so the age test
# failed open and only the XNAT check stood between a session and removal.
# AT MOST 10 DIGITS, as in the charts' durationSeconds, so the multiply cannot
# wrap. "999999999999999d" wrapped negative and failed open the same way.
# CAUTION: YAML reads an unquoted 010 as octal (8) before it gets here.
to_seconds() {
    local v="${1:-}" n u
    n="${v%[a-zA-Z]}"; u="${v#"$n"}"
    case "$n" in ''|*[!0-9]*) echo ERR; return ;; esac
    [ "${#n}" -le 10 ] || { echo ERR; return; }
    case "$u" in
        ''|s) echo $(( 10#$n )) ;;
        m)    echo $(( 10#$n * 60 )) ;;
        h)    echo $(( 10#$n * 3600 )) ;;
        d)    echo $(( 10#$n * 86400 )) ;;
        w)    echo $(( 10#$n * 604800 )) ;;
        *)    echo ERR ;;
    esac
}
MIN_AGE_S=$(to_seconds "$MIN_AGE")
# Name the key the operator set: the edge chart (STORAGE=filesystem) passes
# stagedReclaimer.minAge, the mgmt chart s3Staged.minAge.
if [ "$STORAGE" = "filesystem" ]; then
    _minage_key="dataPolicy.derived.stagedReclaimer.minAge"
else
    _minage_key="dataPolicy.derived.s3Staged.minAge"
fi
# Check the RESULT, not only for ERR: empty or negative must refuse as well.
case "$MIN_AGE_S" in
    ''|*[!0-9]*)
        unavailable minage_unparseable "${_minage_key}=${MIN_AGE} is not a duration I can parse (expected at most 10 digits and an optional s/m/h/d/w, e.g. 0, 90m, 12h, 1d, 2w), so refusing to run rather than treating it as 0" ;;
esac

# THE TREE'S OWN minAge (edge chart only; the mgmt chart passes none).
# data-policy hands this tree to us before its own age check, so without this
# no deleter reads derived.<tree>.minAge. Wait for the LONGER of the two.
TREE_MIN_AGE="${TREE_MIN_AGE:-}"
TREE_MIN_AGE_KEY="${TREE_MIN_AGE_KEY:-TREE_MIN_AGE}"
if [ -n "$TREE_MIN_AGE" ]; then
    TREE_MIN_AGE_S=$(to_seconds "$TREE_MIN_AGE")
    case "$TREE_MIN_AGE_S" in
        ''|*[!0-9]*)
            unavailable minage_unparseable "${TREE_MIN_AGE_KEY}=${TREE_MIN_AGE} is not a duration I can parse (expected at most 10 digits and an optional s/m/h/d/w, e.g. 0, 90m, 12h, 1d, 2w), so refusing to run rather than ignoring it" ;;
    esac
    if [ "$TREE_MIN_AGE_S" -gt "$MIN_AGE_S" ]; then
        MIN_AGE="$TREE_MIN_AGE" MIN_AGE_S="$TREE_MIN_AGE_S" _minage_key="$TREE_MIN_AGE_KEY"
    fi
fi
# A FOLDER STORE NEEDS A POSITIVE AGE. The delete rechecks each file by identity (inode,
# size, mtime, ctime) taken before the proof; the kernel stamps file times at tick
# granularity, so a rewrite within the tick of the previous write keeps its identity.
# With minAge of at least a second every identity the proof saw is at least that much
# older than any later write, which lands in a later tick. With 0, a same-size rewrite
# right after a write can pass the recheck (codex-193). The chart refuses under 1m;
# this is the deleter's own floor. The bucket store needs none: If-Match binds content.
if [ "$STORAGE" = "filesystem" ] && [ "$MIN_AGE_S" -lt 1 ]; then
    unavailable minage_zero "${_minage_key}=${MIN_AGE} is under one second: the file identities this deleter rechecks cannot tell a rewrite within the same clock tick from the original; set at least 1m. Nothing was examined"
fi

# The per-run removal cap is the blast-radius bound, and a non-numeric value
# does not clamp it, it REMOVES it: `[ N -ge notanumber ]` prints "integer
# expression expected" and exits 2, which `if` reads as false, so the check at
# the top of the session loop never breaks. Verified: `[ 0 -ge unlimited ]`
# exits 2. Refuse to run rather than run uncapped.
#
# 0 is accepted but does NOT mean "examine everything, remove nothing".
# The cap is tested at the TOP of the session loop and breaks, so 0 stops
# the run before the first session is examined: one session-less
# reclaim_skipped, examined=1, and no per-session evidence at all. That
# starves the staged-session alert, which reads per-session events. If you
# want confirm-without-delete today, use dryRun, not maxRemovals: 0.
case "$MAX_REMOVALS" in
    ''|*[!0-9]*)
        unavailable maxremovals_invalid "dataPolicy.derived.s3Staged.maxRemovals=${MAX_REMOVALS} is not a whole number — a non-numeric cap silently disables the per-run removal limit rather than clamping it, so refusing to run"
        ;;
esac

[ -f "$FILES_HELPER" ] || \
    unavailable missing_tool "this reclaimer needs ${FILES_HELPER}; nothing was examined"
if [ "$STORAGE" = "s3" ]; then
    python3 -c 'import boto3' 2>/dev/null || \
        unavailable missing_tool "python3 in this image has no boto3 module; reclaim-files.py needs it for the S3 listing, the sidecar reads and every delete; nothing was examined"
    if ! err=$(python3 "$FILES_HELPER" --probe 2>&1); then
        unavailable bucket_unreachable "cannot reach bucket ${S3_BUCKET}: $(jsan "$err")"
    fi
    # THE GATE. SeaweedFS removes an empty folder on its own soon after its last
    # object goes, with a window in which a child written meanwhile is dropped.
    # No delete here until the bucket says the cleaner is opted out AND the
    # activation procedure (drain, restart) attested it: scripts/cleaner-activation.sh.
    if ! gate=$(python3 "$FILES_HELPER" --gate 2>&1); then
        unavailable "${gate%% *}" "$(jsan "${gate#* }")"
    fi
fi

# --- XNAT ---------------------------------------------------------------------
XNAT_SERVER="${XNAT_SERVER:-}"
XNAT_SERVER="${XNAT_SERVER%/}"
CURL_OPTS=(-sS --max-time "$HTTP_TIMEOUT" -o - -w '\n%{http_code}')
# xnatUpload.verifySsl=false. The uploader is given --dont-verify-ssl for the
# same XNAT; the reclaimer must not be stricter, or it would confirm nothing
# and quietly keep everything forever.
[ "$XNAT_VERIFY_SSL" = "true" ] || CURL_OPTS+=(-k)

# Credentials go to curl on STDIN, never in argv: this container's `ps` output
# and any crash dump would otherwise carry the XNAT password.
curl_esc() { printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# -----------------------------------------------------------------------------
# ONE SESSION PER RUN, RELEASED ON EXIT.
#
# XNAT mints a NEW server-side session for every Basic-Auth request and keeps it
# until it times out. This script authenticates on every call — the pre-flight,
# then several per staged session — so an hourly run leaked dozens of sessions a
# day. Observed on the live server: "You have 83 sessions open from one IP
# address", all of them ours.
#
# The documented pattern is to exchange the credentials for one JSESSIONID, reuse
# it, and DELETE it when finished. That is what the web UI does, and it turns
# tens of sessions per day into one per run.
#
# The token goes to curl on STDIN as a header, for the same reason the password
# does: a `-H "Cookie: ..."` would put a live session token in argv, where `ps`
# and any crash dump would carry it.
#
# FALLING BACK IS DELIBERATE. If /data/JSESSION cannot be reached, this keeps
# working with per-request Basic Auth rather than refusing to run: leaking
# sessions is untidy, but a reclaimer that will not start is the failure mode
# that leaves staging to grow unbounded.
#
# EVERY XNAT CALL USES xnat_auth AND CURL_OPTS. Until 2026-10-14 the pre-flight
# probe sent the credentials itself: one extra session per run, on every site.
# The logout had its own curl options without -k: where the certificate does
# not verify (XNAT_VERIFY_SSL=false, as on the test edge) it failed in silence,
# a second session per run. There, XNAT showed 9 open on a 4-minute schedule.
# -----------------------------------------------------------------------------
XNAT_JSESSION=""

# The curl config line that authenticates one XNAT request: the run's session
# when it has one, else the credentials (each such request is a new session).
xnat_auth() {
    if [ -n "$XNAT_JSESSION" ]; then
        printf 'header = "Cookie: JSESSIONID=%s"\n' "$(curl_esc "$XNAT_JSESSION")"
    else
        printf 'user = "%s:%s"\n' "$(curl_esc "${XNAT_USER:-}")" "$(curl_esc "${XNAT_PASS:-}")"
    fi
}

xnat_login() {
    local out code
    # XNAT_JSESSION is empty here: this is the one credential login of the run.
    out=$(xnat_auth | curl "${CURL_OPTS[@]}" -K - "${XNAT_SERVER}/data/JSESSION" 2>/dev/null)
    code=$(printf '%s' "$out" | tail -n1)
    if [ "$code" = "200" ]; then
        # Body is the token; strip the trailing http_code line the -w added.
        XNAT_JSESSION=$(printf '%s' "$out" | sed '$d' | tr -d '\r\n "')
    fi
    if [ -n "$XNAT_JSESSION" ]; then
        jlog xnat_session_opened "" "reusing one XNAT session for this run"
    else
        jlog xnat_session_fallback "" "could not obtain a JSESSION (HTTP ${code}) — falling back to per-request auth, which leaves a session behind per call"
    fi
}

xnat_logout() {
    [ -n "$XNAT_JSESSION" ] || return 0
    local code
    code=$(xnat_auth | curl "${CURL_OPTS[@]}" -X DELETE -K - "${XNAT_SERVER}/data/JSESSION" 2>/dev/null | tail -n1)
    [ "$code" = "200" ] \
        || jlog xnat_session_close_failed "" "the XNAT logout returned HTTP ${code:-000}; XNAT keeps this session until it times out"
    XNAT_JSESSION=""
}
# Released however the run ends — including the `unavailable`/`die` paths, which
# exit early and would otherwise leak the very session this change exists to stop.
trap xnat_logout EXIT

# PROOF=s3 (the edge in S3 mode): the next copy is the bucket, and reclaim-files.py
# proves each file there (the MD5 of its bytes against the object's ETag). XNAT is
# not consulted and no XNAT credential is needed; verifyAgainstXnat has no effect.
PROOF="${PROOF:-xnat}"
case "$PROOF" in xnat|s3) : ;; *) unavailable bad_proof "PROOF=${PROOF} is not one of xnat, s3 — refusing to run" ;; esac
if [ "$PROOF" = "s3" ]; then
    [ "$STORAGE" = "filesystem" ] || unavailable bad_proof "PROOF=s3 proves a local tree against the bucket; STORAGE=${STORAGE} already is the bucket"
    [ -n "${S3_BUCKET:-}" ] || unavailable bucket_unset "PROOF=s3 needs S3_BUCKET; nothing was examined"
    python3 -c 'import boto3' 2>/dev/null || \
        unavailable missing_tool "python3 in this image has no boto3 module; reclaim-files.py needs it to list the bucket for the proof; nothing was examined"
elif [ "$VERIFY_XNAT" = "true" ]; then
    if [ -z "$XNAT_SERVER" ] || [ -z "${XNAT_USER:-}" ] || [ -z "${XNAT_PASS:-}" ]; then
        unavailable xnat_credentials_missing "verifyAgainstXnat=true but the XNAT credentials Secret gave an empty server/username/password"
    fi
    # Open the single session BEFORE the pre-flight probe, so the probe itself
    # reuses it rather than being the first of many leaked logins.
    xnat_login
    # THE PRE-FLIGHT KEEPS curl's STDERR AND EXIT STATUS. Every other caller
    # discards both, and for them that is right — they parse a body. Here it is
    # the whole diagnostic.
    #
    # `000` is curl's placeholder for "no HTTP response at all", so DNS failure
    # (exit 6), connection refused (7), timeout (28) and TLS failure (35) are
    # INDISTINGUISHABLE in the code alone. Measured: 19 xnat_probe_failed aborts
    # over five days, and afterwards nothing in the logs could say which fault
    # each one was — separating them needed a live investigation that only
    # worked because the fault was still recurring. `-sS` is already in
    # CURL_OPTS specifically so curl prints that one line; it was then thrown
    # away. This is what makes the FIRST notification actionable.
    #
    # No mktemp: the tool pre-flight above guarantees aws, curl and python3
    # only, and a missing mktemp would turn a diagnostic into a crash. $$ in
    # the container's own tmp is unique enough for a single-purpose pod.
    # jsan() escapes the result, so a multi-line curl error cannot break the
    # one-JSON-object-per-line contract.
    probe_err="${TMPDIR:-/tmp}/reclaim-xnat-probe-$$.err"
    probe_rc=0
    probe=$(xnat_auth | curl "${CURL_OPTS[@]}" \
                   -w '\n%{time_namelookup} %{time_connect} %{time_appconnect}\n%{http_code}' \
                   -K - "${XNAT_SERVER}/data/projects?format=json" 2>"$probe_err") || probe_rc=$?
    # curl uses the LAST -w, so the tail is: <body>\n<timings>\n<http_code>.
    code=$(printf '%s' "$probe" | tail -n1)
    probe_timings=$(printf '%s' "$probe" | tail -n2 | head -n1)
    probe_err_text=$(tr '\n' ' ' < "$probe_err" 2>/dev/null)
    rm -f "$probe_err"
    case "$code" in
        301|302|303|307|308)
            unavailable xnat_probe_failed "XNAT returned HTTP ${code}: set the server in xnat-credentials to its final HTTPS URL. The reclaimer does not follow redirects; HTTP sends credentials in clear text. Nothing was removed" ;;
    esac
    if [ "$code" != "200" ]; then
        # Not a data-loss condition — but every session would come back
        # unconfirmed, so the run would be a very expensive no-op.
        #
        # THIS IS THE ONE THAT WAS OBSERVED (HTTP 000 twice in 24h, see the
        # abort note above). Going through `unavailable` is what keeps
        # SessionStagedNotConfirmedInXNAT supplied with staged sessions while
        # XNAT is unanswerable, instead of muting it.
        unavailable xnat_probe_failed "XNAT auth probe returned HTTP ${code} (curl exit ${probe_rc}: ${probe_err_text:-no stderr}; namelookup/connect/tls ${probe_timings:-?}s) — cannot confirm any session, so nothing is eligible; nothing removed"
    fi
else
    # dataPolicy.derived.s3Staged.verifyAgainstXnat=false. Deletion then rests
    # on age alone, i.e. on the assumption that the uploader got everything
    # older than minAge into XNAT — which is exactly the assumption that put
    # this component in the chart. Loud on purpose.
    jlog startup "" "WARNING verifyAgainstXnat=false — sessions older than ${MIN_AGE} will be removed WITHOUT asking XNAT whether it holds them. Undelivered data will be lost."
fi

if [ "$STORAGE" = "filesystem" ]; then
    _origin="root=${STAGED_ROOT}"
else
    _origin="bucket=${S3_BUCKET} prefix=${S3_PREFIX}"
fi
# Bucket proof uses its own content checks; the XNAT switch does not apply.
_verify_summary="${VERIFY_XNAT}"
[ "$PROOF" = s3 ] && _verify_summary="not-applicable(proof=s3)"
jlog startup "" "s3-reclaimer starting storage=${STORAGE} ${_origin} proof=${PROOF} minAge=${MIN_AGE} (from ${_minage_key}) verifyAgainstXnat=${_verify_summary} dryRun=${DRY_RUN} maxRemovals=${MAX_REMOVALS}"

# -----------------------------------------------------------------------------
# S3 helpers. Each returns ERR on ANY doubt — a non-zero exit, an empty
# answer, or output that is not the shape expected. Callers treat ERR as KEEP.
# `wc -l`-through-a-pipe is deliberately avoided: a failed `aws` on the left of
# a pipe still yields "0" on the right, which reads as "empty, safe to delete".
# -----------------------------------------------------------------------------
numeric_or_err() {
    case "${1:-}" in ''|*[!0-9]*) echo ERR ;; *) echo "$1" ;; esac
}

# s3_list_prefixes, fs_list_prefixes and st_list_prefixes all live ABOVE the
# pre-flight, not here with their siblings: `unavailable` calls the dispatcher,
# and the pre-flight runs before this point in the file. Defining them lower
# down made an aborted run die with `st_list_prefixes: command not found`
# instead of reporting why it aborted.

# =============================================================================
# Main pass
# =============================================================================

# =============================================================================
# BOTH BACKENDS: reclaim-files.py
# =============================================================================
# reclaim-files.py, next to this script, decides per resource: a HEAD per file
# against XNAT, then the delete. A session folder: exact files inside the
# upload-tree writer lock. A session prefix: one DeleteObject per object with
# If-Match, never a folder. This script runs the pre-flight and starts one
# worker for the data pass; no delete happens in this script.

# Keep pre-flight gates above. The data pass uses one worker/client per run;
# it discovers names once, then takes a fresh snapshot for each session.
rc=0
STORAGE="$STORAGE" S3_BUCKET="${S3_BUCKET:-}" S3_PREFIX="$S3_PREFIX" FILER_ENDPOINT="${FILER_ENDPOINT:-}" \
    MIN_AGE="$MIN_AGE" MIN_AGE_S="$MIN_AGE_S" MIN_AGE_KEY="$_minage_key" DRY_RUN="$DRY_RUN" \
    VERIFY_XNAT="$VERIFY_XNAT" XNAT_SERVER="$XNAT_SERVER" XNAT_JSESSION="$XNAT_JSESSION" \
    HTTP_TIMEOUT="$HTTP_TIMEOUT" MAX_REMOVALS="$MAX_REMOVALS" PROOF="$PROOF" \
    run_files_helper --batch || rc=$?
[ "$rc" -eq 20 ] && exit 1  # discovery abort: reclaim_unavailable was already logged
if [ "$rc" -ne 0 ]; then
    jlog reclaim_failed "" "reclaim-files.py stopped with exit ${rc}; the run did not finish"
fi
exit "$rc"
