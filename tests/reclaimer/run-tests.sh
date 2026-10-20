#!/usr/bin/env bash
# =============================================================================
# Reclaimer test harness
# =============================================================================
#   tests/reclaimer/run-tests.sh
#
# The reclaimer (charts/edge/files/reclaim-staged.sh) is the only component in
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
# THIS BRANCH HAS NO charts/mgmt. The same script ships as the edge chart's
# terminal-stage reclaimer for upload.mode=direct, and it is byte-identical to
# main's copy, so the cases below apply unchanged.
SCRIPT="$REPO/charts/edge/files/reclaim-staged.sh"
WORK="${TMPDIR:-/tmp}/reclaimer-tests"

PASS=0; FAIL=0; FAILED=()
_R=$'\033[31m'; _G=$'\033[32m'; _B=$'\033[1m'; _O=$'\033[0m'

# XNAT SESSIONS, checked after EVERY case. stub-curl keeps them as the real
# server does. A run logs in once, uses that session for every call and logs
# out, however it ends; any other session stays open on XNAT until it times
# out (the live server showed 83, and later 9, before this check). Skipped when
# the run says it fell back to per-request logins: that fallback is deliberate.
session_leak() {   # <output> <case dir>: prints the leak and returns 0, else 1
    local opened closed
    printf '%s' "$1" | grep -q '"event":"xnat_session_fallback"' && return 1
    opened=$(cat "$2/xnat-sessions.log" 2>/dev/null | grep -c '^SESSION-OPENED')
    closed=$(cat "$2/xnat-sessions.log" 2>/dev/null | grep -c '^SESSION-CLOSED')
    [ "$opened" -gt 1 ] && { echo "the run opened $opened XNAT sessions, not 1"; return 0; }
    # A logout that failed is a leak the run reported itself, not a hidden one.
    printf '%s' "$1" | grep -q '"event":"xnat_session_close_failed"' && return 1
    [ "$opened" != "$closed" ] && { echo "the run left an XNAT session open ($opened opened, $closed closed)"; return 0; }
    return 1
}

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
    elif why=$(session_leak "$out" "$S"); then
        ok=0
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

# =============================================================================
# FILESYSTEM BACKEND (STORAGE=filesystem, tier-1): reclaim-files.py
# =============================================================================
# The decision and the delete are in charts/edge/files/reclaim-files.py. It asks a
# fake XNAT (fake-xnat.py) over real HTTP: the experiment, the file listing and
# one HEAD per file. The lock files are real, and a background process stands in
# for the wrapped writer: it holds a shared lock on .alive (and, for a writer in
# a pass, the pass lock).
#
# The assertion is the disk: what is still there after the run. That fails if the
# helper deletes the wrong thing as well as if it deletes nothing. Each case also
# fails if anything but GET, HEAD or the logout reached XNAT (a reclaimer never
# writes there), and if a run opened more than one XNAT session or left one open:
# XNAT opens a session for each request that logs in and keeps it.

# SOP classes the uploader's rule maps (xnat_resource_label_from_sop_class).
MR=1.2.840.10008.5.1.4.1.1.4      # MR Image Storage: primary, label DICOM
SC=1.2.840.10008.5.1.4.1.1.7      # Secondary Capture Image Storage: label secondary

# <root>/<session>/<scan>/<resource>/{f1..fN}.dcm, 100 bytes each, the manifest
# and the resource metadata the uploader reads its SOP class from.
fs_session() {   # <root> <session> <nfiles> [scan folder] [resource folder] [SOP class|-] [datatype]
    local s="$2" n="$3" d="$1/$2/${4:-1.scan}/${5:-DICOM}" i cks=""
    mkdir -p "$d"
    for i in $(seq 1 "$n"); do
        printf '%0100d' "$i" > "$d/f$i.dcm"
        cks="$cks\"f$i.dcm\":\"abc\","
    done
    printf '{"datatype":"%s","checksums":{%s}}' "${7:-medimage/dicom-series}" "${cks%,}" > "$d/__MANIFEST__.json"
    case "${6:-$MR}" in
        -)     printf '{"Modality":"MR"}' > "$d/__METADATA__.json" ;;          # no SOPClassUID key
        empty) printf '{"SOPClassUID":"","Modality":"MR"}' > "$d/__METADATA__.json" ;;
        none)  : ;;                                                          # no metadata file
        *)     printf '{"SOPClassUID":"%s","Modality":"MR"}' "${6:-$MR}" > "$d/__METADATA__.json" ;;
    esac
    printf '{}' > "$1/$s/__METADATA__.json"
}

# The fake XNAT's answers. As XNAT 1.9 lists them, a row names its resource by a
# numeric id in the URI and in "cat_ID", and by its label in "collection". All
# files of one call are in one resource.
xnat_files() {   # <subject> <expid> <label> <nfiles> [size] [scan id] [resource label] [resource id]
    python3 - "$CASE_DIR/xnat.json" "$@" <<'PY'
import json, sys
path, subj, exp, label, n, *rest = sys.argv[1:]
size, scan, res, rid = (rest + ["100", "1", "DICOM", "101"][len(rest):])[:4]
d = json.load(open(path))
d.setdefault("experiments", {})[f"proj/{subj}"] = [{"ID": exp, "label": label}]
d.setdefault("files", {}).setdefault(exp, []).extend(
    {"URI": f"/data/experiments/{exp}/scans/{scan}/resources/{rid}/files/f{i}.dcm",
     "collection": res, "cat_ID": rid, "Size": size, "digest": ""} for i in range(1, int(n) + 1))
json.dump(d, open(path, "w"))
PY
}
xnat_set() {   # <python statement on the fixture d>
    python3 - "$CASE_DIR/xnat.json" "$1" <<'PY'
import json, sys
path, stmt = sys.argv[1:3]
d = json.load(open(path))
exec(stmt, {"d": d})
json.dump(d, open(path, "w"))
PY
}
U1="/data/experiments/EXP1/scans/1/resources/101/files/f1.dcm"
U2="/data/experiments/EXP1/scans/1/resources/101/files/f2.dcm"

# THE UPLOADER'S LABEL RULE COMES FROM THE PINNED IMAGE. reclaim-files.py loads
# xnat_ingest/helpers/xnat_scan_types.py from the installed xnat-ingest. Here the
# module is copied out of the image the chart runs, onto PYTHONPATH. Without
# docker the filesystem cases are skipped, loudly; CI_REQUIRE_RECLAIMER_IMAGE=1
# makes that a failure.
FS_PYMOD="$WORK/pymod"; FS_SKIP=""
rm -rf "$FS_PYMOD"; mkdir -p "$FS_PYMOD/xnat_ingest/helpers" "$WORK/broken-rule/xnat_ingest/helpers"
: > "$FS_PYMOD/xnat_ingest/__init__.py"; : > "$FS_PYMOD/xnat_ingest/helpers/__init__.py"
: > "$WORK/broken-rule/xnat_ingest/__init__.py"
printf 'raise ImportError("no label rule here")\n' > "$WORK/broken-rule/xnat_ingest/helpers/xnat_scan_types.py"
FS_IMAGE="$(python3 -c "import yaml; i = yaml.safe_load(open('$REPO/charts/edge/values.yaml'))['ingest']['image']; print(i['repository'] + ':' + i['tag'])")"
if ! docker run --rm --entrypoint python3 "$FS_IMAGE" -c 'import importlib.util, os
s = importlib.util.find_spec("xnat_ingest")
print(open(os.path.join(s.submodule_search_locations[0], "helpers", "xnat_scan_types.py")).read())' \
        > "$FS_PYMOD/xnat_ingest/helpers/xnat_scan_types.py" 2>/dev/null \
   || ! grep -q 'def xnat_resource_label_from_sop_class' "$FS_PYMOD/xnat_ingest/helpers/xnat_scan_types.py"; then
    FS_SKIP="cannot copy the label rule out of $FS_IMAGE (docker)"
fi

# A stand-in for the wrapped writer: a shared lock on .alive and, with a second
# path, the pass lock as well (a writer in the middle of a pass).
hold_locks() {
    python3 -c '
import fcntl, os, sys, time
for i, p in enumerate(sys.argv[1:]):
    fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
    fcntl.flock(fd, fcntl.LOCK_SH if i == 0 else fcntl.LOCK_EX)
open(sys.argv[1] + ".held", "w").close()
time.sleep(600)' "$@" &
    HOLDER=$!
    local i; for i in $(seq 50); do [ -e "$1.held" ] && return 0; sleep 0.1; done
}

run_fs_case() {   # <name> <expect-gone yes|no> <expect-event> [env...]
    local name="$1" expect_gone="$2" expect_event="$3"; shift 3
    if [ -n "$FS_SKIP" ]; then
        printf '  SKIP  %-34s %s\n' "$name" "$FS_SKIP"
        [ "${CI_REQUIRE_RECLAIMER_IMAGE:-0}" = "1" ] && { FAIL=$((FAIL+1)); FAILED+=("$name: skipped: $FS_SKIP"); }
        return 0
    fi
    local S="$WORK/$name"
    rm -rf "$S"; mkdir -p "$S/locks"
    CASE_DIR="$S"
    local root="$S/staged"
    mkdir -p "$root"
    printf '{}' > "$S/xnat.json"
    WRITER=yes   # a setup may say no (no wrapped writer) or pass (a writer in a pass)
    "setup_$name" "$root"

    python3 "$HERE/fake-xnat.py" "$S" &
    local xpid=$! i
    for i in $(seq 50); do [ -s "$S/xnat-port" ] && break; sleep 0.1; done
    HOLDER=""
    case "$WRITER" in
        yes)  hold_locks "$S/locks/assigned.alive" ;;
        pass) hold_locks "$S/locks/assigned.alive" "$S/locks/assigned.lock" ;;
    esac

    local out
    out=$(cd "$S" && env -i \
        PATH="$HERE:/usr/bin:/bin:/usr/local/bin" \
        SCENARIO="$S" \
        HOME="$S" \
        STORAGE=filesystem \
        STAGED_ROOT="$root" \
        CLUSTER_LABEL=edge-dev \
        RECLAIM=onXnatConfirmed \
        MIN_AGE=0 \
        VERIFY_XNAT=true \
        DRY_RUN=false \
        XNAT_VERIFY_SSL=false \
        XNAT_SERVER="http://127.0.0.1:$(cat "$S/xnat-port")" \
        XNAT_USER=u XNAT_PASS=p \
        WRITER_LOCK="$S/locks/assigned.lock" \
        WRITER_ALIVE="$S/locks/assigned.alive" \
        LOCK_WAIT=2 \
        PYTHONPATH="$FS_PYMOD" PYTHONDONTWRITEBYTECODE=1 \
        "$@" \
        bash "$SCRIPT" 2>&1)
    kill "$xpid" $HOLDER 2>/dev/null; wait "$xpid" $HOLDER 2>/dev/null
    chmod -R u+w "$S" 2>/dev/null

    printf '%s\n' "$out" > "$S/out.log"

    local gone="no"
    [ -d "$root/$SESS" ] || gone="yes"

    local ok=1 why=""
    # CHECKED FIRST, BEFORE THE EXPECTED EVENT. A run can do the right thing and
    # still be broken afterwards: the armed run that first exercised this backend
    # removed the correct session, then died on `S3_BUCKET: unbound variable` in
    # the post-removal verification and reported reclaim_failed for it. Every
    # assertion below passed, because they only ask whether the expected event is
    # PRESENT. So an unbound variable, or a shell error of any kind, now fails the
    # case on its own. A Python traceback counts as well.
    if printf '%s' "$out" | grep -qE "unbound variable|command not found|: line [0-9]+:|Traceback"; then
        ok=0; why="shell or Python error in an otherwise-passing run: $(printf '%s' "$out" | grep -oE '[^ ]*: line [0-9]+: .*|.*unbound variable|Traceback.*' | head -1)"
    elif [ -s "$S/xnat-requests.log" ] && grep -qvE '^(GET|HEAD) |^DELETE /data/JSESSION$|^SESSION-(OPENED|CLOSED) ' "$S/xnat-requests.log"; then
        ok=0; why="the reclaimer sent XNAT a request that is not GET, HEAD or the logout: $(grep -vE '^(GET|HEAD) |^DELETE /data/JSESSION$|^SESSION-(OPENED|CLOSED) ' "$S/xnat-requests.log" | head -1)"
    # A case that made no request has no log: that counts as 0, not as an error.
    elif [ "$(cat "$S/xnat-requests.log" 2>/dev/null | grep -c '^SESSION-OPENED')" -gt 1 ]; then
        ok=0; why="the reclaimer opened $(cat "$S/xnat-requests.log" 2>/dev/null | grep -c '^SESSION-OPENED') XNAT sessions in one run; XNAT keeps each one"
    elif [ "$(cat "$S/xnat-requests.log" 2>/dev/null | grep -c '^SESSION-OPENED')" != "$(cat "$S/xnat-requests.log" 2>/dev/null | grep -c '^SESSION-CLOSED')" ]; then
        ok=0; why="the reclaimer left an XNAT session open: $(cat "$S/xnat-requests.log" 2>/dev/null | grep -c '^SESSION-OPENED') opened, $(cat "$S/xnat-requests.log" 2>/dev/null | grep -c '^SESSION-CLOSED') closed"
    elif printf '%s' "$out" | grep -q '"event":"reclaim_failed"' && [ "$expect_event" != "reclaim_failed" ]; then
        ok=0; why="reclaim_failed was emitted but not expected"
    elif [ "$gone" != "$expect_gone" ]; then
        ok=0; why="expected session-gone=$expect_gone but got $gone"
    elif ! printf '%s' "$out" | grep -q "\"event\":\"$expect_event\""; then
        ok=0; why="expected event $expect_event; got: $(printf '%s' "$out" | grep -o '"event":"[a-z_]*"' | tr '\n' ' ')"
    elif why=$(session_leak "$out" "$S"); then
        ok=0
    elif declare -F "assert_$name" >/dev/null 2>&1; then
        local extra
        if ! extra=$("assert_$name" "$S/out.log" "$root" 2>&1); then ok=0; why="$extra"; fi
    fi

    if [ "$ok" = "1" ]; then
        printf '  %sPASS%s  %-34s gone=%-3s %s\n' "$_G" "$_O" "$name" "$gone" "$expect_event"
        PASS=$((PASS+1))
    else
        printf '  %sFAIL%s  %-34s %s\n' "$_R" "$_O" "$name" "$why"
        FAIL=$((FAIL+1)); FAILED+=("$name: $why")
        printf '%s\n' "$out" | sed 's/^/          /' | head -12
    fi
}

# Assertion helpers. reason: the reclaim_kept slug. kept_files: these paths still exist.
reason() { grep '"event":"reclaim_kept"' "$1" | grep -q "\"reason\":\"$2\"" || { echo "no reclaim_kept with reason $2"; return 1; }; }
kept_files() {
    local root="$1" f; shift
    for f in "$@"; do [ -e "$root/$f" ] || { echo "$f was removed; it must stay"; return 1; }; done
}
R="$SESS/1.scan/DICOM"

# --- the proof ----------------------------------------------------------------
setup_fs_happy_path()     { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
assert_fs_happy_path()    { grep -q '"event":"reclaim_confirmed"' "$1" || { echo "no reclaim_confirmed before the removal"; return 1; }; }
setup_fs_partial_upload() { fs_session "$1" "$SESS" 400; xnat_files subj EXP1 visit 3; }
assert_fs_partial_upload(){ reason "$1" incomplete_in_xnat && kept_files "$2" "$R/f1.dcm" "$R/f400.dcm" "$R/__MANIFEST__.json"; }
setup_fs_xnat_absent()    { fs_session "$1" "$SESS" 2; }
assert_fs_xnat_absent()   { reason "$1" incomplete_in_xnat && kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
# XNAT holding MORE files than the manifest names puts no local file at risk:
# each local file is proved on its own. The old count check kept this session.
setup_fs_xnat_has_more()  { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 5; }
# A file XNAT still lists but lost (measured on xnat-test: HEAD 404, row listed).
setup_fs_listed_but_lost(){ fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; xnat_set "d['head']={'$U1':{'status':404}}"; }
assert_fs_listed_but_lost(){ reason "$1" incomplete_in_xnat && kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
setup_fs_size_mismatch()  { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; xnat_set "d['head']={'$U2':{'length':99}}"; }
assert_fs_size_mismatch() { reason "$1" size_mismatch && kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
setup_fs_head_401()       { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; xnat_set "d['head']={'$U2':{'status':401}}"; }
setup_fs_head_500()       { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; xnat_set "d['head']={'$U1':{'status':500}}"; }
setup_fs_head_redirect()  { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; xnat_set "d['head']={'$U1':{'status':302,'location':'/login'}}"; }
setup_fs_head_no_length() { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; xnat_set "d['head']={'$U1':{'no_length':True}}"; }
setup_fs_listing_500()    { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; xnat_set "d['status']={'files':500}"; }
# The subject is not in XNAT at lookup (HTTP 404: not uploaded yet): kept as not in
# XNAT, not as a failed check. Any other code on the lookup is a failed check.
setup_fs_lookup_404()     { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; xnat_set "d['status']={'experiments':404}"; }
assert_fs_lookup_404()    { reason "$1" incomplete_in_xnat && kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
setup_fs_lookup_500()     { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; xnat_set "d['status']={'experiments':500}"; }
assert_fs_lookup_500()    { reason "$1" xnat_check_failed && kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
for c in head_401 head_500 head_redirect head_no_length listing_500; do
    eval "assert_fs_$c() { reason \"\$1\" xnat_check_failed && kept_files \"\$2\" \"$R/f1.dcm\" \"$R/f2.dcm\"; }"
done
setup_fs_digest_mismatch(){ fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; xnat_set "d['files']['EXP1'][0]['digest']='zzz'"; }
assert_fs_digest_mismatch(){ reason "$1" digest_mismatch && kept_files "$2" "$R/f1.dcm"; }

# --- the mapping: the uploader's scan and resource, nothing wider --------------
# A same-named, same-size file in ANOTHER resource of the scan is not proof.
GEN=generic/file-set
setup_fs_wrong_resource() { fs_session "$1" "$SESS" 1 1.scan TARGET - "$GEN"; xnat_files subj EXP1 visit 1 100 1 OTHER; }
assert_fs_wrong_resource(){ reason "$1" incomplete_in_xnat && kept_files "$2" "$SESS/1.scan/TARGET/f1.dcm"; }
setup_fs_non_dicom()      { fs_session "$1" "$SESS" 1 1.scan TARGET - "$GEN"; xnat_files subj EXP1 visit 1 100 1 TARGET; }
# Two local resources share a file name; XNAT holds only one of them.
setup_fs_two_resources_one_name() {
    fs_session "$1" "$SESS" 1 1.scan DICOM; fs_session "$1" "$SESS" 1 1.scan OTHER - "$GEN"
    xnat_files subj EXP1 visit 1 100 1 OTHER 102
}
assert_fs_two_resources_one_name() {
    reason "$1" incomplete_in_xnat && kept_files "$2" "$R/f1.dcm" || return 1
    [ ! -e "$2/$SESS/1.scan/OTHER" ] || { echo "OTHER was proved and must be removed"; return 1; }
}
# The ONE label the uploader gives a DICOM series, from its SOP classes: a primary
# class (MR) goes to DICOM, Secondary Capture to secondary. The other label is
# never proof, even with the same name and size.
setup_fs_secondary_label()      { fs_session "$1" "$SESS" 2 1.scan DICOM "$SC"; xnat_files subj EXP1 visit 2 100 1 secondary; }
setup_fs_primary_in_secondary() { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2 100 1 secondary; }
assert_fs_primary_in_secondary(){ reason "$1" incomplete_in_xnat && kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
setup_fs_secondary_in_dicom()   { fs_session "$1" "$SESS" 2 1.scan DICOM "$SC"; xnat_files subj EXP1 visit 2 100 1 DICOM; }
assert_fs_secondary_in_dicom()  { reason "$1" incomplete_in_xnat && kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
# Both labels hold the name: only the expected one (DICOM, for MR) is read.
setup_fs_both_labels()    { fs_session "$1" "$SESS" 1; xnat_files subj EXP1 visit 1 100 1 DICOM 101; xnat_files subj EXP1 visit 1 100 1 secondary 102; }
# No SOPClassUID KEY, or no metadata file: the uploader would read the DICOM
# headers, which the reclaimer does not, so the label is unknown: kept. An
# explicit empty value makes the uploader keep the folder name.
setup_fs_no_sop_key()     { fs_session "$1" "$SESS" 2 1.scan secondary -; xnat_files subj EXP1 visit 2 100 1 secondary; }
assert_fs_no_sop_key()    { reason "$1" unmapped_resource && kept_files "$2" "$SESS/1.scan/secondary/f1.dcm"; }
setup_fs_no_metadata()    { fs_session "$1" "$SESS" 2 1.scan secondary none; xnat_files subj EXP1 visit 2 100 1 secondary; }
assert_fs_no_metadata()   { reason "$1" unmapped_resource && kept_files "$2" "$SESS/1.scan/secondary/f1.dcm"; }
setup_fs_empty_sop()      { fs_session "$1" "$SESS" 2 1.scan DICOM empty; xnat_files subj EXP1 visit 2; }
# A zipped series (the package stage's DICOM-zip): one archive, labelled by its
# folder name like any non-DICOM resource, so it is proved and removed.
setup_fs_dicom_zip()      { fs_session "$1" "$SESS" 1 1.scan DICOM-zip - medimage/dicom-series+zip; xnat_files subj EXP1 visit 1 100 1 DICOM-zip; }
# A single DICOM image: its label comes from its header, so it is not mapped.
setup_fs_dicom_image()    { fs_session "$1" "$SESS" 1 1.scan secondary - medimage/dicom-image; xnat_files subj EXP1 visit 1 100 1 secondary; }
assert_fs_dicom_image()   { reason "$1" unmapped_resource && kept_files "$2" "$SESS/1.scan/secondary/f1.dcm"; }
setup_fs_unknown_dicom_type(){ fs_session "$1" "$SESS" 2 1.scan DICOM "$MR" medimage/dicom-something; xnat_files subj EXP1 visit 2; }
assert_fs_unknown_dicom_type(){ reason "$1" unmapped_resource && kept_files "$2" "$R/f1.dcm"; }
# The rule cannot be loaded: no label, so nothing is mapped.
setup_fs_no_label_rule()  { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
assert_fs_no_label_rule() { reason "$1" unmapped_resource && kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
# One resource's files must be in ONE XNAT resource (one id), not two.
setup_fs_two_resource_ids(){ fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 1 100 1 DICOM 101
    xnat_set "d['files']['EXP1'].append({'URI':'/data/experiments/EXP1/scans/1/resources/103/files/f2.dcm','collection':'DICOM','cat_ID':'103','Size':'100','digest':''})"; }
assert_fs_two_resource_ids(){ reason "$1" xnat_ambiguous && kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
# A series split by modality goes to <id>-<modality>: not mapped, so kept.
setup_fs_split_scan()     { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2 100 1-MR; }
assert_fs_split_scan()    { reason "$1" unmapped_resource && kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
# Nested and escaped names: the resource-relative path, quoted in the URI.
setup_fs_nested_escaped() {
    local d="$1/$R/sub dir"
    mkdir -p "$d"; printf '%0100d' 1 > "$d/a b%+.dcm"
    printf '{"datatype":"medimage/dicom-series","checksums":{"sub dir/a b%%+.dcm":"abc"}}' > "$1/$R/__MANIFEST__.json"
    printf '{"SOPClassUID":"%s"}' "$MR" > "$1/$R/__METADATA__.json"
    printf '{}' > "$1/$SESS/__METADATA__.json"
    xnat_files subj EXP1 visit 0
    xnat_set "d['files']['EXP1'].append({'URI':'/data/experiments/EXP1/scans/1/resources/101/files/sub%20dir/a%20b%25%2B.dcm','collection':'DICOM','cat_ID':'101','Size':'100','digest':''})"
}

# --- per resource: a late series ------------------------------------------------
setup_fs_late_resource()  { fs_session "$1" "$SESS" 2 1.scan; fs_session "$1" "$SESS" 2 2.late; xnat_files subj EXP1 visit 2; }
assert_fs_late_resource() {
    reason "$1" incomplete_in_xnat && kept_files "$2" "$SESS/2.late/DICOM/f1.dcm" "$SESS/__METADATA__.json" || return 1
    [ ! -e "$2/$SESS/1.scan" ] || { echo "1.scan was proved and must be removed"; return 1; }
    grep -q '"event":"reclaim_resource_removed"' "$1" || { echo "no reclaim_resource_removed"; return 1; }
    grep -q '"event":"reclaim_confirmed"' "$1" && { echo "reclaim_confirmed for a session with an unproved series"; return 1; }
    return 0
}

# --- the writer lock --------------------------------------------------------------
setup_fs_writer_not_alive(){ fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; WRITER=no; }
assert_fs_writer_not_alive(){ reason "$1" writer_not_alive && kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
# .alive exists but nobody holds it: a writer without the lock may run.
setup_fs_alive_unheld()   { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; WRITER=no; : > "$CASE_DIR/locks/assigned.alive"; }
assert_fs_alive_unheld()  { reason "$1" writer_not_alive && kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
setup_fs_lock_timeout()   { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; WRITER=pass; }
assert_fs_lock_timeout()  { reason "$1" lock_timeout && kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
# The pass lock cannot be created: a lock ERROR, never read as contention.
setup_fs_lock_error()     { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
assert_fs_lock_error()    { reason "$1" lock_error && kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
# Written during the proof: changed, or a new name. Both keep the resource.
setup_fs_changed_during_check(){ fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; xnat_set "d['on_head']={'$U1':{'append':'$1/$R/f2.dcm'}}"; }
assert_fs_changed_during_check(){ reason "$1" changed_during_check && kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
setup_fs_new_file_during_check(){ fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; xnat_set "d['on_head']={'$U1':{'create':'$1/$R/f3.dcm'}}"; }
assert_fs_new_file_during_check(){ reason "$1" changed_during_check && kept_files "$2" "$R/f1.dcm" "$R/f3.dcm"; }

# --- configuration and leftovers ---------------------------------------------------
setup_fs_verify_disabled(){ fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
assert_fs_verify_disabled(){ reason "$1" verify_disabled && kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
# A delete stopped half way: the manifest (removed last) names files already
# gone. XNAT holds all of them, so the rest goes; if it does not, all stays.
setup_fs_crash_recovery() { fs_session "$1" "$SESS" 3; rm "$1/$R/f1.dcm" "$1/$R/f2.dcm"; xnat_files subj EXP1 visit 3; }
setup_fs_crash_unproved() { fs_session "$1" "$SESS" 3; rm "$1/$R/f1.dcm" "$1/$R/f2.dcm"; xnat_files subj EXP1 visit 3; xnat_set "d['head']={'$U1':{'status':404}}"; }
assert_fs_crash_unproved(){ reason "$1" incomplete_in_xnat && kept_files "$2" "$R/f3.dcm" "$R/__MANIFEST__.json"; }
# An upload batch (.<resource>-upload-*) can hold the only link to unproved
# data, so it is never removed here, and the session stays visible.
setup_fs_upload_batch() {
    fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2
    mkdir -p "$1/$SESS/1.scan/.DICOM-upload-abc123"; ln "$1/$R/f1.dcm" "$1/$SESS/1.scan/.DICOM-upload-abc123/f1.dcm"
}
assert_fs_upload_batch() {
    reason "$1" upload_batch_present && kept_files "$2" "$SESS/1.scan/.DICOM-upload-abc123/f1.dcm" || return 1
    [ ! -e "$2/$R" ] || { echo "the proved resource must be removed"; return 1; }
}
setup_fs_empty_session()  { mkdir -p "$1/$SESS/1.scan"; printf '{}' > "$1/$SESS/__METADATA__.json"; printf '{}' > "$1/$SESS/1.scan/__METADATA__.json"; }
assert_fs_empty_session() { grep '"event":"reclaim_confirmed"' "$1" | grep -q '"empty":true' || { echo "no reclaim_confirmed for the empty session"; return 1; }; }
setup_fs_symlink()        { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; ln -s /etc/hostname "$1/$R/link.dcm"; }
assert_fs_symlink()       { reason "$1" unknown_entry && kept_files "$2" "$R/f1.dcm"; }
setup_fs_helper_fails()   { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; printf 'import sys\nsys.exit(3)\n' > "$CASE_DIR/broken.py"; }
assert_fs_helper_fails()  { kept_files "$2" "$R/f1.dcm" "$R/f2.dcm"; }
setup_fs_lock_paths_unset(){ fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
assert_fs_lock_paths_unset(){ grep '"event":"reclaim_unavailable","session":""' "$1" | grep -q '"reason":"writer_lock_unset"' || { echo "no run-level writer_lock_unset"; return 1; }; }
setup_fs_dry_run()        { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; WRITER=no; }
assert_fs_dry_run()       { kept_files "$2" "$R/f1.dcm" "$R/f2.dcm" && grep -q '"event":"reclaim_confirmed"' "$1" || { echo "a dry run must decide as the armed run does"; return 1; }; }

# __build__ is a stage's half-written tree. It carries no manifest and must never
# be listed.
setup_fs_build_dir_ignored() {
    fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2
    mkdir -p "$1/__build__/1.scan/DICOM"; : > "$1/__build__/1.scan/DICOM/partial.dcm"
}
assert_fs_build_dir_ignored() {
    [ -d "$2/__build__" ] || { echo "__build__ was removed; it must be invisible to the reclaimer"; return 1; }
    grep -q '__build__' "$1" && { echo "__build__ appeared in the run output"; return 1; }
    return 0
}
# A file written after the manifest: named by no manifest, so never proved.
setup_fs_undeclared_file(){ fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; : > "$1/$R/stray.dcm"; }
assert_fs_undeclared_file(){ reason "$1" manifest_incomplete && kept_files "$2" "$R/stray.dcm" "$R/f1.dcm"; }

printf '\n%s== reclaimer decision paths, filesystem backend ==%s\n' "$_B" "$_O"
# XNAT SESSIONS by name. XNAT_VERIFY_SSL=false, as on the test edge, where the
# certificate does not verify: one login, used by every call, and one logout.
setup_fs_one_xnat_session() { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
assert_fs_one_xnat_session() {
    local log="$CASE_DIR/xnat-sessions.log"
    [ "$(grep -c '^SESSION-OPENED' "$log")" = 1 ] && [ "$(grep -c '^SESSION-CLOSED' "$log")" = 1 ] \
        || { echo "want 1 session opened and closed, got: $(tr '\n' ' ' < "$log")"; return 1; }
    ! grep -q '"event":"xnat_session_close_failed"' "$1" || { echo "the logout failed"; return 1; }
}
# The login fails: the run still decides, with a login per request, and says so.
setup_fs_session_fallback() { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; : > "$CASE_DIR/xnat-jsession.fail"; }
assert_fs_session_fallback() { grep -q '"event":"xnat_session_fallback"' "$1" || { echo "no xnat_session_fallback event"; return 1; }; }
# Verification on: no XNAT call may turn it off with -k.
setup_fs_xnat_tls_verified() { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; : > "$CASE_DIR/xnat-cert-trusted"; }
# The logout fails (HTTP 500): the run says so, and its decision is unchanged.
setup_fs_session_close_failed() { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; : > "$CASE_DIR/xnat-logout.fail"; }
assert_fs_session_close_failed() { grep -q '"event":"xnat_session_close_failed"' "$1" || { echo "no xnat_session_close_failed event"; return 1; }; }
assert_fs_xnat_tls_verified() {
    ! grep -qE '/data/.* insecure$' "$CASE_DIR/calls.log" \
        || { echo "an XNAT call used -k with XNAT_VERIFY_SSL=true: $(grep -m1 ' insecure$' "$CASE_DIR/calls.log")"; return 1; }
}

run_fs_case fs_happy_path              yes reclaim_removed
run_fs_case fs_partial_upload          no  reclaim_kept
run_fs_case fs_xnat_absent             no  reclaim_kept
run_fs_case fs_xnat_has_more           yes reclaim_removed
run_fs_case fs_listed_but_lost         no  reclaim_kept
run_fs_case fs_size_mismatch           no  reclaim_kept
run_fs_case fs_head_401                no  reclaim_kept
run_fs_case fs_head_500                no  reclaim_kept
run_fs_case fs_head_redirect           no  reclaim_kept
run_fs_case fs_head_no_length          no  reclaim_kept
run_fs_case fs_listing_500             no  reclaim_kept
run_fs_case fs_lookup_404              no  reclaim_kept
run_fs_case fs_lookup_500              no  reclaim_kept
run_fs_case fs_digest_mismatch         no  reclaim_kept
run_fs_case fs_wrong_resource          no  reclaim_kept
run_fs_case fs_non_dicom               yes reclaim_removed
run_fs_case fs_two_resources_one_name  no  reclaim_kept
run_fs_case fs_secondary_label         yes reclaim_removed
run_fs_case fs_primary_in_secondary    no  reclaim_kept
run_fs_case fs_secondary_in_dicom      no  reclaim_kept
run_fs_case fs_both_labels             yes reclaim_removed
run_fs_case fs_no_sop_key              no  reclaim_kept
run_fs_case fs_no_metadata             no  reclaim_kept
run_fs_case fs_empty_sop               yes reclaim_removed
run_fs_case fs_dicom_zip               yes reclaim_removed
run_fs_case fs_dicom_image             no  reclaim_kept
run_fs_case fs_unknown_dicom_type      no  reclaim_kept
run_fs_case fs_no_label_rule           no  reclaim_kept       PYTHONPATH="$WORK/broken-rule"
run_fs_case fs_two_resource_ids        no  reclaim_kept
run_fs_case fs_split_scan              no  reclaim_kept
run_fs_case fs_nested_escaped          yes reclaim_removed
run_fs_case fs_late_resource           no  reclaim_resource_removed
run_fs_case fs_writer_not_alive        no  reclaim_kept
run_fs_case fs_alive_unheld            no  reclaim_kept
run_fs_case fs_lock_timeout            no  reclaim_kept
run_fs_case fs_lock_error              no  reclaim_kept       WRITER_LOCK=/proc/no-such-dir/assigned.lock
run_fs_case fs_changed_during_check    no  reclaim_kept
run_fs_case fs_new_file_during_check   no  reclaim_kept
run_fs_case fs_verify_disabled         no  reclaim_kept       VERIFY_XNAT=false
run_fs_case fs_crash_recovery          yes reclaim_removed
run_fs_case fs_crash_unproved          no  reclaim_kept
run_fs_case fs_upload_batch            no  reclaim_resource_removed
run_fs_case fs_empty_session           yes reclaim_removed
run_fs_case fs_symlink                 no  reclaim_kept
run_fs_case fs_helper_fails            no  reclaim_failed     FILES_HELPER=broken.py
run_fs_case fs_lock_paths_unset        no  reclaim_unavailable WRITER_LOCK=
run_fs_case fs_dry_run                 no  reclaim_skipped    DRY_RUN=true
run_fs_case fs_build_dir_ignored       yes reclaim_removed
run_fs_case fs_one_xnat_session        yes reclaim_removed
run_fs_case fs_session_fallback        yes reclaim_removed
run_fs_case fs_xnat_tls_verified       yes reclaim_removed      XNAT_VERIFY_SSL=true
run_fs_case fs_session_close_failed    yes reclaim_removed
run_fs_case fs_undeclared_file         no  reclaim_kept

# --- minAge ---------------------------------------------------------------------
# AGE IS FROM ctime: assign hard-links files, so mtime is Orthanc's old write
# time. ctime cannot be set back, so these cases move the clock forward with
# RECLAIM_NOW (read by reclaim-files.py for tests only).
# MIN_AGE IS BASE 10. $(( )) read a leading zero as octal: 010d was 8 days, 08d
# a shell error that removed a session written seconds ago. The seconds are
# asserted too, so skipping for another reason cannot pass.
NOW=$(date +%s)
setup_fs_min_age_blocks()     { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
setup_fs_min_age_010d()       { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
assert_fs_min_age_010d()      { grep -qF 'minAge is 010d (864000s)' "$1" || { echo "010d was not read as 864000s"; return 1; }; }
setup_fs_min_age_08d()        { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
assert_fs_min_age_08d()       { grep -qF 'minAge is 08d (691200s)' "$1" || { echo "08d was not read as 691200s"; return 1; }; }
setup_fs_min_age_10_digits()  { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
setup_fs_min_age_elapsed()    { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
run_fs_case fs_min_age_blocks     no  reclaim_skipped      MIN_AGE=1d
run_fs_case fs_min_age_010d       no  reclaim_skipped      MIN_AGE=010d RECLAIM_NOW=$((NOW + 9*86400))
run_fs_case fs_min_age_08d        no  reclaim_skipped      MIN_AGE=08d
run_fs_case fs_min_age_10_digits  no  reclaim_skipped      MIN_AGE=9999999999s
run_fs_case fs_min_age_elapsed    yes reclaim_removed      MIN_AGE=1d RECLAIM_NOW=$((NOW + 2*86400))

# THE TREE'S OWN minAge. data-policy hands this tree to the CronJob before its
# own age check, so the tree's minAge must reach the CronJob or no deleter reads
# it. The edge chart passes it as TREE_MIN_AGE; the script waits for the LONGER
# of the two and names the key that decided.
setup_fs_tree_min_age_blocks()  { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
assert_fs_tree_min_age_blocks() {
    grep -q 'minAge is 7d (604800s) from dataPolicy.derived.deidentified.minAge' "$1" \
        || { echo "the skip does not name the tree's minAge as the deciding key"; return 1; }
}
setup_fs_tree_min_age_elapsed() { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
setup_fs_tree_min_age_shorter() { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
assert_fs_tree_min_age_shorter() {
    grep -q 'minAge is 1d (86400s) from dataPolicy.derived.stagedReclaimer.minAge' "$1" \
        || { echo "the skip does not name stagedReclaimer.minAge as the deciding key"; return 1; }
}
setup_fs_tree_min_age_bad()     { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
setup_fs_tree_min_age_010d()    { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }

TREE_KEY="TREE_MIN_AGE_KEY=dataPolicy.derived.deidentified.minAge"
run_fs_case fs_tree_min_age_blocks   no  reclaim_skipped      MIN_AGE=1d TREE_MIN_AGE=7d   "$TREE_KEY" RECLAIM_NOW=$((NOW + 3*86400))
run_fs_case fs_tree_min_age_elapsed  yes reclaim_removed      MIN_AGE=1d TREE_MIN_AGE=7d   "$TREE_KEY" RECLAIM_NOW=$((NOW + 8*86400))
run_fs_case fs_tree_min_age_shorter  no  reclaim_skipped      MIN_AGE=1d TREE_MIN_AGE=0    "$TREE_KEY" RECLAIM_NOW=$((NOW + 3*3600))
run_fs_case fs_tree_min_age_bad      no  reclaim_unavailable  MIN_AGE=1d TREE_MIN_AGE=7days "$TREE_KEY"
run_fs_case fs_tree_min_age_010d     no  reclaim_skipped      MIN_AGE=1d TREE_MIN_AGE=010d "$TREE_KEY" RECLAIM_NOW=$((NOW + 9*86400))

# REFUSALS. Each of these must abort the whole run rather than examine anything:
# a reclaimer that cannot trust its own configuration must not delete under it.
# The session is staged normally in every case, so "still there" is a real
# assertion and not an artefact of nothing having been created.
setup_fs_root_unsafe()   { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
setup_fs_root_missing()  { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
setup_fs_bad_storage()   { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }

run_fs_case fs_root_unsafe        no  reclaim_unavailable  STAGED_ROOT=/data
run_fs_case fs_root_missing       no  reclaim_unavailable  STAGED_ROOT=/nonexistent-staged-root
run_fs_case fs_bad_storage        no  reclaim_unavailable  STORAGE=nfs

# MORE THAN 10 DIGITS IS REFUSED, as in the chart.
# 20 digits got past the old ERR check, then `[` errored on it and read as
# old enough: the session was removed. 11 was accepted as 391 years.
# reason is asserted: ReclaimerRunUnavailable's runbook maps it to dataPolicy values.
setup_fs_min_age_11_digits() { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
setup_fs_min_age_20_digits() { fs_session "$1" "$SESS" 2; xnat_files subj EXP1 visit 2; }
minage_refused() {
    grep '"event":"reclaim_unavailable","session":""' "$1" | grep -q '"reason":"minage_unparseable"' \
        || { echo "no run-level reclaim_unavailable carrying reason=minage_unparseable"; return 1; }
}
assert_fs_min_age_11_digits() { minage_refused "$1"; }
assert_fs_min_age_20_digits() { minage_refused "$1"; }

run_fs_case fs_min_age_11_digits  no  reclaim_unavailable  MIN_AGE=12345678901s
run_fs_case fs_min_age_20_digits  no  reclaim_unavailable  MIN_AGE=99999999999999999999s

# A LOCK ERROR IS NEVER CONTENTION. Only EWOULDBLOCK says that a wrapped writer
# holds .alive; any other error must keep the data. The cases above cannot make
# flock() itself fail, so this asks the helper directly, with a closed descriptor.
printf '\n%s== lock errors are not contention ==%s\n' "$_B" "$_O"
if STAGED_ROOT=/nonexistent MIN_AGE_S=0 python3 -B - "$REPO/charts/edge/files/reclaim-files.py" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("reclaim_files", sys.argv[1])
rf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rf)
try:
    fd = os.open("/dev/null", os.O_RDONLY)
    os.close(fd)   # a closed descriptor: EBADF, a real OS error
    rf.WriterLock.try_lock(fd, "closed-fd")
except rf.Keep as k:
    sys.exit(0 if k.reason == "lock_error" else 1)
sys.exit(1)
PY
then
    printf '  %sPASS%s  %-34s %s\n' "$_G" "$_O" "fs_flock_error_is_not_contention" "lock_error"; PASS=$((PASS+1))
else
    printf '  %sFAIL%s  %-34s %s\n' "$_R" "$_O" "fs_flock_error_is_not_contention" "a flock error was read as contention"
    FAIL=$((FAIL+1)); FAILED+=("fs_flock_error_is_not_contention")
fi

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
# Shared-connection controls exercise fresh per-session reads and auth expiry.
python3 "$HERE/test-batch.py" || exit 1
exit 0
