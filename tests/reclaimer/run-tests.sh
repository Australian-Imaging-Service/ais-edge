#!/usr/bin/env bash
# =============================================================================
# Reclaimer test harness
# =============================================================================
#   tests/reclaimer/run-tests.sh
#
# The reclaimer (charts/mgmt/files/reclaim-staged.sh) is the only component in
# either chart that deletes patient data. Everything else can be wrong and
# cost you time; this one can be wrong and cost you a scan that exists nowhere
# else.
#
# So it is tested by ASSERTING ON THE DELETES, not on the log text. Each case
# declares whether the session should have been removed, and the harness
# checks what the stubbed filer was actually asked to delete. A run that logs
# `reclaim_kept` and issues a DELETE anyway would pass a log-only test and
# fail this one.
#
# `aws` and `curl` are stubbed and driven by files in a per-case scenario
# directory, so a test is data. The stubs FAIL by default for anything a case
# does not configure — a stub that invented a plausible success would test the
# opposite of the property we care about.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/charts/mgmt/files/reclaim-staged.sh"
WORK="${TMPDIR:-/tmp}/reclaimer-tests"

PASS=0; FAIL=0; FAILED=()
_R=$'\033[31m'; _G=$'\033[32m'; _B=$'\033[1m'; _O=$'\033[0m'

# run_case <name> <expect_deleted: yes|no> <expect_event> [env assignments...]
#
# A case may also define `assert_<name>`, called with the path to the captured
# output. It prints why it is unhappy and returns non-zero. That exists because
# `deleted` plus one event name cannot express the property the pre-flight
# cases are about: not "which event" but "which SESSIONS were named, and which
# events were deliberately NOT emitted".
run_case() {
    local name="$1" expect_del="$2" expect_event="$3"; shift 3
    local S="$WORK/$name"
    rm -rf "$S"; mkdir -p "$S"
    CASE_DIR="$S"
    "setup_$name"

    local out
    out=$(cd "$S" && env -i \
        PATH="$HERE:/usr/bin:/bin:/usr/local/bin" \
        SCENARIO="$S" \
        HOME="$S" \
        S3_BUCKET=ingest-edge-dev \
        CLUSTER_LABEL=edge-dev \
        FILER_ENDPOINT=http://filer:8888 \
        S3_PREFIX=staged \
        RECLAIM=onXnatConfirmed \
        MIN_AGE=0 \
        VERIFY_XNAT=true \
        DRY_RUN=false \
        XNAT_VERIFY_SSL=false \
        XNAT_SERVER=https://xnat.example.org \
        XNAT_USER=u XNAT_PASS=p \
        AWS_ENDPOINT_URL=http://s3:8333 \
        AWS_DEFAULT_REGION=us-east-1 \
        "$@" \
        bash "$SCRIPT" 2>&1)

    printf '%s\n' "$out" > "$S/out.log"

    local deleted="no"
    [ -s "$S/deletes.log" ] && deleted="yes"

    local ok=1 why=""
    if [ "$deleted" != "$expect_del" ]; then
        ok=0; why="expected deleted=$expect_del but got $deleted"
        [ -s "$S/deletes.log" ] && why="$why (deleted: $(tr '\n' ' ' < "$S/deletes.log"))"
    elif ! printf '%s' "$out" | grep -q "\"event\":\"$expect_event\""; then
        ok=0; why="expected event $expect_event; got: $(printf '%s' "$out" | grep -o '"event":"[a-z_]*"' | tr '\n' ' ')"
    elif declare -F "assert_$name" >/dev/null 2>&1; then
        local extra
        if ! extra=$("assert_$name" "$S/out.log" 2>&1); then
            ok=0; why="$extra"
        fi
    fi

    if [ "$ok" = "1" ]; then
        printf '  %sPASS%s  %-34s deleted=%-3s %s\n' "$_G" "$_O" "$name" "$deleted" "$expect_event"
        PASS=$((PASS+1))
    else
        printf '  %sFAIL%s  %-34s %s\n' "$_R" "$_O" "$name" "$why"
        FAIL=$((FAIL+1)); FAILED+=("$name: $why")
        printf '%s\n' "$out" | sed 's/^/          /' | head -12
    fi
}

# --- fixture helpers ---------------------------------------------------------
prefixes() { printf '%s\n' "$*" | tr ' ' '\t' > "$CASE_DIR/list-prefixes.json.raw"
             printf '%s' "$(cat "$CASE_DIR/list-prefixes.json.raw")" > "$CASE_DIR/list-prefixes.json"; }

# One object plus one manifest, timestamped long ago so minAge never blocks.
session_with() {   # <session> <nfiles>
    local s="$1" n="$2" items="" i
    for i in $(seq 1 "$n"); do
        items="$items{\"Key\":\"staged/$s/scan/DICOM/f$i.dcm\",\"Size\":100,\"LastModified\":\"2020-01-01T00:00:00+00:00\"},"
    done
    items="$items{\"Key\":\"staged/$s/scan/DICOM/__MANIFEST__.json\",\"Size\":42,\"LastModified\":\"2020-01-01T00:00:00+00:00\"}"
    printf '{"Contents":[%s]}' "$items" > "$CASE_DIR/objects.$s.json"
    local cks="" i2
    for i2 in $(seq 1 "$n"); do
        cks="$cks\"f$i2.dcm\":\"abc\","
    done
    cks="${cks%,}"
    printf '{"datatype":"medimage/dicom-series","checksums":{%s}}' "$cks" \
        > "$CASE_DIR/get.staged_${s}_scan_DICOM___MANIFEST__.json"
}

# RECORDED SHAPES. The real server answers every file listing with an empty
# Result, so what XNAT can tell us is the per-resource file_count and file_size,
# and both arrive as STRINGS. Fixtures keep them strings for that reason.
xnat_has() {   # <subject> <expid> <label> <nfiles> [total-bytes] [scan-id]
    local sid="${6:-1}" bytes="${5:-$(( $4 * 100 ))}"
    printf '{"ResultSet":{"Result":[{"ID":"%s","label":"%s"}]}}' "$2" "$3" \
        > "$CASE_DIR/xnat-exp.$1.json"
    printf '{"ResultSet":{"Result":[{"ID":"%s","type":"synthetic"}]}}' "$sid" \
        > "$CASE_DIR/xnat-scans.$2.json"
    printf '{"ResultSet":{"Result":[{"label":"DICOM","file_count":"%s","file_size":"%s"}]}}' "$4" "$bytes" \
        > "$CASE_DIR/xnat-res.$2.${sid}.json"
}

# XNAT resolved the experiment but has not built its stats: file_count arrives
# empty. That must read as "cannot check", never as zero.
xnat_stats_unbuilt() {   # <subject> <expid> <label>
    printf '{"ResultSet":{"Result":[{"ID":"%s","label":"%s"}]}}' "$2" "$3" \
        > "$CASE_DIR/xnat-exp.$1.json"
    printf '{"ResultSet":{"Result":[{"ID":"1","type":"synthetic"}]}}' \
        > "$CASE_DIR/xnat-scans.$2.json"
    printf '{"ResultSet":{"Result":[{"label":"DICOM","file_count":"","file_size":""}]}}' \
        > "$CASE_DIR/xnat-res.$2.1.json"
}

SESS="proj.subj.visit"

# =============================================================================
# Cases. `deleted` is the assertion that matters.
# =============================================================================

setup_happy_path() { prefixes "staged/$SESS/"; session_with "$SESS" 2; xnat_has subj EXP1 visit 2; }
setup_xnat_has_more() { prefixes "staged/$SESS/"; session_with "$SESS" 2; xnat_has subj EXP1 visit 5; }

# THE ONE THAT MATTERS: partial upload. XNAT created the experiment on the
# first resource POST, so it EXISTS — but holds fewer files than were staged.
setup_partial_upload() { prefixes "staged/$SESS/"; session_with "$SESS" 400; xnat_has subj EXP1 visit 3; }

setup_xnat_absent()      { prefixes "staged/$SESS/"; session_with "$SESS" 2; }

# THE ACCEPTED GAP, asserted so it is visible rather than assumed. XNAT holds
# the right number of files and the right total bytes, but they are different
# files. Verification is count-and-bytes because no listing endpoint on the real
# server returns names (measured 2026-09-01), so this session IS confirmed. A
# swap that preserves both count and total length is not a delivery failure; it
# is a substitution. If XNAT ever serves names again, tighten this and flip the
# expectation back.
setup_same_count_different_files() { prefixes "staged/$SESS/"; session_with "$SESS" 3
                                     xnat_has subj EXP1 visit 3; }

# One of three missing: the count differs, so it is kept.
setup_one_file_missing()  { prefixes "staged/$SESS/"; session_with "$SESS" 3
                            xnat_has subj EXP1 visit 2; }

# Right count, WRONG total bytes — a file was truncated or replaced by a
# shorter one. The count alone would have confirmed this.
setup_size_mismatch()     { prefixes "staged/$SESS/"; session_with "$SESS" 2
                            xnat_has subj EXP1 visit 2 199; }

# Right count and right bytes — must remove.
setup_size_match()        { prefixes "staged/$SESS/"; session_with "$SESS" 2
                            xnat_has subj EXP1 visit 2 200; }

# XNAT resolved the session but has not built its stats. file_count arrives
# empty, which must be "cannot check", never zero. This is the exact shape that
# left the old probe unable to confirm anything for weeks without saying so.
setup_xnat_stats_unbuilt() { prefixes "staged/$SESS/"; session_with "$SESS" 2
                             xnat_stats_unbuilt subj EXP1 visit; }

# Objects staged under a resource directory with no manifest beside them. They
# were never declared, so they were never compared, and confirming would delete
# them unchecked.
setup_undeclared_objects() { prefixes "staged/$SESS/"; session_with "$SESS" 2
    python3 - "$CASE_DIR/objects.$SESS.json" "$SESS" <<'PYEOF'
import json, sys
p, sess = sys.argv[1], sys.argv[2]
d = json.load(open(p))
for i in range(1, 300):
    d["Contents"].append({"Key": "staged/%s/scan2/DICOM/g%d.dcm" % (sess, i),
                          "Size": 100, "LastModified": "2020-01-01T00:00:00+00:00"})
json.dump(d, open(p, "w"))
PYEOF
    xnat_has subj EXP1 visit 2; }

setup_xnat_500()         { prefixes "staged/$SESS/"; session_with "$SESS" 2; : > "$CASE_DIR/xnat-exp.subj.fail"; }
setup_xnat_res_500()     { prefixes "staged/$SESS/"; session_with "$SESS" 2; xnat_has subj EXP1 visit 2; : > "$CASE_DIR/xnat-res.EXP1.1.fail"; }
setup_no_manifest()      { prefixes "staged/$SESS/"
                           printf '{"Contents":[{"Key":"staged/%s/scan/DICOM/f1.dcm","LastModified":"2020-01-01T00:00:00+00:00"}]}' "$SESS" \
                             > "$CASE_DIR/objects.$SESS.json"
                           xnat_has subj EXP1 visit 1; }
setup_manifest_unreadable() { prefixes "staged/$SESS/"; session_with "$SESS" 2
                           rm -f "$CASE_DIR/get.staged_${SESS}_scan_DICOM___MANIFEST__.json"
                           : > "$CASE_DIR/getfail.staged_${SESS}_scan_DICOM___MANIFEST__.json"
                           xnat_has subj EXP1 visit 2; }
setup_listing_fail()     { prefixes "staged/$SESS/"; : > "$CASE_DIR/objects.$SESS.fail"; }
setup_unsafe_name()      { prefixes 'staged/evil; rm -rf ..$/'; }
setup_unsafe_dotdot()    { prefixes 'staged/../etc/'; }

# Empty prefix: first sighting must DEFER, second may remove.
setup_empty_first_run()  { prefixes "staged/$SESS/"; printf '{"Contents":[]}' > "$CASE_DIR/objects.$SESS.json"; }
setup_empty_second_run() { prefixes "staged/$SESS/"; printf '{"Contents":[]}' > "$CASE_DIR/objects.$SESS.json"
                           : > "$CASE_DIR/marker.$SESS"; }
setup_empty_but_multipart() { prefixes "staged/$SESS/"; printf '{"Contents":[]}' > "$CASE_DIR/objects.$SESS.json"
                           : > "$CASE_DIR/marker.$SESS"
                           printf '{"Uploads":[{"Key":"x"}]}' > "$CASE_DIR/multipart.$SESS.json"; }
setup_empty_multipart_err() { prefixes "staged/$SESS/"; printf '{"Contents":[]}' > "$CASE_DIR/objects.$SESS.json"
                           : > "$CASE_DIR/marker.$SESS"
                           : > "$CASE_DIR/multipart.$SESS.fail"; }

setup_filer_down()       { prefixes "staged/$SESS/"; session_with "$SESS" 2; xnat_has subj EXP1 visit 2
                           : > "$CASE_DIR/filer-down.fail"; }
setup_headbucket_fail()  { prefixes "staged/$SESS/"; : > "$CASE_DIR/head-bucket.fail"; }
setup_xnat_auth_fail()   { prefixes "staged/$SESS/"; : > "$CASE_DIR/xnat-auth.fail"; }
setup_list_prefixes_fail() { : > "$CASE_DIR/list-prefixes.fail"; }
setup_bad_minage()       { prefixes "staged/$SESS/"; session_with "$SESS" 2; xnat_has subj EXP1 visit 2; }
setup_bad_maxremovals()  { prefixes "staged/$SESS/"; session_with "$SESS" 2; xnat_has subj EXP1 visit 2; }
setup_dry_run()          { prefixes "staged/$SESS/"; session_with "$SESS" 2; xnat_has subj EXP1 visit 2; }
setup_wrong_reclaim()    { prefixes "staged/$SESS/"; }
setup_filer_refuses()    { prefixes "staged/$SESS/"; session_with "$SESS" 2; xnat_has subj EXP1 visit 2
                           : > "$CASE_DIR/filer-delete.fail"; }
setup_state_dir_skipped() { prefixes "staged/.reclaim-state/ staged/$SESS/"
                            session_with "$SESS" 2; xnat_has subj EXP1 visit 2; }

# =============================================================================
# Silence cases: a run that COULD NOT DECIDE vs a run that decided there was
# nothing to do.
# =============================================================================
# Every case above asserts on deletes. These three assert on the opposite —
# what the run SAID — because the defect they pin down produced no delete and
# no error, only silence.
#
# The reclaimer aborted its pre-flight on 2026-08-05T18:17:11Z and again on
# 2026-08-06T01:17:11Z (XNAT auth probe, HTTP 000). Each run logged one
# reclaim_unavailable with session="" and exited, and nothing alerted.
# SessionStagedNotConfirmedInXNAT builds its "staged" half from
# `event=~"reclaim_.*" | session != ""`, so those lines contributed nothing to
# it. Two isolated aborts were absorbed by that alert's 24h count window — the
# case that is NOT absorbed, and that the fan-out asserted below exists for, is
# a pre-flight that stays broken across a whole window.
#
# `deleted=no` was already true of that run, and always will be — which is why
# it needed an assertion of a different kind.

# grep on the event AND the session together. "a reclaim_unavailable was
# logged" and "a reclaim_unavailable was logged FOR THIS SESSION" are different
# claims, and only the second is what the alert consumes. jlog emits `event`
# immediately before `session`, so they are adjacent.
ev_for() { grep -q "\"event\":\"$2\",\"session\":\"$3\"" "$1"; }

# Pre-flight fails, two sessions are staged: both must be named.
setup_preflight_xnat_fanout() { prefixes "staged/$SESS/ staged/proj.subj2.visit/"
                                : > "$CASE_DIR/xnat-auth.fail"; }
assert_preflight_xnat_fanout() {
    local log="$1" why="" s
    grep '"event":"reclaim_unavailable","session":""' "$log" | grep -q '"reason":"xnat_probe_failed"' \
        || why="$why no run-level reclaim_unavailable carrying reason=xnat_probe_failed (ReclaimerRunUnavailable keys on it);"
    for s in "$SESS" proj.subj2.visit; do
        ev_for "$log" reclaim_unavailable "$s" \
            || why="$why no per-session reclaim_unavailable for $s — the staged half of SessionStagedNotConfirmedInXNAT would see nothing for it;"
    done
    grep -q '"event":"reclaim_finished"' "$log" \
        && why="$why logged reclaim_finished on an aborted run — that is what a nothing-to-do run logs, and the two must stay distinguishable;"
    grep -q '"event":"reclaim_confirmed"' "$log" \
        && why="$why logged reclaim_confirmed without a positive answer from XNAT;"
    [ -z "$why" ] || { printf '%s' "$why"; return 1; }
}

# The other side of the invariant: a healthy run over empty staging must NOT
# look like an aborted one. `None` is what the real CLI prints for a null
# JMESPath result, so this is also the only case that walks that branch.
setup_nothing_to_do() { printf 'None' > "$CASE_DIR/list-prefixes.json"; }
assert_nothing_to_do() {
    local log="$1" why=""
    grep -q '"examined":0' "$log" \
        || why="$why reclaim_finished did not report examined=0;"
    grep -q '"event":"reclaim_unavailable"' "$log" \
        && why="$why a healthy run over empty staging logged reclaim_unavailable — that is the abort signal and it would raise ReclaimerRunUnavailable;"
    [ -z "$why" ] || { printf '%s' "$why"; return 1; }
}

# The fan-out is BEST-EFFORT. When the bucket itself is what is broken there is
# nothing to enumerate, and the run must degrade to the run-level line rather
# than hang, retry forever, or invent session names.
setup_preflight_no_listing() { prefixes "staged/$SESS/"
                               : > "$CASE_DIR/head-bucket.fail"
                               : > "$CASE_DIR/list-prefixes.fail"; }
assert_preflight_no_listing() {
    local log="$1" why=""
    grep '"event":"reclaim_unavailable","session":""' "$log" | grep -q '"reason":"bucket_unreachable"' \
        || why="$why no run-level reclaim_unavailable carrying reason=bucket_unreachable;"
    ev_for "$log" reclaim_unavailable "$SESS" \
        && why="$why named a session it could not have listed;"
    grep -q '"event":"reclaim_finished"' "$log" \
        && why="$why logged reclaim_finished on an aborted run;"
    [ -z "$why" ] || { printf '%s' "$why"; return 1; }
}

printf '\n%s== reclaimer decision paths ==%s\n' "$_B" "$_O"
run_case happy_path            yes reclaim_removed
run_case xnat_has_more         no  reclaim_kept
run_case partial_upload        no  reclaim_kept
run_case xnat_absent           no  reclaim_kept
run_case same_count_different_files yes reclaim_removed
run_case one_file_missing      no  reclaim_kept
run_case size_mismatch         no  reclaim_kept
run_case size_match            yes reclaim_removed
run_case xnat_stats_unbuilt    no  reclaim_kept
run_case undeclared_objects    no  reclaim_kept
run_case xnat_500              no  reclaim_kept
run_case xnat_res_500          no  reclaim_kept
run_case no_manifest           no  reclaim_kept
run_case manifest_unreadable   no  reclaim_kept
run_case listing_fail          no  reclaim_kept
run_case unsafe_name           no  reclaim_kept
run_case unsafe_dotdot         no  reclaim_kept
run_case empty_first_run       no  reclaim_skipped
run_case empty_second_run      yes reclaim_removed
run_case empty_but_multipart   no  reclaim_kept
run_case empty_multipart_err   no  reclaim_kept
run_case filer_down            no  reclaim_unavailable
run_case headbucket_fail       no  reclaim_unavailable
run_case xnat_auth_fail        no  reclaim_unavailable
run_case list_prefixes_fail    no  reclaim_unavailable
run_case bad_minage            no  reclaim_unavailable MIN_AGE=notaduration
run_case bad_maxremovals       no  reclaim_unavailable MAX_REMOVALS=unlimited
run_case dry_run               no  reclaim_skipped     DRY_RUN=true
run_case wrong_reclaim         no  reclaim_unavailable RECLAIM=never
run_case filer_refuses         no  reclaim_failed
run_case state_dir_skipped     yes reclaim_removed

printf '\n%s== could-not-decide vs nothing-to-do ==%s\n' "$_B" "$_O"
run_case preflight_xnat_fanout no  reclaim_unavailable
run_case nothing_to_do         no  reclaim_finished
run_case preflight_no_listing  no  reclaim_unavailable

printf '\n%sreclaimer: %d passed, %d failed%s\n' "$_B" "$PASS" "$FAIL" "$_O"
if [ "$FAIL" -gt 0 ]; then
    printf '%sFAILURES:%s\n' "$_R" "$_O"
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
fi
exit 0
