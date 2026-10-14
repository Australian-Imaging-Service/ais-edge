#!/usr/bin/env bash
# =============================================================================
# tests/reclaimer-fence/run-tests.sh: scripts/reclaimer-fence.sh against a stub
# kubectl. Each case asserts the exit status AND the CronJob's suspend value the
# script left, so a run that fails open (reads an error as "nothing runs", or
# resumes without a wrapped writer) fails here.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/reclaimer-fence-tests"
_R=$'\033[31m'; _G=$'\033[32m'; _B=$'\033[1m'; _O=$'\033[0m'
PASS=0; FAIL=0; FAILED=()
REL=rel; CJ=rel-staged-reclaimer

# --- fixtures ------------------------------------------------------------------
cronjob() {   # [lock] [alive]: the CronJob, its deleter env with or without the lock
    python3 -c 'import json, sys
env = [{"name": "STORAGE", "value": "filesystem"}]
if sys.argv[1]:
    env += [{"name": "WRITER_LOCK", "value": sys.argv[1]}, {"name": "WRITER_ALIVE", "value": sys.argv[2]}]
print(json.dumps({"spec": {"jobTemplate": {"spec": {"template": {"spec": {"containers": [{"env": env}]}}}}}}))' \
        "${1:-}" "${2:-}" > "$C/cronjob.json"
}
jobs() {   # <file> <job>:<active|done> ...: Jobs owned by the CronJob
    local f="$1"; shift
    python3 -c 'import json, sys
items = [{"metadata": {"name": n, "ownerReferences": [{"kind": "CronJob", "name": "rel-staged-reclaimer"}]},
          "status": {"conditions": [{"type": "Complete", "status": "True"}] if s == "done" else []}}
         for n, s in (a.split(":") for a in sys.argv[1:])]
print(json.dumps({"items": items}))' "$@" > "$C/$f"
}
pods() {   # [--file F] <pod>:<job>:<phase>[:deleting][:release] ...: reclaimer pods
    local f=pods.json; [ "${1:-}" = "--file" ] && { f="$2"; shift 2; }
    python3 -c 'import json, sys
items = []
for a in sys.argv[1:]:
    n, j, ph, *more = a.split(":")
    rel = next((x for x in more if x != "deleting"), "rel")
    m = {"name": n, "ownerReferences": [{"kind": "Job", "name": j}],
         "labels": {"app.kubernetes.io/instance": rel, "component": "s3-reclaimer"}}
    if "deleting" in more: m["deletionTimestamp"] = "2026-10-14T00:00:00Z"
    items.append({"metadata": m, "status": {"phase": ph}})
print(json.dumps({"items": items}))' "$@" > "$C/$f"
}
WRAPPED='mkdir -p /data/.locks && exec 9>>/data/.locks/assigned.alive && flock -s 9 && while :; do flock /data/.locks/assigned.lock "$0" "$@" || exit; sleep 60; done'
writers() {   # <pod>:<wrapped|plain>:<phase>[:deleting] ...: writer pods
    python3 -c 'import json, sys
w = sys.argv[1]; items = []
for a in sys.argv[2:]:
    n, kind, ph, *d = a.split(":")
    cmd = ["/bin/sh", "-c", w, "xnat-ingest", "assign"] if kind == "wrapped" else ["xnat-ingest", "assign"]
    m = {"name": n}
    if d: m["deletionTimestamp"] = "2026-10-14T00:00:00Z"
    items.append({"metadata": m, "spec": {"containers": [{"command": cmd}]}, "status": {"phase": ph}})
print(json.dumps({"items": items}))' "$WRAPPED" "$@" > "$C/writers.json"
}

# run_case <name> <drain|resume> <expect exit: 0|fail> <expect suspend: true|false|unset> [env...]
run_case() {
    local name="$1" cmd="$2" want_rc="$3" want_suspend="$4"; shift 4
    C="$WORK/$name"; rm -rf "$C"; mkdir -p "$C"
    echo true > "$C/suspend"    # a resume starts from a suspended CronJob
    "setup_$name"
    local out rc=0
    local argv=("$cmd" "$REL")
    # around runs a command between drain and resume; it leaves a marker so a
    # case can assert whether the command ran at all.
    [ "$cmd" = around ] && argv+=(-- bash -c "touch '$C/ran'; exit \${AROUND_RC:-0}")
    out=$(env PATH="$HERE:$PATH" FENCE_CASE="$C" FENCE_TIMEOUT=2 "$@" bash "$REPO/scripts/reclaimer-fence.sh" "${argv[@]}" 2>&1) || rc=$?
    local got_rc=fail; [ "$rc" -eq 0 ] && got_rc=0
    local got_suspend; got_suspend=$(cat "$C/suspend" 2>/dev/null || echo unset)
    if [ "$got_rc" = "$want_rc" ] && [ "$got_suspend" = "$want_suspend" ] && ! grep -q 'unexpected call' <<<"$out"; then
        printf '  %sPASS%s  %-30s exit=%-4s suspend=%s\n' "$_G" "$_O" "$name" "$got_rc" "$got_suspend"; PASS=$((PASS+1))
    else
        printf '  %sFAIL%s  %-30s exit=%s (want %s) suspend=%s (want %s)\n' "$_R" "$_O" "$name" "$got_rc" "$want_rc" "$got_suspend" "$want_suspend"
        printf '%s\n' "$out" | sed 's/^/          /' | head -6
        FAIL=$((FAIL+1)); FAILED+=("$name")
    fi
}

# --- drain ---------------------------------------------------------------------
setup_drain_nothing_active()  { echo false > "$C/suspend"; cronjob; jobs jobs.json "j1:done"; pods "p1:j1:Succeeded"; }
setup_drain_patch_fails()     { echo false > "$C/suspend"; cronjob; jobs jobs.json; pods; : > "$C/patch.fail"; }
setup_drain_readback_wrong()  { echo false > "$C/suspend"; cronjob; jobs jobs.json; pods; : > "$C/readback.wrong"; }
# THE FAIL-OPEN CASE: a failed read must never count as "nothing runs".
setup_drain_jobs_read_fails() { echo false > "$C/suspend"; cronjob; pods; : > "$C/jobs.fail"; }
setup_drain_pods_read_fails() { echo false > "$C/suspend"; cronjob; jobs jobs.json; : > "$C/pods.fail"; }
setup_drain_waits()           { echo false > "$C/suspend"; cronjob; jobs jobs.1.json "j1:active"; jobs jobs.json "j1:done"; pods "p1:j1:Succeeded"; }
setup_drain_still_active()    { echo false > "$C/suspend"; cronjob; jobs jobs.json "j1:active"; pods "p1:j1:Running"; }
# The Job reports done, but its pod is still being deleted: not drained.
setup_drain_pod_terminating() { echo false > "$C/suspend"; cronjob; jobs jobs.json "j1:done"; pods "p1:j1:Running:deleting"; }
setup_drain_other_jobs()      { echo false > "$C/suspend"; cronjob; python3 -c 'import json
print(json.dumps({"items": [{"metadata": {"name": "x", "ownerReferences": [{"kind": "CronJob", "name": "other"}]}, "status": {}}]}))' > "$C/jobs.json"; pods; }

# The Job is gone (background cascading deletion) and its pod still runs.
setup_drain_orphan_pod()        { echo false > "$C/suspend"; cronjob; jobs jobs.json; pods "p1:j-gone:Running"; }
setup_drain_orphan_terminating(){ echo false > "$C/suspend"; cronjob; jobs jobs.json; pods "p1:j-gone:Succeeded:deleting"; }
# The parent disappears between polls; the pod ends one poll later.
setup_drain_parent_disappears() {
    echo false > "$C/suspend"; cronjob
    jobs jobs.1.json "j1:active"; jobs jobs.json
    pods --file pods.1.json "p1:j1:Running"; pods --file pods.2.json "p1:j1:Running"; pods "p1:j1:Succeeded"
}
# A reclaimer pod of ANOTHER release is not this release's.
setup_drain_other_release_pod() { echo false > "$C/suspend"; cronjob; jobs jobs.json; pods "p9:j9:Running:other"; }

printf '\n%s== reclaimer-fence drain ==%s\n' "$_B" "$_O"
run_case drain_nothing_active    drain  0    true
run_case drain_patch_fails       drain  fail false
run_case drain_readback_wrong    drain  fail true
run_case drain_jobs_read_fails   drain  fail true
run_case drain_pods_read_fails   drain  fail true
run_case drain_waits             drain  0    true
run_case drain_still_active      drain  fail true
run_case drain_pod_terminating   drain  fail true
run_case drain_other_jobs        drain  0    true
run_case drain_orphan_pod        drain  fail true
run_case drain_orphan_terminating drain fail true
run_case drain_parent_disappears drain  0    true    FENCE_TIMEOUT=30
run_case drain_other_release_pod drain  0    true

# --- resume --------------------------------------------------------------------
LOCK=/data/.locks/assigned.lock; ALIVE=/data/.locks/assigned.alive
setup_resume_ok()                { cronjob "$LOCK" "$ALIVE"; writers "w1:wrapped:Running"; }
# Rolled back to a release whose deleter does not take the lock: stay suspended.
setup_resume_deleter_unlocked()  { cronjob; writers "w1:wrapped:Running"; }
# Rolled back to a writer without the wrapper: stay suspended.
setup_resume_writer_unwrapped()  { cronjob "$LOCK" "$ALIVE"; writers "w1:plain:Running"; }
setup_resume_old_writer_left()   { cronjob "$LOCK" "$ALIVE"; writers "w2:wrapped:Running" "w1:plain:Running:deleting"; }
setup_resume_writer_terminating(){ cronjob "$LOCK" "$ALIVE"; writers "w1:wrapped:Running:deleting"; }
setup_resume_no_writer()         { cronjob "$LOCK" "$ALIVE"; writers; }
setup_resume_rollout_fails()     { cronjob "$LOCK" "$ALIVE"; writers "w1:wrapped:Running"; : > "$C/rollout.fail"; }
setup_resume_pods_read_fails()   { cronjob "$LOCK" "$ALIVE"; : > "$C/pods.fail"; }
setup_resume_cronjob_read_fails(){ : > "$C/cronjob.fail"; }
setup_resume_other_alive()       { cronjob "$LOCK" /data/.locks/other.alive; writers "w1:wrapped:Running"; }

printf '\n%s== reclaimer-fence resume ==%s\n' "$_B" "$_O"
run_case resume_ok                 resume 0    false
run_case resume_deleter_unlocked   resume fail true
run_case resume_writer_unwrapped   resume fail true
run_case resume_old_writer_left    resume fail true
run_case resume_writer_terminating resume fail true
run_case resume_no_writer          resume fail true
run_case resume_rollout_fails      resume fail true
run_case resume_pods_read_fails    resume fail true
run_case resume_cronjob_read_fails resume fail true
run_case resume_other_alive        resume fail true

# --- around: the documented operator command ------------------------------------
# A failure at any step stops it, and the CronJob stays suspended.
ran() { [ -e "$WORK/$1/ran" ] && echo yes || echo no; }
setup_around_ok()            { echo false > "$C/suspend"; cronjob "$LOCK" "$ALIVE"; jobs jobs.json; pods; writers "w1:wrapped:Running"; }
setup_around_drain_fails()   { echo false > "$C/suspend"; cronjob "$LOCK" "$ALIVE"; pods; writers "w1:wrapped:Running"; : > "$C/jobs.fail"; }
setup_around_command_fails() { echo false > "$C/suspend"; cronjob "$LOCK" "$ALIVE"; jobs jobs.json; pods; writers "w1:wrapped:Running"; }
setup_around_resume_refused(){ echo false > "$C/suspend"; cronjob "$LOCK" "$ALIVE"; jobs jobs.json; pods; writers "w1:plain:Running"; }

printf '\n%s== reclaimer-fence around ==%s\n' "$_B" "$_O"
run_case around_ok              around 0    false
run_case around_drain_fails     around fail true
[ "$(ran around_drain_fails)" = no ] || { printf '  %sFAIL%s  around_drain_fails: the command ran after a failed drain\n' "$_R" "$_O"; FAIL=$((FAIL+1)); FAILED+=("around_drain_fails ran the command"); }
run_case around_command_fails   around fail true     AROUND_RC=3
run_case around_resume_refused  around fail true
[ "$(ran around_ok)" = yes ] || { printf '  %sFAIL%s  around_ok: the command did not run\n' "$_R" "$_O"; FAIL=$((FAIL+1)); FAILED+=("around_ok did not run the command"); }

printf '\n%sreclaimer-fence: %d passed, %d failed%s\n' "$_B" "$PASS" "$FAIL" "$_O"
for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
[ "$FAIL" -eq 0 ]
