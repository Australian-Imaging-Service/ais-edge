#!/usr/bin/env bash
# =============================================================================
# data-policy engine tests — assert on WHAT SURVIVED, not on what was logged
# =============================================================================
# This engine deletes patient-derived data, so the tests are written the same
# way tests/reclaimer/run-tests.sh is: every case builds a real directory tree,
# runs the REAL script under the REAL busybox image the chart deploys, and then
# asserts on the filesystem afterwards.
#
# A run that logs `reclaim_removed` and deletes nothing passes a log-only test
# and fails this one. So does a run that logs nothing and deletes everything.
#
# THE SCRIPT IS NEVER COPIED HERE. It is bind-mounted from charts/edge/files/,
# so a test cannot keep passing against a stale duplicate.
#
#   tests/data-policy/run-tests.sh
#   CI_REQUIRE_DATAPOLICY_TESTS=1   a skipped run (no docker) becomes a failure
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
ENGINE="${REPO_ROOT}/charts/edge/files/data-policy.sh"
# The image the chart deploys, read from values.yaml so the tests cannot drift
# onto a different one. The engine needs curl for the orthanc-rest backend, and
# busybox has none — testing on busybox would pass while production failed.
IMAGE="$(python3 -c "
import yaml
r = yaml.safe_load(open('${REPO_ROOT}/charts/edge/values.yaml'))['dataPolicy']['reporter']['image']
print(r['repository'] + ':' + r['tag'])" 2>/dev/null)"
[ -n "$IMAGE" ] || IMAGE="curlimages/curl:8.11.1"

_G=$'\033[32m'; _R=$'\033[31m'; _Y=$'\033[33m'; _B=$'\033[1m'; _O=$'\033[0m'
PASS=0; FAIL=0; FAILED=()
pass() { PASS=$((PASS+1)); printf '  %sPASS%s  %-26s %s\n' "$_G" "$_O" "$1" "$2"; }
fail() { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  %sFAIL%s  %-26s %s\n' "$_R" "$_O" "$1" "$2"; }

[ -f "$ENGINE" ] || { echo "no engine at $ENGINE" >&2; exit 2; }

if ! command -v docker >/dev/null 2>&1 || ! docker ps >/dev/null 2>&1; then
    printf '%sSKIP%s  data-policy: docker unusable, so the engine was NOT tested\n' "$_Y" "$_O"
    [ "${CI_REQUIRE_DATAPOLICY_TESTS:-0}" = "1" ] && exit 1
    exit 0
fi

printf '%s== data-policy engine (%s) ==%s\n' "$_B" "$IMAGE" "$_O"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
TAB="$(printf '\t')"

# build_case <dir> — a pipeline tree with two assigned sessions and one grouped.
# `old` is backdated well past any settle window or minAge under test.
build_case() {
    root="$1"
    rm -rf "$root"; mkdir -p "$root/assigned" "$root/grouped" "$root/LOGS/s3-uploader-state" "$root/fb"
}
mk_session() {  # mk_session <root> <stage-dir> <name> <age-minutes>
    d="$1/$2/$3"; mkdir -p "$d"; echo data > "$d/img.dcm"
    touch -d "$4 minutes ago" "$d/img.dcm" "$d"
}
mk_uploaded() {  # mk_uploaded <root> <name>
    # THE MARKER CARRIES A FINGERPRINT, NOT MERELY EXISTENCE. The uploader
    # writes a fingerprint of exactly the bytes it uploaded, and condition_met
    # recomputes it and compares. Existence alone was safe only while the marker
    # was swept in the same pass that wrote it, so it could never outlive the
    # data it described; now that it survives, an existence test would be a
    # standing permission to delete anything later appearing under the same
    # session name.
    #
    # MUST match fingerprint() in charts/edge/files/data-policy.sh and
    # s3-uploader.sh. scripts/ci/fingerprint-contract.sh keeps those two in
    # step with each other; this is the third copy and it is deliberate,
    # because a test that computed it a different way would pass while the
    # engine failed.
    if [ -d "$1/assigned/$2" ]; then
        ( cd "$1/assigned/$2" && find -L . -type f -exec stat -c '%n %s %Y' {} + 2>/dev/null \
            | sort | md5sum | cut -d' ' -f1 ) > "$1/LOGS/s3-uploader-state/$2"
    else
        # The session has already moved past the assigned stage. The engine
        # returns "satisfied" before it compares anything, so the content here
        # is irrelevant -- but the marker must still exist.
        echo "moved-on" > "$1/LOGS/s3-uploader-state/$2"
    fi
}

# run_engine <root> <stages.tsv contents> <RECLAIM_ENABLED> <DRY_RUN> [MAX_REMOVALS]
run_engine() {
    root="$1"; stages="$2"; en="$3"; dry="$4"; maxrm="${5:-50}"
    printf '%s\n' "$stages" > "$root/stages.tsv"
    # ONESHOT, not a timeout. The engine loops forever by design; bounding it
    # with `timeout docker run` killed the CLI while the container kept running,
    # so --rm never fired and the next case collided on the container name.
    # RUN AS THE HOST USER. curlimages/curl defaults to uid 100, which cannot
    # delete fixtures this script created — every deletion case failed with
    # `reclaim_failed`. Production does not have this problem: the chart sets
    # runAsUser 10001 and the real volumes are owned by 10001. Matching the
    # fixture owner here reproduces that relationship instead of the image's
    # accidental default.
    timeout 60 docker run --rm --user "$(id -u):$(id -g)" \
        -v "$ENGINE:/s.sh:ro" -v "$root:/data" \
        -e EDGE_NAME=test -e STAGES_FILE=/data/stages.tsv -e ONESHOT=true \
        -e RECLAIM_ENABLED="$en" -e DRY_RUN="$dry" -e MAX_REMOVALS="$maxrm" \
        -e SETTLE_MINUTES=5 \
        -e UPLOAD_STATE_DIR=/data/LOGS/s3-uploader-state \
        -e ASSIGNED_DIR=/data/assigned \
        -e ALLOW_ORIGINAL_EXPIRY="${ALLOW_EXPIRY:-false}" \
        -e ORTHANC_URL="${ORTHANC_URL_T:-}" \
        -e ORTHANC_USER="${ORTHANC_USER_T:-}" \
        -e ORTHANC_PASS="${ORTHANC_PASS_T:-}" \
        --entrypoint sh "$IMAGE" /s.sh > "$root/out.jsonl" 2>&1
}

STAGES_ASSIGNED="derived.assigned${TAB}derived${TAB}/data/assigned${TAB}-${TAB}-${TAB}onUploaded${TAB}0${TAB}filesystem"
STAGES_GROUPED="derived.grouped${TAB}derived${TAB}/data/grouped${TAB}-${TAB}-${TAB}onAssigned${TAB}0${TAB}filesystem"

check() {  # check <name> <root> <path-that-should-be> <exist|gone> <desc>
    if [ "$4" = "gone" ]; then
        [ ! -d "$2/$3" ] && pass "$1" "$5" || fail "$1" "$5 — $3 STILL EXISTS"
    else
        [ -d "$2/$3" ] && pass "$1" "$5" || fail "$1" "$5 — $3 WAS DELETED"
    fi
}

# 1 — condition met + old enough + armed -> removed
R="$WORK/c1"; build_case "$R"; mk_session "$R" assigned s1 60; mk_uploaded "$R" s1
run_engine "$R" "$STAGES_ASSIGNED" true false
check removed_when_eligible "$R" assigned/s1 gone "uploaded + past minAge + armed"

# 2 — condition met but INSIDE the recovery window -> kept  (assigned.minAge live)
R="$WORK/c2"; build_case "$R"; mk_session "$R" assigned s1 60; mk_uploaded "$R" s1
run_engine "$R" "derived.assigned${TAB}derived${TAB}/data/assigned${TAB}-${TAB}-${TAB}onUploaded${TAB}86400${TAB}filesystem" true false
check kept_inside_minage "$R" assigned/s1 exist "minAge 24h not yet elapsed — the recovery window"

# 2b — a marker describing DIFFERENT bytes must not authorise removal.
# This is the case the fingerprint comparison exists for: a session re-staged
# under a name that was uploaded before (a supplementary or re-sent study)
# would otherwise inherit the old marker's authority and be deleted without
# ever having been uploaded.
R="$WORK/c2b"; build_case "$R"; mk_session "$R" assigned s1 60; mk_uploaded "$R" s1
# Re-staged under the SAME NAME with different content. mk_session alone would
# not do: it writes identical bytes at an identical backdated mtime, so the
# fingerprint would match and the case would prove nothing.
echo "a supplementary study, different bytes" > "$R/assigned/s1/img.dcm"
touch -d "60 minutes ago" "$R/assigned/s1/img.dcm" "$R/assigned/s1"
run_engine "$R" "$STAGES_ASSIGNED" true false
check kept_stale_fingerprint "$R" assigned/s1 exist "marker describes an earlier upload of different bytes"

# 3 — never uploaded -> kept regardless of age
R="$WORK/c3"; build_case "$R"; mk_session "$R" assigned s1 600
run_engine "$R" "$STAGES_ASSIGNED" true false
check kept_not_uploaded "$R" assigned/s1 exist "no uploader marker — nothing proves it is reconstructible"

# 4 — dryRun -> decides, deletes nothing
R="$WORK/c4"; build_case "$R"; mk_session "$R" assigned s1 60; mk_uploaded "$R" s1
run_engine "$R" "$STAGES_ASSIGNED" true true
check kept_dry_run "$R" assigned/s1 exist "enabled but dryRun"

# 5 — dataPolicy disabled -> deletes nothing
R="$WORK/c5"; build_case "$R"; mk_session "$R" assigned s1 60; mk_uploaded "$R" s1
run_engine "$R" "$STAGES_ASSIGNED" false false
check kept_disabled "$R" assigned/s1 exist "dataPolicy.enabled=false"

# 6 — still being written (inside settle window) -> untouched
R="$WORK/c6"; build_case "$R"; mk_session "$R" assigned s1 1; mk_uploaded "$R" s1
run_engine "$R" "$STAGES_ASSIGNED" true false
check kept_settling "$R" assigned/s1 exist "modified 1m ago, settle is 5m"

# 7 — grouped whose assigned output exists -> removed
R="$WORK/c7"; build_case "$R"; mk_session "$R" grouped s1 60; mk_session "$R" assigned s1 60
run_engine "$R" "$STAGES_GROUPED" true false
check grouped_after_assign "$R" grouped/s1 gone "assign has produced its output"

# 8 — grouped with no assigned copy and no upload marker -> kept
R="$WORK/c8"; build_case "$R"; mk_session "$R" grouped s1 60
run_engine "$R" "$STAGES_GROUPED" true false
check grouped_not_assigned "$R" grouped/s1 exist "assign has not run for it"

# 9 — grouped whose assigned copy was ALREADY reclaimed, but which uploaded ->
#     removed. Without the second half of the condition this pins forever.
R="$WORK/c9"; build_case "$R"; mk_session "$R" grouped s1 60; mk_uploaded "$R" s1
run_engine "$R" "$STAGES_GROUPED" true false
check grouped_after_upload "$R" grouped/s1 gone "assigned copy gone but upload marker proves progress"

# 10 — unknown condition word (a typo) -> kept, never deleted
R="$WORK/c10"; build_case "$R"; mk_session "$R" assigned s1 60; mk_uploaded "$R" s1
run_engine "$R" "derived.assigned${TAB}derived${TAB}/data/assigned${TAB}-${TAB}-${TAB}onWhenever${TAB}0${TAB}filesystem" true false
check kept_unknown_condition "$R" assigned/s1 exist "a typo in values.yaml must not authorise removal"

# 11 — ORIGINALS are never removed by this engine, whatever the word says
R="$WORK/c11"; build_case "$R"; mk_session "$R" fb s1 600; mk_uploaded "$R" s1
run_engine "$R" "originals.facilityBackup${TAB}original${TAB}/data/fb${TAB}-${TAB}-${TAB}onUploaded${TAB}0${TAB}filesystem" true false
check originals_never_removed "$R" fb/s1 exist "kind=original is skipped regardless of the reclaim word"

# 12 — per-pass cap bounds the blast radius
R="$WORK/c12"; build_case "$R"
for i in 1 2 3 4 5; do mk_session "$R" assigned "s$i" 60; mk_uploaded "$R" "s$i"; done
run_engine "$R" "$STAGES_ASSIGNED" true false 2
left=$(find "$R/assigned" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
[ "$left" = "3" ] && pass max_removals_cap "5 eligible, cap 2 -> 3 left" \
                  || fail max_removals_cap "expected 3 survivors with cap 2, got $left"


# ---------------------------------------------------------------------------
# originals expiry — the only path that removes an identifiable copy
# ---------------------------------------------------------------------------
FB_1H="originals.facilityBackup${TAB}original${TAB}/data/fb${TAB}-${TAB}-${TAB}1h${TAB}3600${TAB}filesystem"

# 13 — old enough, but the third switch is OFF -> kept
R="$WORK/c13"; build_case "$R"; mk_session "$R" fb p1 600
ALLOW_EXPIRY=false run_engine "$R" "$FB_1H" true false
check originals_switch_off "$R" fb/p1 exist "past retain but allowExpiry=false"

# 14 — old enough AND the third switch on -> expired
R="$WORK/c14"; build_case "$R"; mk_session "$R" fb p1 600
ALLOW_EXPIRY=true run_engine "$R" "$FB_1H" true false
check originals_expired "$R" fb/p1 gone "past retain with allowExpiry=true"

# 15 — inside the retention period -> kept even with every switch on
R="$WORK/c15"; build_case "$R"; mk_session "$R" fb p1 10
ALLOW_EXPIRY=true run_engine "$R" "$FB_1H" true false
check originals_within_retain "$R" fb/p1 exist "10m old, retain is 1h"

# 16 — retain: forever renders as '-' and must never expire
R="$WORK/c16"; build_case "$R"; mk_session "$R" fb p1 6000
FB_FOREVER="originals.facilityBackup${TAB}original${TAB}/data/fb${TAB}-${TAB}-${TAB}forever${TAB}-${TAB}filesystem"
ALLOW_EXPIRY=true run_engine "$R" "$FB_FOREVER" true false
check originals_forever "$R" fb/p1 exist "retain=forever, every switch on"

# 17 — dry run still never expires an original
R="$WORK/c17"; build_case "$R"; mk_session "$R" fb p1 600
ALLOW_EXPIRY=true run_engine "$R" "$FB_1H" true true
check originals_dry_run "$R" fb/p1 exist "allowExpiry=true but dryRun"

# ---------------------------------------------------------------------------
# backends
# ---------------------------------------------------------------------------
# 18 — an unknown backend must NOT fall through to a filesystem walk. Walking
#      /data/orthanc-storage as if it held sessions would delete Orthanc's own
#      UUID folders.
R="$WORK/c18"; build_case "$R"; mk_session "$R" assigned s1 60; mk_uploaded "$R" s1
run_engine "$R" "derived.assigned${TAB}derived${TAB}/data/assigned${TAB}-${TAB}-${TAB}onUploaded${TAB}0${TAB}weird-backend" true false
check unknown_backend_no_walk "$R" assigned/s1 exist "unknown backend must not delete"

# 19 — orthanc-rest with no URL configured: reports, removes nothing, no crash
R="$WORK/c19"; build_case "$R"; mk_session "$R" assigned s1 60; mk_uploaded "$R" s1
ORTHANC_URL_T="" run_engine "$R" "derived.orthancStorage${TAB}derived${TAB}/data/assigned${TAB}-${TAB}-${TAB}onGrouped${TAB}0${TAB}orthanc-rest" true false
if grep -q backend_unavailable "$R/out.jsonl" 2>/dev/null; then
    pass orthanc_no_url "reports backend_unavailable rather than failing silently"
else
    fail orthanc_no_url "expected a backend_unavailable event; got: $(tail -1 "$R/out.jsonl" 2>/dev/null | cut -c1-90)"
fi
check orthanc_no_url_nodelete "$R" assigned/s1 exist "and deleted nothing while unconfigured"

# ORTHANC AUTH. The engine reclaims the Orthanc store over the REST API whenever
# the backend is orthanc-rest, so with orthanc.auth.enabled it is a SECOND consumer
# of the credentials, not just group-orthanc.
#
# The first case is the failure this pair exists for, and it was silent. Without
# credentials every call returns 401; a 401 body is empty, so /tools/find yielded an
# empty id list and the engine logged backend_idle "nothing to reclaim" -- identical
# to a healthy empty store, while the Orthanc store grew until the disk did. A real
# Orthanc is used rather than a stub because the bug was in what a real 401 looks
# like to curl, which a stub would have had to guess.
ORTHANC_IMG=jodogne/orthanc-plugins:1.12.11
if docker image inspect "$ORTHANC_IMG" >/dev/null 2>&1 || docker pull -q "$ORTHANC_IMG" >/dev/null 2>&1; then
    OCFG=$(mktemp -d)
    printf '{ "Name":"authtest", "RemoteAccessAllowed":true, "AuthenticationEnabled":true, "HttpPort":8042 }\n' >"$OCFG/orthanc.json"
    printf '{"RegisteredUsers":{"admin":"testpw123"}}\n' >"$OCFG/users.json"
    OCID=$(docker run -d --rm -v "$OCFG":/etc/orthanc:ro "$ORTHANC_IMG" 2>/dev/null)
    OIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$OCID" 2>/dev/null)
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        curl -s -o /dev/null --max-time 2 "http://$OIP:8042/system" && break || sleep 1
    done
    STAGE="derived.orthancStorage${TAB}derived${TAB}/data/assigned${TAB}-${TAB}-${TAB}onGrouped${TAB}0${TAB}orthanc-rest"

    # THIS CASE IS THE ONLY THING STANDING BEHIND --fail IN orthanc_curl.
    # orthanc_401_nodelete passes without it (an unauthenticated engine finds
    # nothing to delete either way) and orthanc_authed_ok passes without it
    # (correct credentials work regardless). Delete or weaken this one and --fail
    # becomes unguarded, and the silent-empty-store bug can return unnoticed.
    #
    # The PAIR is what makes a failure here trustworthy: if the scaffolding were
    # broken -- Orthanc not up, config not mounted, engine not reaching the URL --
    # orthanc_authed_ok would fail too. It passing while this one fails localises
    # the fault to the 401 path rather than the harness.
    R2="$WORK/auth401"; build_case "$R2"; mk_session "$R2" assigned s1 60
    ORTHANC_URL_T="http://$OIP:8042" run_engine "$R2" "$STAGE" true false
    if grep -q '"event":"backend_idle"' "$R2/out.jsonl" 2>/dev/null; then
        fail orthanc_401_not_idle "a 401 was reported as backend_idle — indistinguishable from an empty store"
    elif grep -q '"event":"backend_unavailable"' "$R2/out.jsonl" 2>/dev/null; then
        pass orthanc_401_not_idle "401 reports backend_unavailable, not an empty store"
    else
        fail orthanc_401_not_idle "expected backend_unavailable; got: $(grep -o '"event":"[a-z_]*"' "$R2/out.jsonl" 2>/dev/null | sort -u | tr '\n' ' ')"
    fi
    check orthanc_401_nodelete "$R2" assigned/s1 exist "and deleted nothing while unauthenticated"

    R3="$WORK/authok"; build_case "$R3"; mk_session "$R3" assigned s1 60
    ORTHANC_URL_T="http://$OIP:8042" ORTHANC_USER_T=admin ORTHANC_PASS_T=testpw123 \
        run_engine "$R3" "$STAGE" true false
    if grep -q '"event":"backend_unavailable"' "$R3/out.jsonl" 2>/dev/null; then
        fail orthanc_authed_ok "authenticated query still reported backend_unavailable"
    elif grep -q '"event":"backend_idle"' "$R3/out.jsonl" 2>/dev/null; then
        pass orthanc_authed_ok "authenticated query succeeds; empty store reads as empty"
    else
        fail orthanc_authed_ok "expected backend_idle; got: $(grep -o '"event":"[a-z_]*"' "$R3/out.jsonl" 2>/dev/null | sort -u | tr '\n' ' ')"
    fi

    docker kill "$OCID" >/dev/null 2>&1 || true
    rm -rf "$OCFG"
else
    printf '  SKIP  %-26s %s\n' "orthanc_auth" "$ORTHANC_IMG unavailable"
fi

printf '\n%sdata-policy: %d passed, %d failed%s\n' "$_B" "$PASS" "$FAIL" "$_O"
if [ "$FAIL" -gt 0 ]; then printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
