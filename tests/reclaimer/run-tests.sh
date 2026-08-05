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

    local deleted="no"
    [ -s "$S/deletes.log" ] && deleted="yes"

    local ok=1 why=""
    if [ "$deleted" != "$expect_del" ]; then
        ok=0; why="expected deleted=$expect_del but got $deleted"
        [ -s "$S/deletes.log" ] && why="$why (deleted: $(tr '\n' ' ' < "$S/deletes.log"))"
    elif ! printf '%s' "$out" | grep -q "\"event\":\"$expect_event\""; then
        ok=0; why="expected event $expect_event; got: $(printf '%s' "$out" | grep -o '"event":"[a-z_]*"' | tr '\n' ' ')"
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
        items="$items{\"Key\":\"staged/$s/scan/DICOM/f$i.dcm\",\"LastModified\":\"2020-01-01T00:00:00+00:00\"},"
    done
    items="$items{\"Key\":\"staged/$s/scan/DICOM/__MANIFEST__.json\",\"LastModified\":\"2020-01-01T00:00:00+00:00\"}"
    printf '{"Contents":[%s]}' "$items" > "$CASE_DIR/objects.$s.json"
    local cks="" i2
    for i2 in $(seq 1 "$n"); do
        cks="$cks\"f$i2.dcm\":\"abc\","
    done
    cks="${cks%,}"
    printf '{"datatype":"medimage/dicom-series","checksums":{%s}}' "$cks" \
        > "$CASE_DIR/get.staged_${s}_scan_DICOM___MANIFEST__.json"
}

xnat_has() {   # <subject> <expid> <label> <nfiles> [name-prefix] [digest]
    printf '{"ResultSet":{"Result":[{"ID":"%s","label":"%s"}]}}' "$2" "$3" \
        > "$CASE_DIR/xnat-exp.$1.json"
    local rows="" i pfx="${5:-f}" dig="${6:-}"
    for i in $(seq 1 "$4"); do
        rows="$rows{\"Name\":\"${pfx}$i.dcm\",\"digest\":\"${dig}\"},"
    done
    rows="${rows%,}"
    printf '{"ResultSet":{"Result":[%s]}}' "$rows" > "$CASE_DIR/xnat-files.$2.json"
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

# THE CASE A COUNT CANNOT CATCH: XNAT holds the right NUMBER of files, but
# they are different files. A count comparison would confirm and delete.
setup_right_count_wrong_files() { prefixes "staged/$SESS/"; session_with "$SESS" 3
                                  xnat_has subj EXP1 visit 3 other; }

# One of three missing, the other two present — a count would say 2 != 3 and
# also keep, but this proves the MISSING NAME is what is reported.
setup_one_file_missing()  { prefixes "staged/$SESS/"; session_with "$SESS" 3
                            xnat_has subj EXP1 visit 2; }

# Names match, digests differ. Only reachable where the XNAT catalog carries
# checksums; ours does not, so this proves the path works for sites that do.
setup_checksum_mismatch() { prefixes "staged/$SESS/"; session_with "$SESS" 2
                            xnat_has subj EXP1 visit 2 f deadbeef; }

# Names match and digests match — must still remove.
setup_checksum_match()    { prefixes "staged/$SESS/"; session_with "$SESS" 2
                            xnat_has subj EXP1 visit 2 f abc; }
setup_xnat_500()         { prefixes "staged/$SESS/"; session_with "$SESS" 2; : > "$CASE_DIR/xnat-exp.subj.fail"; }
setup_xnat_files_500()   { prefixes "staged/$SESS/"; session_with "$SESS" 2; xnat_has subj EXP1 visit 2; : > "$CASE_DIR/xnat-files.EXP1.fail"; }
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
setup_dry_run()          { prefixes "staged/$SESS/"; session_with "$SESS" 2; xnat_has subj EXP1 visit 2; }
setup_wrong_reclaim()    { prefixes "staged/$SESS/"; }
setup_filer_refuses()    { prefixes "staged/$SESS/"; session_with "$SESS" 2; xnat_has subj EXP1 visit 2
                           : > "$CASE_DIR/filer-delete.fail"; }
setup_state_dir_skipped() { prefixes "staged/.reclaim-state/ staged/$SESS/"
                            session_with "$SESS" 2; xnat_has subj EXP1 visit 2; }

printf '\n%s== reclaimer decision paths ==%s\n' "$_B" "$_O"
run_case happy_path            yes reclaim_removed
run_case xnat_has_more         yes reclaim_removed
run_case partial_upload        no  reclaim_kept
run_case xnat_absent           no  reclaim_kept
run_case right_count_wrong_files no reclaim_kept
run_case one_file_missing      no  reclaim_kept
run_case checksum_mismatch     no  reclaim_kept
run_case checksum_match        yes reclaim_removed
run_case xnat_500              no  reclaim_kept
run_case xnat_files_500        no  reclaim_kept
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
run_case dry_run               no  reclaim_skipped     DRY_RUN=true
run_case wrong_reclaim         no  reclaim_unavailable RECLAIM=never
run_case filer_refuses         no  reclaim_failed
run_case state_dir_skipped     yes reclaim_removed

printf '\n%sreclaimer: %d passed, %d failed%s\n' "$_B" "$PASS" "$FAIL" "$_O"
if [ "$FAIL" -gt 0 ]; then
    printf '%sFAILURES:%s\n' "$_R" "$_O"
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
fi
exit 0
