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
# Every case runs under `env -i`, with this PATH. It starts with the directory of the
# python3 this suite was started with: on a CI runner the pinned boto3 lives in the
# setup-python interpreter, not in /usr/bin/python3, and the helper must run with it.
CASE_PATH="$(dirname "$(command -v python3)"):/usr/bin:/bin:/usr/local/bin"
REPO="$(cd "$HERE/../.." && pwd)"
# The same script ships in charts/edge as the terminal-stage reclaimer for
# upload.mode=direct; scripts/ci/shared-files.sh keeps the two copies identical.
SCRIPT="$REPO/charts/mgmt/files/reclaim-staged.sh"
# The filesystem cases run the edge copy: its folder holds reclaim-files.py, the
# helper that backend needs; the mgmt reclaimer is S3 only and ships no helper.
FS_SCRIPT="$REPO/charts/edge/files/reclaim-staged.sh"
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

SESS="proj.subj.visit"

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
        PATH="$HERE:$CASE_PATH" \
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
        bash "$FS_SCRIPT" 2>&1)
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

# The skip line carries the parsed number. Assert it, not only the skip.
minage_read_as() {   # <log> <minAge> <seconds>
    grep -qF "minAge is $2 ($3s)" "$1" && return 0
    printf 'minAge %s should read as %ss; the run said: %s' "$2" "$3" \
        "$(grep -o 'minAge is [^"]*' "$1" | head -1)"
    return 1
}

# =============================================================================
# S3 BACKEND (STORAGE=s3, the mgmt reclaimer)
# =============================================================================
# The same helper over a session prefix. The objects come from fake-s3.py (real
# HTTP; boto3 in the helper), the XNAT answers from fake-xnat.py, and the bucket
# attributes the gate reads from fake-filer.py. The shell's own XNAT calls (the
# login, the probe, the logout) go to fake-xnat.py too, with the real curl: this
# runner puts no stub on the PATH. A delete is a DeleteObject with If-Match, in
# s3-requests.log; "gone" means no object of the session is left in s3.json.
# Every case fails on a DELETE of a folder key, a DELETE without If-Match, a
# request to S3 that is not GET, HEAD or DELETE, or an XNAT session left open.

S3B=ingest-edge-dev
s3_put() {   # <key> <size> [body]: one object; the ETag is the MD5 of the body
    python3 - "$CASE_DIR/s3.json" "$@" <<'PY'
import hashlib, json, os, sys
path, key, size, *rest = sys.argv[1:]
body = rest[0] if rest else ("x" * int(size))
d = json.load(open(path)) if os.path.exists(path) else {"objects": {}}
d["objects"][key] = {"size": len(body.encode()), "etag": hashlib.md5(body.encode()).hexdigest(),
                     "modified": "2020-01-01T00:00:00.000Z", "body": body}
json.dump(d, open(path, "w"))
PY
}
s3_set() {   # <python statement on the fixture d>
    python3 - "$CASE_DIR/s3.json" "$1" <<'PY'
import json, sys
path, stmt = sys.argv[1:3]
d = json.load(open(path))
exec(stmt, {"d": d})
json.dump(d, open(path, "w"))
PY
}
# staged/<session>/<scan>/<resource>/{f1..fN}.dcm, the manifest, the resource
# metadata (the SOP class) and the session metadata, as the edge copies them.
s3_session() {   # <session> <nfiles> [scan folder] [resource folder] [SOP class|-|none] [datatype]
    local s="$1" n="$2" p="staged/$1/${3:-1.scan}/${4:-DICOM}" i cks=""
    for i in $(seq 1 "$n"); do s3_put "$p/f$i.dcm" 100; cks="$cks\"f$i.dcm\":\"abc\","; done
    s3_put "$p/__MANIFEST__.json" 0 "{\"datatype\":\"${6:-medimage/dicom-series}\",\"checksums\":{${cks%,}}}"
    case "${5:-$MR}" in
        -)    s3_put "$p/__METADATA__.json" 0 '{"Modality":"MR"}' ;;
        none) : ;;
        *)    s3_put "$p/__METADATA__.json" 0 "{\"SOPClassUID\":\"${5:-$MR}\",\"Modality\":\"MR\"}" ;;
    esac
    s3_put "staged/$s/__METADATA__.json" 0 '{}'
}
s3_modified() { s3_set "import datetime; t=(datetime.datetime.utcnow()-datetime.timedelta(seconds=$1)).strftime('%Y-%m-%dT%H:%M:%S.000Z')
for o in d['objects'].values(): o['modified']=t"; }
s3_left()    { python3 -c 'import json,sys; print(sum(1 for k in json.load(open(sys.argv[1]))["objects"] if k.startswith("staged/"+sys.argv[2]+"/")))' "$CASE_DIR/s3.json" "$1"; }
s3_deletes() { local n; n=$(grep -c '^DELETE ' "$CASE_DIR/s3-requests.log" 2>/dev/null); echo "${n:-0}"; }
s3_has()     { python3 -c 'import json,sys; sys.exit(0 if sys.argv[2] in json.load(open(sys.argv[1]))["objects"] else 1)' "$CASE_DIR/s3.json" "$1"; }
no_deletes() { [ "$(s3_deletes)" = 0 ] || { echo "$(s3_deletes) object(s) were deleted: $(grep '^DELETE' "$CASE_DIR/s3-requests.log" | head -1)"; return 1; }; }
ev_for()     { grep -q "\"event\":\"$2\",\"session\":\"$3\"" "$1"; }

# boto3 for the helper: the pinned image's version, installed on the runner by
# the CI workflow or by hand (python3 -m pip install --user boto3==1.43.108).
# The case runs with an empty environment, so the user site-packages go in by path.
PYUSER=$(python3 -c 'import site; print(site.getusersitepackages())' 2>/dev/null)
env -i PATH="$CASE_PATH" PYTHONPATH="$PYUSER" python3 -c 'import sys, boto3, botocore
print(f"S3 cases run with {sys.executable} ({sys.version.split()[0]}), boto3 {boto3.__version__} from {boto3.__file__}, botocore {botocore.__version__}")
print("DeleteObject accepts IfMatch:", "IfMatch" in boto3.client("s3", region_name="us-east-1", aws_access_key_id="a", aws_secret_access_key="b").meta.service_model.operation_model("DeleteObject").input_shape.members)' 2>&1 | sed "s/^/  /"
run_s3_case() {   # <name> <expect-gone yes|no> <expect-event> [env...]
    local name="$1" expect_gone="$2" expect_event="$3"; shift 3
    local S="$WORK/$name"
    rm -rf "$S"; mkdir -p "$S"
    CASE_DIR="$S"
    printf '{"objects":{}}' > "$S/s3.json"
    printf '{}' > "$S/xnat.json"
    S3UP=yes; FILERUP=yes; CASE_SESS="$SESS"
    "setup_$name"
    local pids=""
    python3 "$HERE/fake-xnat.py" "$S" & pids="$pids $!"
    [ "$S3UP" = yes ] && { python3 "$HERE/fake-s3.py" "$S" & pids="$pids $!"; }
    [ "$FILERUP" = yes ] && { python3 "$HERE/fake-filer.py" "$S" & pids="$pids $!"; }
    for i in $(seq 50); do
        [ -s "$S/xnat-port" ] && { [ "$S3UP" != yes ] || [ -s "$S/s3-port" ]; } && { [ "$FILERUP" != yes ] || [ -s "$S/filer-port" ]; } && break
        sleep 0.1
    done
    local s3port=1 filerport=1
    [ "$S3UP" = yes ] && s3port=$(cat "$S/s3-port")
    [ "$FILERUP" = yes ] && filerport=$(cat "$S/filer-port")
    local out
    out=$(cd "$S" && env -i \
        PATH="$CASE_PATH" \
        HOME="$S" \
        STORAGE=s3 \
        S3_BUCKET="$S3B" S3_PREFIX=staged \
        AWS_ENDPOINT_URL="http://127.0.0.1:$s3port" AWS_ACCESS_KEY_ID=k AWS_SECRET_ACCESS_KEY=s AWS_DEFAULT_REGION=us-east-1 \
        FILER_ENDPOINT="http://127.0.0.1:$filerport" \
        CLUSTER_LABEL=mgmt \
        RECLAIM=onXnatConfirmed \
        MIN_AGE=0 \
        VERIFY_XNAT=true \
        DRY_RUN=false \
        XNAT_VERIFY_SSL=true \
        XNAT_SERVER="http://127.0.0.1:$(cat "$S/xnat-port")" \
        XNAT_USER=u XNAT_PASS=p \
        PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$FS_PYMOD:$PYUSER" \
        "$@" \
        bash "$SCRIPT" 2>&1)
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null; wait $pids 2>/dev/null
    printf '%s\n' "$out" > "$S/out.log"

    local gone="no"
    [ "$(s3_left "$CASE_SESS")" = 0 ] && gone="yes"
    local ok=1 why=""
    if printf '%s' "$out" | grep -qE "unbound variable|command not found|: line [0-9]+:|Traceback"; then
        ok=0; why="shell or python error: $(printf '%s' "$out" | grep -oE '[^ ]*: line [0-9]+: .*|.*unbound variable|Traceback.*' | head -1)"
    elif printf '%s' "$out" | grep -q '"event":"reclaim_failed"' && [ "$expect_event" != "reclaim_failed" ]; then
        ok=0; why="reclaim_failed was emitted but not expected"
    elif [ "$gone" != "$expect_gone" ]; then
        ok=0; why="expected session-gone=$expect_gone but got $gone ($(s3_left "$CASE_SESS") object(s) left)"
    elif ! printf '%s' "$out" | grep -q "\"event\":\"$expect_event\""; then
        ok=0; why="expected event $expect_event; got: $(printf '%s' "$out" | grep -o '"event":"[a-z_]*"' | tr '\n' ' ')"
    elif grep -qE '^DELETE [^ ]*/( |$)' "$S/s3-requests.log" 2>/dev/null; then
        ok=0; why="a folder key was deleted: $(grep -E '^DELETE [^ ]*/( |$)' "$S/s3-requests.log" | head -1)"
    elif grep '^DELETE ' "$S/s3-requests.log" 2>/dev/null | grep -qv 'if-match='; then
        ok=0; why="an object was deleted without If-Match: $(grep '^DELETE ' "$S/s3-requests.log" | grep -v 'if-match=' | head -1)"
    elif [ -s "$S/s3-requests.log" ] && grep -qvE '^(GET|HEAD|DELETE) ' "$S/s3-requests.log"; then
        ok=0; why="an S3 request that is not GET, HEAD or DELETE: $(grep -vE '^(GET|HEAD|DELETE) ' "$S/s3-requests.log" | head -1)"
    elif [ -s "$S/xnat-requests.log" ] && grep -qvE '^(GET|HEAD) |^DELETE /data/JSESSION$|^SESSION-(OPENED|CLOSED) ' "$S/xnat-requests.log"; then
        ok=0; why="the reclaimer sent XNAT a request that is not GET, HEAD or the logout"
    elif [ "$(cat "$S/xnat-requests.log" 2>/dev/null | grep -c '^SESSION-OPENED')" -gt 1 ]; then
        ok=0; why="the run opened $(grep -c '^SESSION-OPENED' "$S/xnat-requests.log") XNAT sessions in one run"
    elif [ "$(cat "$S/xnat-requests.log" 2>/dev/null | grep -c '^SESSION-OPENED')" != "$(cat "$S/xnat-requests.log" 2>/dev/null | grep -c '^SESSION-CLOSED')" ]; then
        ok=0; why="the run left an XNAT session open"
    elif declare -F "assert_$name" >/dev/null 2>&1; then
        local extra
        if ! extra=$("assert_$name" "$S/out.log" 2>&1); then ok=0; why="$extra"; fi
    fi
    if [ "$ok" = "1" ]; then
        printf '  %sPASS%s  %-34s gone=%-3s %s\n' "$_G" "$_O" "$name" "$gone" "$expect_event"
        PASS=$((PASS+1))
    else
        printf '  %sFAIL%s  %-34s %s\n' "$_R" "$_O" "$name" "$why"
        # what the fake S3 saw and what the helper decided: the only way to read a failure on a CI runner
        sed 's/^/          s3: /' "$S/s3-requests.log" 2>/dev/null | tail -14
        grep -o '"event":"reclaim_[a-z_]*".\{0,320\}' "$S/out.log" 2>/dev/null | tail -6 | sed 's/^/          helper: /'
        grep -v '^{' "$S/out.log" 2>/dev/null | tail -4 | sed 's/^/          stderr: /'
        FAIL=$((FAIL+1)); FAILED+=("$name: $why")
        printf '%s\n' "$out" | sed 's/^/          /' | head -12
    fi
}

SR="staged/$SESS/1.scan/DICOM"
# Every object deleted with the ETag the run listed, data before the manifest.
setup_s3_happy_path()      { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2; }
assert_s3_happy_path() {
    local log="$CASE_DIR/s3-requests.log" f1 m
    [ "$(s3_deletes)" = 5 ] || { echo "want 5 deletes, got $(s3_deletes)"; return 1; }
    grep -q "^DELETE $SR/f1.dcm if-match=$(python3 -c 'import hashlib; print(hashlib.md5(b"x"*100).hexdigest())')$" "$log" \
        || { echo "f1.dcm was not deleted with its listed ETag"; return 1; }
    f1=$(grep -n "^DELETE $SR/f1.dcm" "$log" | cut -d: -f1); m=$(grep -n "^DELETE $SR/__MANIFEST__.json" "$log" | cut -d: -f1)
    [ "$f1" -lt "$m" ] || { echo "the manifest went before the data"; return 1; }
    grep -q '"event":"reclaim_confirmed"' "$1" || { echo "no reclaim_confirmed"; return 1; }
}
setup_s3_partial_upload()  { s3_session "$SESS" 400; xnat_files subj EXP1 visit 3; }
assert_s3_partial_upload() { reason "$1" incomplete_in_xnat && no_deletes; }
setup_s3_xnat_absent()     { s3_session "$SESS" 2; }
assert_s3_xnat_absent()    { reason "$1" incomplete_in_xnat && no_deletes; }
setup_s3_size_mismatch()   { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2 50; }
assert_s3_size_mismatch()  { reason "$1" size_mismatch && no_deletes; }
setup_s3_xnat_500()        { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2; xnat_set "d['status']={'experiments':500}"; }
assert_s3_xnat_500()       { reason "$1" xnat_check_failed && no_deletes; }
setup_s3_no_manifest()     { s3_session "$SESS" 2; s3_set "d['objects'].pop('$SR/__MANIFEST__.json')"; }
assert_s3_no_manifest()    { reason "$1" manifest_unreadable && no_deletes; }
# A refused delete (412: the object changed after the listing) ends every delete
# of this session for the run: f1 went, f2 was refused, nothing else was tried.
setup_s3_etag_changed()    { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2
                             s3_set "k='$SR/f2.dcm'; d['after_list']={k: dict(d['objects'][k], etag='0'*32)}"; }
assert_s3_etag_changed() {
    reason "$1" object_changed || return 1
    [ "$(s3_deletes)" = 2 ] || { echo "want 2 delete attempts (f1 done, f2 refused), got $(s3_deletes)"; return 1; }
    s3_has "$SR/__MANIFEST__.json" && s3_has "staged/$SESS/__METADATA__.json" || { echo "a sidecar was deleted after the refusal"; return 1; }
    ! grep -q '"event":"reclaim_resource_removed"' "$1" || { echo "a resource was reported removed"; return 1; }
}
setup_s3_delete_error()    { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2; s3_set "d['fail_delete']={'$SR/f1.dcm': 500}"; }
# boto3 retries a 500 (five attempts of the same key); no OTHER object is tried.
assert_s3_delete_error()   { reason "$1" delete_failed && [ "$(grep '^DELETE' "$CASE_DIR/s3-requests.log" | awk '{print $2}' | sort -u | wc -l)" = 1 ] || { echo "another object was tried after the failure"; return 1; }; }
# The resource metadata was rewritten after the listing: its GET is refused, and
# no data object of the session is deleted.
setup_s3_sidecar_changed() { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2
                             s3_set "k='$SR/__METADATA__.json'; d['after_list']={k: dict(d['objects'][k], etag='1'*32, body='{\"SOPClassUID\":\"$SC\"}')}"; }
assert_s3_sidecar_changed(){ reason "$1" object_changed && no_deletes; }
# A resource that arrives after the snapshot: the proven resource goes, the
# session metadata stays, and the session is kept with the reason.
setup_s3_late_arrival()    { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2
                             s3_set "d['after_list']={'staged/$SESS/2.late/DICOM/f1.dcm': {'size':100,'etag':'a'*32,'modified':'2020-01-01T00:00:00.000Z','body':'x'*100}}"; }
assert_s3_late_arrival() {
    reason "$1" late_arrival || return 1
    s3_has "staged/$SESS/__METADATA__.json" || { echo "the session metadata was deleted although a resource arrived late"; return 1; }
    ! s3_has "$SR/f1.dcm" || { echo "the proven resource was not removed"; return 1; }
    ! grep -q '"event":"reclaim_removed"' "$1" || { echo "the session was reported removed"; return 1; }
}
# A nested object named like a sidecar is data: named by the manifest, not in
# XNAT, so the resource is kept and NOTHING is deleted.
setup_s3_nested_sidecar_name() {
    s3_session "$SESS" 1; xnat_files subj EXP1 visit 1
    s3_put "$SR/nested/__METADATA__.json" 0 '{"x":1}'
    s3_set "k='$SR/__MANIFEST__.json'; import json as j; m=j.loads(d['objects'][k]['body']); m['checksums']['nested/__METADATA__.json']='abc'; b=j.dumps(m); import hashlib; d['objects'][k].update(body=b, size=len(b), etag=hashlib.md5(b.encode()).hexdigest())"
}
assert_s3_nested_sidecar_name() { reason "$1" incomplete_in_xnat && no_deletes; }
# Sidecar-named objects under an unknown session child, a hidden child or an
# upload batch folder: no XNAT proof, and NOTHING is deleted.
setup_s3_unknown_child_sidecar() { s3_session "$SESS" 2; s3_put "staged/$SESS/attachments/nested/__METADATA__.json" 0 '{}'; }
assert_s3_unknown_child_sidecar(){ reason "$1" incomplete_in_xnat && no_deletes; }
setup_s3_batch_sidecar()         { s3_session "$SESS" 2; s3_put "staged/$SESS/1.scan/.DICOM-upload-active/__METADATA__.json" 0 '{}'; }
assert_s3_batch_sidecar()        { reason "$1" incomplete_in_xnat && no_deletes; }
setup_s3_hidden_child_sidecar()  { s3_session "$SESS" 2; s3_put "staged/$SESS/.hidden/nested/__MANIFEST__.json" 0 '{}'; }
assert_s3_hidden_child_sidecar() { reason "$1" incomplete_in_xnat && no_deletes; }
# The same with the resource proven: its data goes, the excluded entries and the
# session metadata stay, and the session is reported kept.
setup_s3_batch_keeps_session()   { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2; s3_put "staged/$SESS/1.scan/.DICOM-upload-active/__METADATA__.json" 0 '{}'; }
assert_s3_batch_keeps_session()  { reason "$1" upload_batch_present && s3_has "staged/$SESS/1.scan/.DICOM-upload-active/__METADATA__.json" \
                                   && s3_has "staged/$SESS/__METADATA__.json" && ! s3_has "$SR/f1.dcm" \
                                   || { echo "the batch or the session metadata went, or the proven data stayed"; return 1; }; }
# A crash after the data objects went: the sidecars are retired on the next run.
setup_s3_crash_retry()     { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2; s3_set "[d['objects'].pop(k) for k in ['$SR/f1.dcm','$SR/f2.dcm']]"; }
assert_s3_crash_retry()    { [ "$(s3_deletes)" = 3 ] || { echo "want the 3 sidecars deleted, got $(s3_deletes)"; return 1; }; }
# A prefix with no objects (an empty folder entry): nothing to do, no per-session
# event, counted as empty in the summary.
setup_s3_empty_prefix()    { s3_set "d['folders']=['staged/$SESS/']"; }
assert_s3_empty_prefix()   { ! grep -q "\"session\":\"$SESS\"" "$1" || { echo "an event names the empty session"; return 1; }
                             grep -q '"empty":1' "$1" || { echo "the summary does not count it as empty"; return 1; }; }
setup_s3_dry_run()         { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2; }
assert_s3_dry_run()        { no_deletes; }
setup_s3_too_young()       { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2; s3_modified 3600; }
assert_s3_too_young()      { no_deletes; }
setup_s3_listing_error()   { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2; s3_set "d['status']={'list':500}"; }
assert_s3_listing_error()  { no_deletes; }
setup_s3_pagination()      { s3_session "$SESS" 3; xnat_files subj EXP1 visit 3; s3_set "d['page']=2"; }
assert_s3_pagination()     { [ "$(s3_deletes)" = 6 ] || { echo "want 6 deletes over 3 pages, got $(s3_deletes)"; return 1; }; }
# The gate: both bucket attributes, or nothing is examined.
setup_s3_gate_not_disabled() { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2
                               printf '{"buckets":{"%s":{"Seaweed-X-Ais-Cleaner-Drained":"2026-10-14T00:00:00Z"}}}' "$S3B" > "$CASE_DIR/filer.json"; }
assert_s3_gate_not_disabled(){ grep -q '"reason":"cleaner_not_disabled"' "$1" && no_deletes; }
setup_s3_gate_not_drained()  { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2
                               printf '{"buckets":{"%s":{"Seaweed-X-Amz-Allow-Empty-Folders":"true"}}}' "$S3B" > "$CASE_DIR/filer.json"; }
assert_s3_gate_not_drained() { grep -q '"reason":"cleaner_not_drained"' "$1" && no_deletes; }
setup_s3_filer_down()      { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2; FILERUP=no; }
assert_s3_filer_down()     { grep -q '"reason":"filer_unreachable"' "$1" && no_deletes; }
setup_s3_bucket_unreachable() { s3_session "$SESS" 2; S3UP=no; }
assert_s3_bucket_unreachable(){ grep -q '"reason":"bucket_unreachable"' "$1"; }
# The pre-flight XNAT probe fails: a run-level event, and one per staged session.
setup_s3_xnat_auth_fail()  { s3_session "$SESS" 2; s3_session proj.subj2.visit 2; }
assert_s3_xnat_auth_fail() {
    grep '"event":"reclaim_unavailable","session":""' "$1" | grep -q '"reason":"xnat_probe_failed"' || { echo "no run-level xnat_probe_failed"; return 1; }
    ev_for "$1" reclaim_unavailable "$SESS" && ev_for "$1" reclaim_unavailable proj.subj2.visit || { echo "the fan-out did not name both sessions"; return 1; }
    no_deletes
}
setup_s3_unsafe_name()     { s3_put 'staged/evil; rm -rf x/1.scan/DICOM/f1.dcm' 100; CASE_SESS='evil; rm -rf x'; }
assert_s3_unsafe_name()    { reason "$1" unsafe_prefix_name && no_deletes; }
setup_s3_cap()             { s3_session "$SESS" 2; s3_session proj.subj2.visit 2; xnat_files subj EXP1 visit 2; xnat_files subj2 EXP2 visit 2; }
assert_s3_cap()            { grep -q 'removal cap of 1 reached' "$1" && s3_has staged/proj.subj2.visit/1.scan/DICOM/f1.dcm; }
# minAge on this backend is read by the same code: base 10, at most 10 digits.
setup_s3_minage_08d()      { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2; s3_modified 3600; }
assert_s3_minage_08d()     { minage_read_as "$1" 08d 691200 && no_deletes; }
setup_s3_minage_010d()     { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2; s3_modified $((9 * 86400)); }
assert_s3_minage_010d()    { minage_read_as "$1" 010d 864000 && no_deletes; }
setup_s3_minage_11_digits(){ s3_session "$SESS" 2; xnat_files subj EXP1 visit 2; }
assert_s3_minage_11_digits(){ minage_refused "$1" && no_deletes; }
setup_s3_minage_overflow() { s3_session "$SESS" 2; xnat_files subj EXP1 visit 2; }
assert_s3_minage_overflow(){ minage_refused "$1" && no_deletes; }

printf '\n%s== reclaimer decision paths, S3 backend ==%s\n' "$_B" "$_O"
run_s3_case s3_happy_path          yes reclaim_removed
run_s3_case s3_partial_upload      no  reclaim_kept
run_s3_case s3_xnat_absent         no  reclaim_kept
run_s3_case s3_size_mismatch       no  reclaim_kept
run_s3_case s3_xnat_500            no  reclaim_kept
run_s3_case s3_no_manifest         no  reclaim_kept
run_s3_case s3_etag_changed        no  reclaim_kept
run_s3_case s3_delete_error        no  reclaim_kept
run_s3_case s3_sidecar_changed     no  reclaim_kept
run_s3_case s3_late_arrival        no  reclaim_kept
run_s3_case s3_nested_sidecar_name no  reclaim_kept
run_s3_case s3_unknown_child_sidecar no reclaim_kept
run_s3_case s3_batch_sidecar       no  reclaim_kept
run_s3_case s3_hidden_child_sidecar no reclaim_kept
run_s3_case s3_batch_keeps_session no  reclaim_kept
run_s3_case s3_crash_retry         yes reclaim_removed
run_s3_case s3_empty_prefix        yes reclaim_finished
run_s3_case s3_dry_run             no  reclaim_skipped      DRY_RUN=true
run_s3_case s3_too_young           no  reclaim_skipped      MIN_AGE=1d
run_s3_case s3_listing_error       no  reclaim_unavailable
run_s3_case s3_pagination          yes reclaim_removed
run_s3_case s3_gate_not_disabled   no  reclaim_unavailable
run_s3_case s3_gate_not_drained    no  reclaim_unavailable
run_s3_case s3_filer_down          no  reclaim_unavailable
run_s3_case s3_bucket_unreachable  no  reclaim_unavailable
run_s3_case s3_xnat_auth_fail      no  reclaim_unavailable  XNAT_PASS=wrong
run_s3_case s3_unsafe_name         no  reclaim_kept
run_s3_case s3_cap                 yes reclaim_skipped      MAX_REMOVALS=1
printf '\n%s== minAge is read in base 10, at most 10 digits ==%s\n' "$_B" "$_O"
run_s3_case s3_minage_08d          no  reclaim_skipped      MIN_AGE=08d
run_s3_case s3_minage_010d         no  reclaim_skipped      MIN_AGE=010d
run_s3_case s3_minage_11_digits    no  reclaim_unavailable  MIN_AGE=10000000000d
run_s3_case s3_minage_overflow     no  reclaim_unavailable  MIN_AGE=999999999999999d

printf '\n%sreclaimer: %d passed, %d failed%s\n' "$_B" "$PASS" "$FAIL" "$_O"
if [ "$FAIL" -gt 0 ]; then
    printf '%sFAILURES:%s\n' "$_R" "$_O"
    printf '  - %s\n' "${FAILED[@]}"
    exit 1
fi
exit 0
