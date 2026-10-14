#!/usr/bin/env bash
# =============================================================================
# cleaner-activation test harness
# =============================================================================
#   tests/cleaner-activation/run-tests.sh
#
# scripts/cleaner-activation.sh against a stub kubectl and a stub curl. The stubs
# record every call to calls.log and answer from the case's fixtures; anything a
# case does not configure fails, so the script's refusals are what is tested.
# Each case asserts the ORDER of the destructive steps and where the script
# stopped, not only its exit status: a step that runs before its precondition
# holds is the failure that matters here. A query that fails is never "nothing
# runs": those cases assert that nothing was attested or resumed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/scripts/cleaner-activation.sh"
WORK="${TMPDIR:-/tmp}/cleaner-activation-tests"
PASS=0; FAIL=0; FAILED=()
_R=$'\033[31m'; _G=$'\033[32m'; _B=$'\033[1m'; _O=$'\033[0m'
ARGS="mgmt ais-mgmt -- edge-a"   # the script's argv; a case may set it before run_case

# run_case <name> <expect exit 0|1>; a setup_<name> writes the fixtures, an
# assert_<name> reads calls.log (one line per kubectl/curl call) and out.log.
run_case() {
    local name="$1" expect="$2"
    local S="$WORK/$name"
    rm -rf "$S"; mkdir -p "$S"; CASE_DIR="$S"
    : > "$S/calls.log"
    "setup_$name"
    local out rc
    # shellcheck disable=SC2086
    out=$(cd "$S" && env -i PATH="$HERE:/usr/bin:/bin" SCENARIO="$S" HOME="$S" ACTIVATION_TIMEOUT=2 \
          bash "$SCRIPT" $ARGS 2>&1); rc=$?
    printf '%s\n' "$out" > "$S/out.log"
    local ok=1 why=""
    if [ "$rc" != "$expect" ]; then
        ok=0; why="expected exit $expect, got $rc: $(printf '%s' "$out" | tail -1 | cut -c1-120)"
    elif printf '%s' "$out" | grep -qE "unbound variable|command not found|: line [0-9]+:"; then
        ok=0; why="shell error: $(printf '%s' "$out" | grep -oE '[^ ]*: line [0-9]+: .*|.*unbound variable' | head -1)"
    elif declare -F "assert_$name" >/dev/null 2>&1; then
        local extra
        if ! extra=$("assert_$name" "$S/calls.log" "$S/out.log" 2>&1); then ok=0; why="$extra"; fi
    fi
    if [ "$ok" = 1 ]; then
        printf '  %sPASS%s  %-32s exit=%s\n' "$_G" "$_O" "$name" "$rc"; PASS=$((PASS+1))
    else
        printf '  %sFAIL%s  %-32s %s\n' "$_R" "$_O" "$name" "$why"; FAIL=$((FAIL+1)); FAILED+=("$name: $why")
        printf '%s\n' "$out" | sed 's/^/          /' | tail -6
    fi
    ARGS="mgmt ais-mgmt -- edge-a"
}

# --- fixture helpers ---------------------------------------------------------
# The stub kubectl answers get jobs/pods from jobs.json / pods.json (empty by
# default), get cronjob suspend from cronjob.<name>.suspend (what the last patch
# wrote; false before any), get deploy -l component=s3-uploader with
# deployment.apps/<edge>-s3-uploader (fails on the call numbered in
# deploy-list.fail-on), the replicas of it from replicas.<edge> (1), scale ok
# unless scale.fail.<edge> exists or the call is the one numbered in
# scale.fail-on.<edge>, get pods -l component=s3-uploader from
# uploader-pods (a file: non-empty means pods remain; uploader-pods.fail: the
# call fails), annotations in ann.cronjob.<name>.json / ann.deploy.<edge>.json
# (read by get -o json, written by annotate), rollout restart/status ok unless
# rollout.fail exists, port-forward
# prints the forwarding line and sleeps. The stub curl answers the filer: ?tagging
# PUT 202 (unless tagging.fail), the bucket listing from attrs.<bucket>.json
# (attributes set so far, updated by each PUT), and .uploads/ with 404, or
# uploads.<bucket>.json (200), uploads.code.<bucket>, or uploads.fail (curl exits
# with that code).
base() {
    printf '{"items":[]}' > "$CASE_DIR/jobs.json"; printf '{"items":[]}' > "$CASE_DIR/pods.json"
    printf '{}' > "$CASE_DIR/attrs.ingest-edge-a.json"
    : > "$CASE_DIR/uploader-pods"     # the uploader has no pods once scaled (empty file = none)
}
calls_in_order() {   # <log> <needle>...: every needle appears, in this order
    local log="$1" pos=0 n line; shift
    for n in "$@"; do
        line=$(grep -n -F -- "$n" "$log" | awk -F: -v p="$pos" '$1 > p {print $1; exit}')
        [ -n "$line" ] || { echo "missing or out of order: $n"; return 1; }
        pos=$line
    done
}
never() { ! grep -q -F -- "$1" "$2" || { echo "must not happen: $1"; return 1; }; }
# nothing destructive after a failed precondition: no attribute, no restart, no resume
stopped_before_attributes() { never 'tagging' "$1" && never 'rollout' "$1" && never '"suspend":false' "$1" && never '--replicas=1' "$1"; }
reclaimer_pod() {   # <phase> [deletionTimestamp]: a pod of a Job that is no longer listed
    printf '{"items":[{"metadata":{"name":"mgmt-reclaim-edge-a-12345-xyz","labels":{"job-name":"mgmt-reclaim-edge-a-12345","app.kubernetes.io/instance":"mgmt","component":"s3-reclaimer"},"ownerReferences":[{"kind":"Job","name":"mgmt-reclaim-edge-a-12345"}]%s},"status":{"phase":"%s"}}]}' \
        "${2:+,\"deletionTimestamp\":\"$2\"}" "$1" > "$CASE_DIR/pods.json"
}

# The happy path, with the order of the steps asserted.
setup_happy_path() { base; }
assert_happy_path() {
    calls_in_order "$1" \
        'kubectl -n xnat-upload patch cronjob mgmt-reclaim-edge-a --type=merge -p {"spec":{"suspend":true}}' \
        'kubectl -n xnat-upload get jobs -o json' \
        'scale deployment.apps/edge-a-s3-uploader --replicas=0' \
        'get pods -l component=s3-uploader -o name' \
        'port-forward svc/mgmt-seaweedfs 0:8888' \
        'curl GET /buckets/ingest-edge-a/.uploads/?limit=1' \
        'curl PUT /buckets/ingest-edge-a?tagging Seaweed-X-Amz-Allow-Empty-Folders: true' \
        'rollout restart deploy/mgmt-seaweedfs' \
        'rollout status deploy/mgmt-seaweedfs' \
        'curl PUT /buckets/ingest-edge-a?tagging Seaweed-X-Ais-Cleaner-Drained:' \
        'scale deployment.apps/edge-a-s3-uploader --replicas=1' \
        'kubectl -n xnat-upload patch cronjob mgmt-reclaim-edge-a --type=merge -p {"spec":{"suspend":false}}' \
        && grep -q 'Seaweed-X-Amz-Allow-Empty-Folders.*true' "$CASE_DIR/attrs.ingest-edge-a.json" \
        && grep -q 'Seaweed-X-Ais-Cleaner-Drained' "$CASE_DIR/attrs.ingest-edge-a.json" \
        && calls_in_order "$1" 'annotate cronjob mgmt-reclaim-edge-a ais.edge/activation-suspended=' 'annotate deployment.apps/edge-a-s3-uploader ais.edge/activation-replicas=1' \
                               'annotate deployment.apps/edge-a-s3-uploader ais.edge/activation-replicas-' 'annotate cronjob mgmt-reclaim-edge-a ais.edge/activation-suspended-' \
        && unmarked
}
unmarked() {   # no mark is left on the CronJob or the Deployment
    ! grep -q 'activation-' "$CASE_DIR/ann.cronjob.mgmt-reclaim-edge-a.json" 2>/dev/null \
        && ! grep -q 'activation-' "$CASE_DIR/ann.deploy.edge-a.json" 2>/dev/null || { echo "a mark is left: $(cat "$CASE_DIR"/ann.*.json 2>/dev/null)"; return 1; }
}
# The documented short form, without a namespace: the default namespace is used.
setup_no_namespace_form() { base; ARGS="mgmt -- edge-a"; }
assert_no_namespace_form() { grep -q 'kubectl -n ais-mgmt port-forward' "$1" && grep -q 'Cleaner-Drained' "$CASE_DIR/attrs.ingest-edge-a.json"; }
# A reclaimer Job still runs: nothing else happens, the CronJob stays suspended.
setup_job_running() { base; printf '{"items":[{"metadata":{"name":"mgmt-reclaim-edge-a-1","ownerReferences":[{"kind":"CronJob","name":"mgmt-reclaim-edge-a"}]},"status":{"active":1}}]}' > "$CASE_DIR/jobs.json"; }
assert_job_running() { never 'scale deployment' "$1" && stopped_before_attributes "$1" && grep -q 'timed out waiting until no Job' "$2"; }
# A reclaimer pod runs on after its Job object is gone: it counts by its labels.
setup_orphan_reclaimer_pod() { base; reclaimer_pod Running; }
assert_orphan_reclaimer_pod() { never 'scale deployment' "$1" && stopped_before_attributes "$1" && grep -q 'timed out waiting until no Job' "$2"; }
# A reclaimer pod that is being deleted still counts, whatever its phase.
setup_terminating_reclaimer_pod() { base; reclaimer_pod Succeeded 2026-10-14T10:00:00Z; }
assert_terminating_reclaimer_pod() { never 'scale deployment' "$1" && stopped_before_attributes "$1"; }
# The uploader pods do not go: the attributes are never written.
setup_uploader_pods_stay() { base; echo pod/edge-a-s3-uploader-x > "$CASE_DIR/uploader-pods"; }
assert_uploader_pods_stay() { stopped_before_attributes "$1"; }
# The uploader pod listing fails: that is not "no pods".
setup_uploader_list_error() { base; : > "$CASE_DIR/uploader-pods.fail"; }
assert_uploader_list_error() { stopped_before_attributes "$1" && grep -q 'timed out waiting until the uploader pods' "$2"; }
# A multipart upload is in flight: no attribute, no restart.
setup_multipart_in_flight() { base; printf '{"Entries":[{"FullPath":"/buckets/ingest-edge-a/.uploads/u1"}]}' > "$CASE_DIR/uploads.ingest-edge-a.json"; }
assert_multipart_in_flight() { stopped_before_attributes "$1" && grep -q 'no multipart upload is in flight' "$2"; }
# The multipart query cannot reach the filer (curl exit 7): not an answer.
setup_multipart_transport_error() { base; echo 7 > "$CASE_DIR/uploads.fail"; }
assert_multipart_transport_error() { stopped_before_attributes "$1" && grep -q 'no multipart upload is in flight' "$2"; }
# The filer answers 500 (or 401, 403) to the multipart query: not an answer.
setup_multipart_http_error() { base; echo 500 > "$CASE_DIR/uploads.code.ingest-edge-a"; }
assert_multipart_http_error() { stopped_before_attributes "$1" && grep -q 'answered HTTP 500' "$2"; }
# The multipart listing is not JSON: not an answer.
setup_multipart_malformed() { base; echo 'not json' > "$CASE_DIR/uploads.ingest-edge-a.json"; }
assert_multipart_malformed() { stopped_before_attributes "$1"; }
# The attribute does not read back: no restart, no attestation.
setup_readback_wrong() { base; : > "$CASE_DIR/tagging.ignore"; }
assert_readback_wrong() { never 'rollout' "$1" && never 'Cleaner-Drained' "$1" && never '"suspend":false' "$1" && grep -q 'does not read back' "$2"; }
# The rollout fails: no attestation, nothing resumed.
setup_rollout_fails() { base; : > "$CASE_DIR/rollout.fail"; }
assert_rollout_fails() { never 'Cleaner-Drained' "$1" && never '--replicas=1' "$1" && never '"suspend":false' "$1"; }
# The attribute is gone after the restart: no attestation, nothing resumed.
setup_lost_after_restart() { base; : > "$CASE_DIR/attrs.reset-on-rollout"; }
assert_lost_after_restart() { never 'Cleaner-Drained' "$1" && never '--replicas=1' "$1" && grep -q 'after the restart' "$2"; }
# The uploader listing fails: not "no uploader"; the CronJob stays suspended.
setup_uploader_list_fails() { base; echo 1 > "$CASE_DIR/deploy-list.fail-on"; }
assert_uploader_list_fails() { never 'scale deployment' "$1" && stopped_before_attributes "$1" && grep -q 'cannot list the uploaders' "$2"; }
# Scaling the uploader back fails at resume: the CronJob stays suspended, and
# the script says so.
setup_resume_scale_error() { base; echo 2 > "$CASE_DIR/scale.fail-on.edge-a"; }
assert_resume_scale_error() { grep -q 'Cleaner-Drained' "$CASE_DIR/attrs.ingest-edge-a.json" && never '"suspend":false' "$1" && grep -q 'still suspended' "$2"; }
# What was there before comes back: a CronJob suspended before the run stays
# suspended; an uploader with two replicas gets two back.
setup_already_suspended() { base; echo true > "$CASE_DIR/cronjob.mgmt-reclaim-edge-a.suspend"; }
assert_already_suspended() { never '"suspend":false' "$1" && never 'activation-suspended=' "$1" && grep -q 'Cleaner-Drained' "$CASE_DIR/attrs.ingest-edge-a.json" && unmarked; }
# A rerun after a failed run: the CronJob is suspended and marked by that run, the
# uploader at zero and marked with its replicas; the rerun resumes both from the marks.
setup_rerun_after_failure() { base; echo true > "$CASE_DIR/cronjob.mgmt-reclaim-edge-a.suspend"; echo '{"ais.edge/activation-suspended": "2026-10-14T15:00:00Z"}' > "$CASE_DIR/ann.cronjob.mgmt-reclaim-edge-a.json"
                              echo 0 > "$CASE_DIR/replicas.edge-a"; echo '{"ais.edge/activation-replicas": "2"}' > "$CASE_DIR/ann.deploy.edge-a.json"; }
assert_rerun_after_failure() { grep -q '"suspend":false' "$1" && grep -q 'scale deployment.apps/edge-a-s3-uploader --replicas=2' "$1" && never 'activation-replicas=0' "$1" && unmarked; }
# The resume reads the mark and nothing else decides the replicas: a failed read, a body
# that is not JSON, or a mark that is not a count stops the script with the uploader
# down, the mark kept and the CronJob suspended. Never a scale to 1.
mark_kept() { grep -q '"ais.edge/activation-replicas": "2"' "$CASE_DIR/ann.deploy.edge-a.json" && never '--replicas=1' "$1" && never '"suspend":false' "$1" && never 'activation-replicas-' "$1"; }
setup_resume_read_fails()   { base; echo 2 > "$CASE_DIR/replicas.edge-a"; echo 2 > "$CASE_DIR/deploy-get.fail-on.edge-a"; }
assert_resume_read_fails()  { mark_kept "$1" && grep -q 'cannot read deployment.apps/edge-a-s3-uploader' "$2"; }
setup_resume_read_garbage() { base; echo 2 > "$CASE_DIR/replicas.edge-a"; echo 2 > "$CASE_DIR/deploy-get.garbage-on.edge-a"; }
assert_resume_read_garbage(){ mark_kept "$1" && grep -q 'cannot read deployment.apps/edge-a-s3-uploader' "$2"; }
setup_resume_mark_invalid() { base; echo 2 > "$CASE_DIR/replicas.edge-a"; echo '{"ais.edge/activation-replicas": "two"}' > "$CASE_DIR/ann.deploy.edge-a.json"; }
assert_resume_mark_invalid(){ never '--replicas=1' "$1" && never '--replicas=two' "$1" && never '"suspend":false' "$1" && grep -q 'no usable replicas mark' "$2" && grep -q '"two"' "$CASE_DIR/ann.deploy.edge-a.json"; }
# An uploader deliberately at zero before the run: marked 0 and put back to 0, never 1.
setup_replicas_zero_kept()  { base; echo 0 > "$CASE_DIR/replicas.edge-a"; }
assert_replicas_zero_kept() { grep -q 'activation-replicas=0' "$1" && [ "$(grep -c 'scale deployment.apps/edge-a-s3-uploader --replicas=0' "$1")" = 2 ] && never '--replicas=1' "$1" && unmarked; }
# A failure leaves the marks: the suspended CronJob and the scaled uploader stay marked.
setup_marks_survive_failure() { base; : > "$CASE_DIR/tagging.ignore"; }
assert_marks_survive_failure() { grep -q 'activation-suspended' "$CASE_DIR/ann.cronjob.mgmt-reclaim-edge-a.json" && grep -q '"ais.edge/activation-replicas": "1"' "$CASE_DIR/ann.deploy.edge-a.json"; }
setup_replicas_restored() { base; echo 2 > "$CASE_DIR/replicas.edge-a"; }
assert_replicas_restored() { grep -q 'scale deployment.apps/edge-a-s3-uploader --replicas=2' "$1" && never '--replicas=1' "$1"; }
# Two edges: every CronJob is suspended before any drain, every uploader is
# scaled before any wait, and both are resumed at the end.
setup_two_edges() { base; printf '{}' > "$CASE_DIR/attrs.ingest-edge-b.json"; ARGS="mgmt ais-mgmt -- edge-a edge-b"; }
assert_two_edges() {
    calls_in_order "$1" \
        'patch cronjob mgmt-reclaim-edge-a --type=merge -p {"spec":{"suspend":true}}' \
        'patch cronjob mgmt-reclaim-edge-b --type=merge -p {"spec":{"suspend":true}}' \
        'get jobs -o json' \
        'scale deployment.apps/edge-a-s3-uploader --replicas=0' \
        'scale deployment.apps/edge-b-s3-uploader --replicas=0' \
        'kubeconfig-edge-a -n xnat-ingest get pods -l component=s3-uploader' \
        'curl GET /buckets/ingest-edge-a/.uploads/?limit=1' \
        'curl GET /buckets/ingest-edge-b/.uploads/?limit=1' \
        'curl PUT /buckets/ingest-edge-a?tagging Seaweed-X-Amz-Allow-Empty-Folders: true' \
        'curl PUT /buckets/ingest-edge-b?tagging Seaweed-X-Amz-Allow-Empty-Folders: true' \
        'rollout restart deploy/mgmt-seaweedfs' \
        'curl PUT /buckets/ingest-edge-a?tagging Seaweed-X-Ais-Cleaner-Drained:' \
        'curl PUT /buckets/ingest-edge-b?tagging Seaweed-X-Ais-Cleaner-Drained:' \
        'scale deployment.apps/edge-a-s3-uploader --replicas=1' \
        'scale deployment.apps/edge-b-s3-uploader --replicas=1' \
        'patch cronjob mgmt-reclaim-edge-a --type=merge -p {"spec":{"suspend":false}}' \
        'patch cronjob mgmt-reclaim-edge-b --type=merge -p {"spec":{"suspend":false}}' \
        && grep -q 'Cleaner-Drained' "$CASE_DIR/attrs.ingest-edge-b.json"
}
# Two edges, and the second uploader cannot be scaled: the first stays down, both
# CronJobs stay suspended, no attribute is written.
setup_two_edges_scale_fails() { base; printf '{}' > "$CASE_DIR/attrs.ingest-edge-b.json"; : > "$CASE_DIR/scale.fail.edge-b"; ARGS="mgmt ais-mgmt -- edge-a edge-b"; }
assert_two_edges_scale_fails() { grep -q 'scale deployment.apps/edge-a-s3-uploader --replicas=0' "$1" && stopped_before_attributes "$1" && grep -q 'every CronJob is suspended' "$2"; }

printf '%s== cleaner-activation ==%s\n' "$_B" "$_O"
run_case happy_path                0
run_case no_namespace_form         0
run_case job_running               1
run_case orphan_reclaimer_pod      1
run_case terminating_reclaimer_pod 1
run_case uploader_pods_stay        1
run_case uploader_list_error       1
run_case multipart_in_flight       1
run_case multipart_transport_error 1
run_case multipart_http_error      1
run_case multipart_malformed       1
run_case readback_wrong            1
run_case rollout_fails             1
run_case lost_after_restart        1
run_case uploader_list_fails       1
run_case resume_scale_error        1
run_case already_suspended         0
run_case replicas_restored         0
run_case rerun_after_failure       0
run_case marks_survive_failure     1
run_case resume_read_fails         1
run_case resume_read_garbage       1
run_case resume_mark_invalid       1
run_case replicas_zero_kept        0
run_case two_edges                 0
run_case two_edges_scale_fails     1
# the usage check runs with no edge: a different argv, through a wrapper
S="$WORK/no_edge"; rm -rf "$S"; mkdir -p "$S"; CASE_DIR="$S"; : > "$S/calls.log"; base
if out=$(cd "$S" && env -i PATH="$HERE:/usr/bin:/bin" SCENARIO="$S" HOME="$S" bash "$SCRIPT" mgmt ais-mgmt -- 2>&1); then
    printf '  %sFAIL%s  %-32s exit 0 without an edge\n' "$_R" "$_O" no_edge; FAIL=$((FAIL+1)); FAILED+=("no_edge")
elif [ -s "$S/calls.log" ]; then
    printf '  %sFAIL%s  %-32s a call happened without an edge\n' "$_R" "$_O" no_edge; FAIL=$((FAIL+1)); FAILED+=("no_edge")
else
    printf '  %sPASS%s  %-32s exit=1\n' "$_G" "$_O" no_edge; PASS=$((PASS+1))
fi

printf '\n%scleaner-activation: %d passed, %d failed%s\n' "$_B" "$PASS" "$FAIL" "$_O"
if [ "$FAIL" -gt 0 ]; then printf '%sFAILURES:%s\n' "$_R" "$_O"; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
