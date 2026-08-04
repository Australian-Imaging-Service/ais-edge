#!/usr/bin/env bash
# =============================================================================
# S3 staging reclaimer — the ONLY component that deletes from s3://<bucket>/staged
# =============================================================================
# `xnat-ingest upload` has no S3 retention. It rebuilds its work list from a
# live listing of the staging prefix on every --loop pass and never removes
# what it uploaded, so a delivered session is listed again, "uploaded" again,
# and re-fires XNATUploadSuccess every 60s forever. (Observed 2026-07-29: 12
# stale prefixes, ~2 success lines/minute, for two days.) This job closes that
# gap by removing staged sessions AFTER XNAT has been re-queried and has
# confirmed it holds them.
#
# -----------------------------------------------------------------------------
# THE DOCTRINE: THIS SCRIPT DELETES PATIENT DATA. IT IS WRONG TO GUESS.
# -----------------------------------------------------------------------------
# A staged session that is not in XNAT is UNDELIVERED DATA. Every uncertainty —
# a failed listing, a non-200 from XNAT, an unparseable response, a session ID
# that does not decompose, a tool that is missing — resolves to KEEP. There is
# no code path in this file where a delete happens because something could not
# be checked. Keeping too much costs disk; deleting too much costs a scan that
# no longer exists anywhere.
#
# Corollaries, each of which is load-bearing:
#   * An uploader exit code is NOT confirmation. `xnat-ingest upload` logs
#     "Successfully uploaded all files in '<session>'" for an EMPTY prefix.
#     Only a positive answer from the XNAT REST API counts.
#   * Deletion goes through the FILER, never `aws s3 rm`. Measured on
#     SeaweedFS 3.99: `aws s3 rm --recursive` (and `mc rm` before it) removes
#     the OBJECTS but leaves a 0-byte directory ENTRY, which `aws s3 ls` still
#     reports as "PRE <session>/" — and an empty prefix is exactly what makes
#     the uploader log a bogus success every cycle. Switching S3 client does
#     not fix it; only the filer can remove a directory entry.
#     See docs/helm-consolidation-briefing.md, A3.
#   * The filer is reached over its HTTP API:
#         DELETE http://<filer>:8888/buckets/<bucket>/<prefix>/<session>?recursive=true
#     Measured: returns 204 and the directory entry is genuinely gone, where
#     the same session deleted with `aws s3 rm --recursive` still listed as
#     "PRE <session>/" afterwards.
#     This deliberately replaces `kubectl exec ... weed shell`, which is how
#     the hand-run cleanup script did it. Going over HTTP means this job needs
#     no kubectl, no custom image (amazon/aws-cli already ships curl), and — the
#     real prize — NO pods/exec RBAC. A CronJob that can exec into arbitrary
#     pods is a far larger blast radius than one that can call one HTTP verb.
#   * We never decide a deletion from `weed shell` TEXT. weed shell prints its
#     prompt inline ("> FIRST_ENTRY"); an earlier cleanup script filtered
#     those lines out, which made a session that HELD DATA look empty and
#     deleted it. Every decision here comes from the S3 API or from XNAT.
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
#     reclaim_unavailable  pre-flight failed; nothing was examined
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

# -----------------------------------------------------------------------------
# Pre-flight. Every failure below aborts the WHOLE run before a single
# decision is taken, rather than degrading into a run that keeps everything:
# a reclaimer that silently examines nothing looks exactly like a reclaimer
# with nothing to do.
# -----------------------------------------------------------------------------
if [ "$RECLAIM" != "onXnatConfirmed" ]; then
    jlog reclaim_unavailable "" "reclaim=${RECLAIM} is not onXnatConfirmed — refusing to remove anything"
    exit 1
fi

for tool in aws curl date timeout; do
    command -v "$tool" >/dev/null 2>&1 || {
        jlog reclaim_unavailable "" "required tool '${tool}' is not in this image — the reclaimer needs aws-cli (S3 listings) and curl (XNAT REST + the filer delete); nothing was examined and nothing was removed"
        exit 1
    }
done

# Filer reachability. Checked up front so an unreachable filer aborts the run
# rather than surfacing as a per-session removal failure after the XNAT
# confirmations have already been spent.
if ! filer_code=$(timeout "$HTTP_TIMEOUT" curl -sS -o /dev/null -w '%{http_code}' \
        "${FILER_ENDPOINT%/}/buckets/?limit=1" 2>&1); then
    jlog reclaim_unavailable "" "filer at ${FILER_ENDPOINT} is unreachable: ${filer_code}"
    exit 1
fi
case "$filer_code" in
    2*|3*) : ;;
    *) jlog reclaim_unavailable "" "filer at ${FILER_ENDPOINT} answered HTTP ${filer_code} — refusing to run"; exit 1 ;;
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
    jlog reclaim_unavailable "" "dataPolicy.derived.s3Staged.minAge=${MIN_AGE} is not a duration I can parse (expected e.g. 0, 90m, 12h, 1d, 2w) — refusing to run rather than treating it as 0"
    exit 1
fi

if ! err=$(aws s3api head-bucket --bucket "$S3_BUCKET" 2>&1); then
    jlog reclaim_unavailable "" "head-bucket ${S3_BUCKET} failed: ${err}"
    exit 1
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
xnat_get() {
    printf 'user = "%s:%s"\n' "$(curl_esc "${XNAT_USER:-}")" "$(curl_esc "${XNAT_PASS:-}")" \
        | curl "${CURL_OPTS[@]}" -K - "$1" 2>/dev/null
}

if [ "$VERIFY_XNAT" = "true" ]; then
    if [ -z "$XNAT_SERVER" ] || [ -z "${XNAT_USER:-}" ] || [ -z "${XNAT_PASS:-}" ]; then
        jlog reclaim_unavailable "" "verifyAgainstXnat=true but the XNAT credentials Secret gave an empty server/username/password"
        exit 1
    fi
    probe=$(xnat_get "${XNAT_SERVER}/data/projects?format=json")
    code=$(printf '%s' "$probe" | tail -n1)
    if [ "$code" != "200" ]; then
        # Not a data-loss condition — but every session would come back
        # unconfirmed, so the run would be a very expensive no-op.
        jlog reclaim_unavailable "" "XNAT auth probe returned HTTP ${code} — cannot confirm any session, so nothing is eligible; nothing removed"
        exit 1
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

# Session prefixes, exactly as the uploader sees them: one delimited listing of
# staging. This includes 0-byte ghost entries, which is the point.
s3_list_prefixes() {
    local raw
    raw=$(aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "${S3_PREFIX}/" \
            --delimiter / --query 'CommonPrefixes[].Prefix' --output text 2>/dev/null) || return 1
    # No prefixes at all: the CLI prints "None" for a null JMESPath result.
    [ "$raw" = "None" ] && return 0
    printf '%s' "$raw" | tr '\t' '\n' | sed "s#^${S3_PREFIX}/##; s#/\$##" | grep -v '^$'
    return 0
}

s3_object_count() {
    local out
    out=$(aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "${S3_PREFIX}/${1}/" \
            --query 'length(Contents || `[]`)' --output text 2>/dev/null) || { echo ERR; return; }
    numeric_or_err "$out"
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
# Staged prefixes are named by `xnat-ingest assign` as PROJECT.SUBJECT.VISIT
# (docs/components/xnat-ingest.md). We ask XNAT for the experiments of that
# ONE subject in that ONE project — a path-addressed query, so a 404 for a
# missing project or subject is unambiguous — and then require an EXACT match
# on a returned label or ID. A substring match could confirm the wrong
# session, and confirming the wrong session deletes the right one.
#
# Returns 0 only on a positive confirmation. Everything else (any HTTP code
# other than 200, an HTML login page, an empty result, a name that does not
# decompose) returns non-zero and the caller keeps the session.
xnat_has_session() {
    local session="$1" project subject visit body code labels
    # Exactly three dot-separated non-empty fields, or we do not know what we
    # are looking at and must not touch it.
    case "$session" in
        *.*.*.*|*..*|.*|*.) return 1 ;;
        *.*.*) : ;;
        *) return 1 ;;
    esac
    project="${session%%.*}"
    visit="${session##*.}"
    subject="${session#*.}"; subject="${subject%.*}"
    [ -n "$project" ] && [ -n "$subject" ] && [ -n "$visit" ] || return 1

    body=$(xnat_get "${XNAT_SERVER}/data/projects/${project}/subjects/${subject}/experiments?format=json")
    code=$(printf '%s' "$body" | tail -n1)
    [ "$code" = "200" ] || return 1

    # Flat extraction of the label/ID fields only. The response is scoped to
    # one subject already, so an exact string match cannot cross sessions.
    labels=$(printf '%s' "$body" | sed '$d' \
             | grep -o '"\(label\|ID\)":"[^"]*"' | sed 's/^"[^"]*":"//; s/"$//')
    [ -n "$labels" ] || return 1

    # xnat-ingest has named the experiment after the visit, and some sites
    # prefix it with the subject. Both candidates are derived from THIS
    # session's own name, so neither can match a different session.
    while IFS= read -r l; do
        [ "$l" = "$visit" ] && return 0
        [ "$l" = "${subject}_${visit}" ] && return 0
    done <<EOF
$labels
EOF
    return 1
}

# -----------------------------------------------------------------------------
# Removal. The filer, and only the filer.
# -----------------------------------------------------------------------------
# `aws s3 rm --recursive` here would leave the 0-byte directory entry behind
# and RECREATE the bug this job exists to fix. Only the filer can remove a
# directory entry, and its HTTP API does it directly:
#
#     DELETE /buckets/<bucket>/<prefix>/<session>?recursive=true   -> 204
#
# Measured on SeaweedFS 3.99: after this call the entry is genuinely gone from
# both `aws s3 ls` and `weed shell fs.ls`, where the same session deleted with
# `aws s3 rm --recursive` still listed as "PRE <session>/".
#
# Two flags matter. `recursive=true` is what makes it descend into the
# session's scan subdirectories. `ignoreRecursiveError=false` (the default)
# means a partial failure is reported rather than swallowed — the caller
# re-lists staging afterwards and only trusts THAT, but a reported error is
# still better than a silent one.
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
    jlog reclaim_unavailable "" "listing s3://${S3_BUCKET}/${S3_PREFIX}/ failed — nothing examined"
    exit 1
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
        if xnat_has_session "$session"; then
            jlog reclaim_confirmed "$session" "XNAT reports it holds this session" \
                ",\"objects\":${count},\"age_s\":${age}"
        else
            # The overwhelmingly common cause is a session that has not been
            # uploaded yet (XNAT down, credentials, backlog) — undelivered
            # data, which is precisely what must never be deleted.
            keep "$session" "not_confirmed_in_xnat" "XNAT did not positively confirm this session — treating it as undelivered" \
                 ",\"objects\":${count},\"age_s\":${age}"
            kept=$((kept + 1)); continue
        fi
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
