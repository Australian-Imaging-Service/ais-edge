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
#   * CAUTION: deletion goes through the FILER's HTTP DELETE, never
#     `aws s3 rm` — see docs/components/seaweedfs.md, "Deletion must go
#     through the filer", for why. HTTP rather than `weed shell` over
#     kubectl exec also means this job needs no pods/exec RBAC.
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
#     reclaim_removed    fs.rm -r returned 0 for this prefix
#     reclaim_kept       deliberately NOT removed — undelivered, or uncertain
#     reclaim_failed     removal ran but the prefix is still listed
#     reclaim_unavailable  pre-flight failed; nothing was DECIDED. Emitted once
#                        with session="" for the run, then once per staged
#                        session — see the pre-flight note below for why the
#                        per-session copies are not redundant.
#     reclaim_finished   the run walked staging to the end. NEVER emitted by an
#                        aborted run: "could not decide" and "decided there was
#                        nothing to do" must not look alike in the log.
# =============================================================================
set -uo pipefail

# --- required -----------------------------------------------------------------
: "${S3_BUCKET:?S3_BUCKET required}"
: "${CLUSTER_LABEL:?CLUSTER_LABEL required}"
# Base URL of the SeaweedFS FILER HTTP API (port 8888), e.g.
#   http://mgmt-seaweedfs.seaweedfs.svc.cluster.local:8888
# This is the only way a directory ENTRY can be removed; the S3 gateway
# cannot do it. In-cluster and plain http on purpose.
: "${FILER_ENDPOINT:?FILER_ENDPOINT required}"

S3_PREFIX="${S3_PREFIX:-staged}"

# Where the two-consecutive-runs markers live. DELIBERATELY OUTSIDE S3_PREFIX.
#
# `xnat-ingest upload` lists s3://<bucket>/<S3_PREFIX> and treats every prefix
# it finds as a session. A state directory under staged/ would therefore be
# picked up as a session, "uploaded" with zero resources, and would re-fire
# XNATUploadSuccess every loop — recreating precisely the bug this reclaimer
# exists to fix, using the mechanism built to prevent it. Keep it as a sibling
# of staged/, never a child.
STATE_PREFIX="${STATE_PREFIX:-.reclaim-state}"
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

# Session prefixes, exactly as the uploader sees them: one delimited listing of
# staging. This includes 0-byte ghost entries, which is the point.
#
# Defined UP HERE, above the pre-flight, rather than with the other S3 helpers
# further down: `unavailable` below calls it, and a bash function must exist by
# the time it is called, not merely somewhere in the file.
s3_list_prefixes() {
    local raw
    raw=$(aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "${S3_PREFIX}/" \
            --delimiter / --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null) || return 1
    # No prefixes at all: the CLI prints "None" for a null JMESPath result.
    [ "$raw" = "None" ] && return 0
    printf '%s' "$raw" | tr '\t' '\n' | sed "s#^${S3_PREFIX}/##; s#/\$##" | grep -v '^$'
    return 0
}

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

    if listed=$(s3_list_prefixes 2>/dev/null); then
        while IFS= read -r session; do
            [ -n "$session" ] || continue
            # Our own state prefix is not a session. The main pass matches the
            # literal `.reclaim-state` only (its charset guard catches any
            # other dot-prefix and logs a reclaim_kept for it); this path has
            # no charset guard because it names rather than deletes, so it
            # matches $STATE_PREFIX too and is deliberately the stricter of
            # the two. Erring towards naming one prefix too few here costs a
            # missing alert on a directory that is not a session anyway.
            case "$session" in
                "$STATE_PREFIX"|.reclaim-state) continue ;;
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
if [ "$RECLAIM" != "onXnatConfirmed" ]; then
    unavailable reclaim_disabled "reclaim=${RECLAIM} is not onXnatConfirmed — refusing to remove anything"
fi

# python3 is in this list on purpose. It parses the object-count JSON, and it
# is present in amazon/aws-cli:2.31.19 (3.9.23, verified) — but if a future
# base image drops it, every count would return ERR and the reclaimer would
# quietly keep everything forever. That is safe, and it is also indis-
# tinguishable from "there was nothing to reclaim". Fail loudly instead.
for tool in aws curl date timeout python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        # If `aws` itself is what is missing, the fan-out inside `unavailable`
        # finds nothing to list and the run-level line stands alone. Nothing to
        # do about that from in here; it is why the run-level line exists.
        unavailable missing_tool "required tool '${tool}' is not in this image — the reclaimer needs aws-cli (S3 listings), curl (XNAT REST + the filer delete) and python3 (parsing object counts); nothing was examined and nothing was removed"
    }
done

# Filer reachability. Checked up front so an unreachable filer aborts the run
# rather than surfacing as a per-session removal failure after the XNAT
# confirmations have already been spent.
if ! filer_code=$(timeout "$HTTP_TIMEOUT" curl -sS -o /dev/null -w '%{http_code}' \
        "${FILER_ENDPOINT%/}/buckets/?limit=1" 2>&1); then
    unavailable filer_unreachable "filer at ${FILER_ENDPOINT} is unreachable: ${filer_code}"
fi
case "$filer_code" in
    2*|3*) : ;;
    *) unavailable filer_unhealthy "filer at ${FILER_ENDPOINT} answered HTTP ${filer_code} — refusing to run" ;;
esac

# minAge -> seconds. An unparseable value must NOT collapse to 0: that would
# make every staged session instantly eligible.
to_seconds() {
    local v="${1:-}" n u
    n="${v%[a-zA-Z]}"; u="${v#"$n"}"
    case "$n" in ''|*[!0-9]*) echo ERR; return ;; esac
    case "$u" in
        ''|s) echo "$n" ;;
        m)    echo $(( n * 60 )) ;;
        h)    echo $(( n * 3600 )) ;;
        d)    echo $(( n * 86400 )) ;;
        w)    echo $(( n * 604800 )) ;;
        *)    echo ERR ;;
    esac
}
MIN_AGE_S=$(to_seconds "$MIN_AGE")
if [ "$MIN_AGE_S" = "ERR" ]; then
    unavailable minage_unparseable "dataPolicy.derived.s3Staged.minAge=${MIN_AGE} is not a duration I can parse (expected e.g. 0, 90m, 12h, 1d, 2w) — refusing to run rather than treating it as 0"
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

if ! err=$(aws s3api head-bucket --bucket "$S3_BUCKET" 2>&1); then
    unavailable bucket_unreachable "head-bucket ${S3_BUCKET} failed: ${err}"
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
# -----------------------------------------------------------------------------
XNAT_JSESSION=""

xnat_login() {
    local out code
    out=$(printf 'user = "%s:%s"\n' "$(curl_esc "${XNAT_USER:-}")" "$(curl_esc "${XNAT_PASS:-}")" \
          | curl "${CURL_OPTS[@]}" -K - "${XNAT_SERVER}/data/JSESSION" 2>/dev/null)
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
    printf 'header = "Cookie: JSESSIONID=%s"\n' "$(curl_esc "$XNAT_JSESSION")" \
        | curl -sS --max-time "$HTTP_TIMEOUT" ${XNAT_VERIFY_SSL:+} -o /dev/null \
               -X DELETE -K - "${XNAT_SERVER}/data/JSESSION" 2>/dev/null
    XNAT_JSESSION=""
}
# Released however the run ends — including the `unavailable`/`die` paths, which
# exit early and would otherwise leak the very session this change exists to stop.
trap xnat_logout EXIT

xnat_get() {
    if [ -n "$XNAT_JSESSION" ]; then
        printf 'header = "Cookie: JSESSIONID=%s"\n' "$(curl_esc "$XNAT_JSESSION")" \
            | curl "${CURL_OPTS[@]}" -K - "$1" 2>/dev/null
    else
        printf 'user = "%s:%s"\n' "$(curl_esc "${XNAT_USER:-}")" "$(curl_esc "${XNAT_PASS:-}")" \
            | curl "${CURL_OPTS[@]}" -K - "$1" 2>/dev/null
    fi
}

if [ "$VERIFY_XNAT" = "true" ]; then
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
    probe=$(printf 'user = "%s:%s"\n' "$(curl_esc "${XNAT_USER:-}")" "$(curl_esc "${XNAT_PASS:-}")" \
            | curl "${CURL_OPTS[@]}" \
                   -w '\n%{time_namelookup} %{time_connect} %{time_appconnect}\n%{http_code}' \
                   -K - "${XNAT_SERVER}/data/projects?format=json" 2>"$probe_err") || probe_rc=$?
    # curl uses the LAST -w, so the tail is: <body>\n<timings>\n<http_code>.
    code=$(printf '%s' "$probe" | tail -n1)
    probe_timings=$(printf '%s' "$probe" | tail -n2 | head -n1)
    probe_err_text=$(tr '\n' ' ' < "$probe_err" 2>/dev/null)
    rm -f "$probe_err"
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

jlog startup "" "s3-reclaimer starting bucket=${S3_BUCKET} prefix=${S3_PREFIX} minAge=${MIN_AGE} verifyAgainstXnat=${VERIFY_XNAT} dryRun=${DRY_RUN} maxRemovals=${MAX_REMOVALS}"

# -----------------------------------------------------------------------------
# S3 helpers. Each returns ERR on ANY doubt — a non-zero exit, an empty
# answer, or output that is not the shape expected. Callers treat ERR as KEEP.
# `wc -l`-through-a-pipe is deliberately avoided: a failed `aws` on the left of
# a pipe still yields "0" on the right, which reads as "empty, safe to delete".
# -----------------------------------------------------------------------------
numeric_or_err() {
    case "${1:-}" in ''|*[!0-9]*) echo ERR ;; *) echo "$1" ;; esac
}

# s3_list_prefixes lives ABOVE the pre-flight, not here with its siblings:
# `unavailable` calls it, and the pre-flight runs before this point in the file.

# --output json, NOT --output text.
#
# With `--output text` the AWS CLI applies --query PER PAGE, so any session
# over 1000 objects returns one number per page — a multi-line answer that
# fails numeric_or_err and keeps the session forever as `listing_failed`.
# Fail-safe, but it silently disables reclaiming for exactly the large
# sessions that matter most for disk. `--output json` is fully buffered and
# returns one document, and the count is parsed explicitly so that anything
# unexpected is ERR rather than a plausible-looking number.
s3_object_count() {
    local out
    out=$(aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "${S3_PREFIX}/${1}/" \
            --output json 2>/dev/null) || { echo ERR; return; }
    printf '%s' "$out" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("ERR"); sys.exit()
if d.get("IsTruncated"):
    # Should not happen: list-objects-v2 through the CLI paginates for us and
    # returns the assembled result. If it ever does, we do NOT know the true
    # count, and guessing is how a session gets deleted early.
    print("ERR"); sys.exit()
c = d.get("Contents")
print(len(c) if isinstance(c, list) else 0)
' 2>/dev/null || echo ERR
}

# In-flight multipart uploads. A session whose first object is still being
# assembled can present as a 0-object prefix; without this probe the
# empty-prefix branch below would delete an upload in progress.
s3_multipart_count() {
    local out
    out=$(aws s3api list-multipart-uploads --bucket "$S3_BUCKET" --prefix "${S3_PREFIX}/${1}/" \
            --query 'length(Uploads || `[]`)' --output text 2>/dev/null) || { echo ERR; return; }
    numeric_or_err "$out"
}

# Age is measured from the NEWEST object, not the oldest: a session that is
# still being written into must never look old enough to reclaim.
s3_newest_epoch() {
    local iso e
    iso=$(aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "${S3_PREFIX}/${1}/" \
            --query 'sort_by(Contents || `[]`, &LastModified)[-1].LastModified' --output text 2>/dev/null) || { echo ERR; return; }
    [ -n "$iso" ] && [ "$iso" != "None" ] || { echo ERR; return; }
    e=$(date -d "$iso" +%s 2>/dev/null) || { echo ERR; return; }
    numeric_or_err "$e"
}

# -----------------------------------------------------------------------------
# XNAT confirmation
# -----------------------------------------------------------------------------
# GUIDING: staged prefixes are PROJECT.SUBJECT.VISIT (docs/components/
# xnat-ingest.md). Query is path-addressed to that one subject/project — a
# 404 is unambiguous — and requires an EXACT label/ID match; a substring
# match could confirm the wrong session, and confirming wrong deletes right.
# Returns 0 ONLY on positive confirmation; any other code, an HTML login
# page, an empty result, or an unparseable name all keep the session.
#
# CAUTION — NAMES, not just a count. "XNAT holds 400 files" does not mean
# THESE 400 — two equal-sized sessions, a partial overwrite, or files landed
# under the wrong scan would all pass a count check and fail a name one. The
# set of files a STAGED session claims, as "<name>\t<md5>" lines summed from
# every __MANIFEST__.json under its prefix, is compared against XNAT's exact
# reported filenames (verified live: manifest keys match `Name` verbatim,
# including the full DICOM UID).
staged_manifest_files() {
    local session="$1" keys out mf
    keys=$(aws s3api list-objects-v2 --bucket "$S3_BUCKET" \
             --prefix "${S3_PREFIX}/${session}/" --output json 2>/dev/null) || { echo ERR; return; }
    mf=$(printf '%s' "$keys" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if d.get("IsTruncated"):
    sys.exit(1)
for o in d.get("Contents") or []:
    k = o.get("Key","")
    if k.endswith("/__MANIFEST__.json"):
        print(k)
' 2>/dev/null) || { echo ERR; return; }

    # No manifest at all means we cannot say what SHOULD be there. Keep.
    [ -n "$mf" ] || { echo ERR; return; }

    local all=""
    while IFS= read -r key; do
        [ -n "$key" ] || continue
        out=$(aws s3 cp "s3://${S3_BUCKET}/${key}" - 2>/dev/null) || { echo ERR; return; }
        local part
        part=$(printf '%s' "$out" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
c = d.get("checksums")
if not isinstance(c, dict) or not c:
    sys.exit(1)
for name, md5 in sorted(c.items()):
    print("%s\t%s" % (name, md5 or ""))
' 2>/dev/null) || { echo ERR; return; }
        all="${all}${part}
"
    done <<EOF
$mf
EOF
    all=$(printf '%s' "$all" | grep -v '^$' | sort -u)
    [ -n "$all" ] || { echo ERR; return; }
    printf '%s' "$all"
}

# The set of files XNAT actually holds for this session, as
# "<name>\t<digest>" lines. Echoes ERR on ANY doubt: a non-200, an HTML login
# page, an unparseable body, an experiment that is absent, a session name that
# does not decompose. The caller treats ERR as KEEP.
#
# `digest` is empty unless the XNAT catalog was built with checksums enabled —
# it is empty on our server. It is carried through anyway so that a site which
# does enable it gets checksum comparison for free rather than needing a code
# change.
xnat_files() {
    local session="$1" project subject visit body code expid
    case "$session" in
        *.*.*.*|*..*|.*|*.) echo ERR; return ;;
        *.*.*) : ;;
        *) echo ERR; return ;;
    esac
    project="${session%%.*}"
    visit="${session##*.}"
    subject="${session#*.}"; subject="${subject%.*}"
    [ -n "$project" ] && [ -n "$subject" ] && [ -n "$visit" ] || { echo ERR; return; }

    body=$(xnat_get "${XNAT_SERVER}/data/projects/${project}/subjects/${subject}/experiments?format=json")
    code=$(printf '%s' "$body" | tail -n1)
    [ "$code" = "200" ] || { echo ERR; return; }

    expid=$(printf '%s' "$body" | sed '$d' | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
rows = (d.get("ResultSet") or {}).get("Result") or []
want = set(sys.argv[1:])
for r in rows:
    if r.get("label") in want or r.get("ID") in want:
        print(r.get("ID","")); break
' "$visit" "${subject}_${visit}" 2>/dev/null) || { echo ERR; return; }
    [ -n "$expid" ] || { echo ERR; return; }

    # /scans/ALL/files, NOT /files. Measured against a session known to be
    # complete: /files returns 0 rows because it lists resources attached to
    # the EXPERIMENT, not the files inside its scans.
    body=$(xnat_get "${XNAT_SERVER}/data/experiments/${expid}/scans/ALL/files?format=json")
    code=$(printf '%s' "$body" | tail -n1)
    [ "$code" = "200" ] || { echo ERR; return; }
    printf '%s' "$body" | sed '$d' | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
rows = (d.get("ResultSet") or {}).get("Result") or []
if not rows:
    sys.exit(1)
for r in rows:
    n = r.get("Name")
    if not n:
        sys.exit(1)
    print("%s\t%s" % (n, (r.get("digest") or "").strip()))
' 2>/dev/null || echo ERR
}

# -----------------------------------------------------------------------------
# Removal. The filer, and only the filer — docs/components/seaweedfs.md.
# -----------------------------------------------------------------------------
#     DELETE /buckets/<bucket>/<prefix>/<session>?recursive=true   -> 204
#
# CAUTION: `recursive=true` descends into scan subdirectories.
# `ignoreRecursiveError=false` (default) reports a partial failure rather
# than swallowing it — the caller re-lists staging afterwards and trusts
# only that, but a reported error is still better than a silent one.
#
# Echoes "HTTP <code>" plus any body, and returns non-zero on a non-2xx, so
# the caller can log what actually happened rather than assuming success.
filer_rm() {
    local session="$1" url body code
    url="${FILER_ENDPOINT%/}/buckets/${S3_BUCKET}/${S3_PREFIX}/${session}?recursive=true"
    body=$(timeout "$HTTP_TIMEOUT" curl -sS -X DELETE -w '\n%{http_code}' "$url" 2>&1) || {
        printf 'request failed: %s' "$(printf '%s' "$body" | tr '\n' ' ')"
        return 1
    }
    code=$(printf '%s' "$body" | tail -n1)
    printf 'HTTP %s %s' "$code" "$(printf '%s' "$body" | sed '$d' | tr '\n' ' ')"
    case "$code" in
        2*) return 0 ;;
        *)  return 1 ;;
    esac
}

# =============================================================================
# Main pass
# =============================================================================
if ! prefixes=$(s3_list_prefixes); then
    # The one abort where the fan-out probably cannot help: we could not list
    # staging, so we do not know what is in it. It still goes through
    # `unavailable` because the retry in there is free and a transient listing
    # failure that succeeds on the second attempt gets the per-session events.
    unavailable staging_list_failed "listing s3://${S3_BUCKET}/${S3_PREFIX}/ failed — nothing examined"
fi

now=$(date +%s)
removed=0; kept=0; skipped=0; examined=0
removed_list=""

# Read the listing LINE by line, never `for session in $prefixes`. Word
# splitting on a prefix containing a space turns one unknown name into several
# tokens, each of which passes the charset check below on its own — so
# "foo bar/" would be examined as "foo" and "bar", and a real session called
# `foo` could be deleted on the strength of a listing entry that was never
# about it. (Caught in test; it is the only data-loss path this script had.)
while IFS= read -r session; do
    [ -n "$session" ] || continue
    examined=$((examined + 1))

    # Our own state prefix, not a session. Skipped explicitly rather than
    # being caught by the charset guard below, which would log a spurious
    # "kept" for it on every single run and train people to ignore that event.
    case "$session" in
        .reclaim-state) continue ;;
    esac

    # The session name is interpolated into a remote `sh -c` a few lines below.
    # Anything outside this charset is rejected rather than quoted: a prefix
    # containing a quote or a semicolon would be a shell injection into a
    # command whose whole job is recursive deletion. Leading `-` is rejected
    # too, so a name can never be read as an option by anything downstream.
    case "$session" in
        *[!A-Za-z0-9._-]*|.*|-*|__*)
            keep "$session" "unsafe_prefix_name" "prefix name is not a plain [A-Za-z0-9._-] session id — refusing to pass it to the filer"
            kept=$((kept + 1)); continue ;;
    esac

    if [ "$removed" -ge "$MAX_REMOVALS" ]; then
        jlog reclaim_skipped "" "per-run removal cap of ${MAX_REMOVALS} reached — remaining sessions left for the next run"
        break
    fi

    count=$(s3_object_count "$session")
    if [ "$count" = "ERR" ]; then
        keep "$session" "listing_failed" "could not count objects — never delete on uncertainty"
        kept=$((kept + 1)); continue
    fi

    if [ "$count" = "0" ]; then
        # Ghost prefix: a 0-byte directory entry left behind by an
        # `aws s3 rm`/`mc rm` recursive delete. It holds NO data, so removing
        # it cannot lose anything — and while it exists the uploader lists it
        # as a session, "uploads" its zero resources and re-fires
        # XNATUploadSuccess every loop. minAge does not apply: an entry with
        # no objects has no timestamp to age from. The multipart probe below
        # is what distinguishes it from an upload that has only just started.
        mp=$(s3_multipart_count "$session")
        if [ "$mp" = "ERR" ]; then
            keep "$session" "multipart_probe_failed" "0 objects, but could not rule out an in-flight multipart upload"
            kept=$((kept + 1)); continue
        fi
        if [ "$mp" != "0" ]; then
            keep "$session" "upload_in_flight" "0 objects but ${mp} multipart upload(s) in progress — an edge is writing this session now"
            kept=$((kept + 1)); continue
        fi
        # TWO-CONSECUTIVE-RUNS RULE.
        #
        # `count == 0` and the delete are not atomic: a small single-part PUT
        # can land in between, and the multipart probe above does not catch it
        # because a small object is never multipart. Requiring the prefix to
        # have been empty on the PREVIOUS run too closes that window without
        # any locking — at an hourly schedule the object would have to arrive
        # and be gone again inside the same hour to slip through, and an
        # arriving object does not vanish.
        #
        # The marker lives in the bucket next to the data, so it survives pod
        # restarts and needs no extra storage.
        marker="${STATE_PREFIX}/${session}.empty"
        if aws s3api head-object --bucket "$S3_BUCKET" --key "$marker" >/dev/null 2>&1; then
            : # seen empty before — safe to proceed
        else
            if [ "$DRY_RUN" != "true" ]; then
                printf 'seen-empty %s\n' "$(date -Iseconds)" \
                    | aws s3 cp - "s3://${S3_BUCKET}/${marker}" --only-show-errors 2>/dev/null || true
            fi
            jlog reclaim_skipped "$session" "empty prefix seen for the FIRST time — deferring removal to the next run so a just-started upload cannot be deleted between the count and the delete" ",\"objects\":0"
            skipped=$((skipped + 1)); continue
        fi

        if [ "$DRY_RUN" = "true" ]; then
            jlog reclaim_skipped "$session" "dataPolicy dryRun/disabled — would have removed this empty prefix" ",\"objects\":0"
            skipped=$((skipped + 1)); continue
        fi
        if out=$(filer_rm "$session"); then
            jlog reclaim_removed "$session" "empty prefix removed via filer: ${out}" ",\"objects\":0,\"empty\":true"
            removed=$((removed + 1)); removed_list="${removed_list}${session}
"
        else
            # Not counted as removed, so it is not added to the
            # post-run verification list either — nothing was claimed.
            jlog reclaim_failed "$session" "filer refused the delete of this empty prefix: ${out}" ",\"objects\":0,\"empty\":true"
        fi
        continue
    fi

    # This prefix has objects, so any "seen empty" marker for it is stale and
    # must go — otherwise a session that was briefly empty and then filled
    # would carry a marker that authorises deletion on a later run.
    aws s3 rm "s3://${S3_BUCKET}/${STATE_PREFIX}/${session}.empty" \
        --only-show-errors >/dev/null 2>&1 || true

    newest=$(s3_newest_epoch "$session")
    if [ "$newest" = "ERR" ]; then
        keep "$session" "age_unknown" "${count} object(s) but no usable LastModified — cannot prove it is older than ${MIN_AGE}"
        kept=$((kept + 1)); continue
    fi
    age=$(( now - newest ))
    if [ "$age" -lt "$MIN_AGE_S" ]; then
        jlog reclaim_skipped "$session" "last written ${age}s ago, minAge is ${MIN_AGE} (${MIN_AGE_S}s)" \
            ",\"objects\":${count},\"age_s\":${age}"
        skipped=$((skipped + 1)); continue
    fi

    if [ "$VERIFY_XNAT" = "true" ]; then
        # COUNT, do not merely look for existence. XNAT creates the experiment
        # on the first resource POST, so "the experiment is there" is true for
        # an upload that died after 3 of 400 scans.
        want=$(staged_manifest_files "$session")
        if [ "$want" = "ERR" ]; then
            keep "$session" "manifest_unreadable" "could not determine WHICH files this session should contain (no readable __MANIFEST__.json) — cannot prove it arrived intact" \
                 ",\"objects\":${count},\"age_s\":${age}"
            kept=$((kept + 1)); continue
        fi

        have=$(xnat_files "$session")
        if [ "$have" = "ERR" ]; then
            # Covers: XNAT unreachable, non-200, unparseable body, experiment
            # absent, a row with no Name, a session name that does not
            # decompose. All of it means we do not know, and not knowing
            # means keep.
            keep "$session" "xnat_count_unavailable" "XNAT did not return a usable file list for this session" \
                 ",\"objects\":${count},\"age_s\":${age}"
            kept=$((kept + 1)); continue
        fi

        # SET COMPARISON, not a count.
        #
        # A count says "XNAT holds 400 files"; it does not say they are THESE
        # 400. A partially-overwritten upload, files landed under the wrong
        # scan, or two sessions of equal size would all satisfy a count and
        # fail this. Names come straight from the manifest keys and from
        # XNAT's `Name` field, which are the same strings — verified against
        # the live server.
        #
        # `digest` is compared too, but only where BOTH sides have one: XNAT
        # leaves it empty unless the catalog was built with checksums enabled
        # (it is empty on ours). Where it is populated a mismatch means the
        # bytes differ even though the name matches, which no count or name
        # check could ever catch.
        cmp_out=$(printf '%s\n---\n%s\n' "$want" "$have" | python3 -c '
import sys
raw = sys.stdin.read().split("\n---\n")
if len(raw) != 2:
    print("ERR"); sys.exit()
def parse(block):
    out = {}
    for line in block.strip().splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        out[parts[0]] = parts[1] if len(parts) > 1 else ""
    return out
wantd, haved = parse(raw[0]), parse(raw[1])
if not wantd:
    print("ERR"); sys.exit()
missing = sorted(set(wantd) - set(haved))
mismatched = sorted(
    n for n in wantd
    if n in haved and wantd[n] and haved[n] and wantd[n].lower() != haved[n].lower()
)
print("%d\t%d\t%d\t%d\t%s\t%s" % (
    len(wantd), len(haved), len(missing), len(mismatched),
    ",".join(missing[:3]), ",".join(mismatched[:3])))
' 2>/dev/null) || cmp_out="ERR"

        if [ "$cmp_out" = "ERR" ] || [ -z "$cmp_out" ]; then
            keep "$session" "comparison_failed" "could not compare the staged file list against XNAT" \
                 ",\"objects\":${count},\"age_s\":${age}"
            kept=$((kept + 1)); continue
        fi

        n_want=$(printf '%s' "$cmp_out" | cut -f1)
        n_have=$(printf '%s' "$cmp_out" | cut -f2)
        n_missing=$(printf '%s' "$cmp_out" | cut -f3)
        n_mismatch=$(printf '%s' "$cmp_out" | cut -f4)
        eg_missing=$(printf '%s' "$cmp_out" | cut -f5)
        eg_mismatch=$(printf '%s' "$cmp_out" | cut -f6)

        if [ "${n_missing:-1}" != "0" ]; then
            # The partial-upload case, and now also the wrong-files case.
            keep "$session" "incomplete_in_xnat" "XNAT is missing ${n_missing} of the ${n_want} files this session staged (e.g. ${eg_missing}) — treating it as a partial upload" \
                 ",\"objects\":${count},\"age_s\":${age},\"want\":${n_want},\"have\":${n_have},\"missing\":${n_missing}"
            kept=$((kept + 1)); continue
        fi

        if [ "${n_mismatch:-0}" != "0" ]; then
            # Same names, different bytes. Only reachable where the XNAT
            # catalog carries digests.
            keep "$session" "checksum_mismatch" "${n_mismatch} file(s) present in XNAT with a DIFFERENT checksum (e.g. ${eg_mismatch}) — the names match but the bytes do not" \
                 ",\"objects\":${count},\"age_s\":${age},\"want\":${n_want},\"have\":${n_have},\"mismatched\":${n_mismatch}"
            kept=$((kept + 1)); continue
        fi

        jlog reclaim_confirmed "$session" "XNAT holds every file this session staged, by name" \
            ",\"objects\":${count},\"age_s\":${age},\"want\":${n_want},\"have\":${n_have}"
    fi

    if [ "$DRY_RUN" = "true" ]; then
        jlog reclaim_skipped "$session" "dataPolicy dryRun/disabled — would have removed ${count} object(s)" \
            ",\"objects\":${count},\"age_s\":${age}"
        skipped=$((skipped + 1)); continue
    fi

    if out=$(filer_rm "$session"); then
        jlog reclaim_removed "$session" "removed via filer: ${out}" \
            ",\"objects\":${count},\"age_s\":${age},\"verified\":${VERIFY_XNAT}"
        removed=$((removed + 1)); removed_list="${removed_list}${session}
"
    else
        # The session is confirmed in XNAT but still on disk. Not data loss —
        # the copy that matters is in XNAT — but it will be re-listed,
        # re-uploaded and re-alerted until someone looks.
        jlog reclaim_failed "$session" "filer refused the delete: ${out}" \
            ",\"objects\":${count},\"age_s\":${age}"
    fi
# A heredoc, not `printf ... | while`: a piped while runs in a subshell and
# every counter incremented above would be discarded at the `done`.
done <<EOF
${prefixes}
EOF

# -----------------------------------------------------------------------------
# Verify the entries are actually gone.
# -----------------------------------------------------------------------------
# The entire point of going through the filer is that the DIRECTORY ENTRY
# disappears, and `weed shell`'s exit code does not tell us whether it did.
# One more delimited listing settles it. A survivor means the uploader will
# keep listing it and keep re-alerting, so it is reported as a failure rather
# than left to be rediscovered from the inbox.
if [ -n "$removed_list" ]; then
    if after=$(s3_list_prefixes); then
        while IFS= read -r session; do
            [ -n "$session" ] || continue
            # -F -x: whole-line literal match. A substring or regex match here
            # would report a survivor for `a.b.c` whenever `a.b.c2` exists.
            if printf '%s\n' "$after" | grep -Fxq "$session"; then
                jlog reclaim_failed "$session" "fs.rm -r ran but the prefix is STILL listed in staging — it will be re-processed and re-alerted; check the filer"
            fi
        done <<EOF
${removed_list}
EOF
    else
        jlog reclaim_failed "" "post-removal listing failed — could not verify that the removed prefixes are gone"
    fi
fi

jlog reclaim_finished "" "examined=${examined} removed=${removed} kept=${kept} skipped=${skipped}" \
    ",\"examined\":${examined},\"removed\":${removed},\"kept\":${kept},\"skipped\":${skipped}"
