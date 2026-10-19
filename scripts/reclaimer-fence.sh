#!/usr/bin/env bash
# =============================================================================
# reclaimer-fence.sh: stop the staged-reclaimer around an upgrade or a rollback.
# =============================================================================
#   scripts/reclaimer-fence.sh around <release> [namespace] -- <command ...>
#   scripts/reclaimer-fence.sh drain  <release> [namespace]
#   scripts/reclaimer-fence.sh resume <release> [namespace]
#
# around  drain, then the command (helm upgrade or rollback), then resume. It
#         stops at the first failure, exits non-zero, and the CronJob stays
#         suspended. Use this one: separate commands in a shell do not stop
#         when one of them fails.
# drain   suspends the CronJob, reads that back, and waits until no Job and no
#         pod of it is active (a Job that has started keeps running after its
#         CronJob changes, and suspend does not stop it). Exit 0 only then.
# resume  unsuspends only when the deleter in the CronJob uses the writer lock
#         (WRITER_LOCK and WRITER_ALIVE), the writer's rollout is complete, and
#         every writer pod runs the lock wrapper with that .alive file and none
#         is terminating. Else the CronJob stays suspended.
#
# CAUTION: any kubectl error is a failure. It is never read as "nothing runs".
# GUIDING: docs/components/xnat-ingest.md, "Upgrade or roll back while the
# cleanup can delete", says when to use it.
set -uo pipefail
CMD="${1:-}"; REL="${2:-}"; NS=xnat-ingest
shift 2 2>/dev/null || set --
if [ -n "${1:-}" ] && [ "$1" != "--" ]; then NS="$1"; shift; fi
[ "${1:-}" = "--" ] && shift
RUN=("$@")                         # around: the command between drain and resume
TIMEOUT="${FENCE_TIMEOUT:-3600}"   # seconds drain waits for active Jobs
CJ="$REL-staged-reclaimer"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

die() { echo "reclaimer-fence: $*" >&2; exit 1; }
k() { kubectl -n "$NS" "$@"; }
USAGE="usage: reclaimer-fence.sh around <release> [namespace] -- <command ...> | drain|resume <release> [namespace]"
[ -n "$REL" ] || die "$USAGE"

suspend_set() {   # true | false, then read it back
    k patch cronjob "$CJ" --type=merge -p "{\"spec\":{\"suspend\":$1}}" >/dev/null || die "cannot set suspend=$1 on $CJ"
    [ "$(k get cronjob "$CJ" -o jsonpath='{.spec.suspend}')" = "$1" ] || die "$CJ suspend does not read back as $1"
}

# The number of active Jobs of the CronJob, plus the reclaimer pods that have not
# ended or are being deleted. A pod counts by its owner Job OR by its release and
# component labels: Kubernetes can delete a Job before its pods (background
# cascading deletion), so a running pod may have no listed parent. Fails on any
# read error.
active() {
    k get jobs -o json > "$TMP/jobs" || return 1
    k get pods -o json > "$TMP/pods" || return 1
    python3 - "$CJ" "$REL" "$TMP/jobs" "$TMP/pods" <<'PY'
import json, sys
cj, rel = sys.argv[1], sys.argv[2]
jobs, pods = json.load(open(sys.argv[3]))["items"], json.load(open(sys.argv[4]))["items"]
owned = lambda o, kind, names: any(r.get("kind") == kind and r.get("name") in names
                                   for r in o["metadata"].get("ownerReferences", []))
mine = {j["metadata"]["name"] for j in jobs if owned(j, "CronJob", {cj})}
ended = lambda j: any(c.get("type") in ("Complete", "Failed") and c.get("status") == "True"
                      for c in j.get("status", {}).get("conditions", []))
labels = lambda p: p["metadata"].get("labels") or {}
ours = lambda p: owned(p, "Job", mine) or (labels(p).get("app.kubernetes.io/instance") == rel
                                           and labels(p).get("component") == "s3-reclaimer")
n = sum(1 for j in jobs if j["metadata"]["name"] in mine and not ended(j))
n += sum(1 for p in pods if ours(p)
         and (p.get("status", {}).get("phase") not in ("Succeeded", "Failed") or p["metadata"].get("deletionTimestamp")))
print(n)
PY
}

drain() {
    k get cronjob "$CJ" >/dev/null || die "cannot read CronJob $CJ in $NS"
    suspend_set true
    local end=$(( $(date +%s) + TIMEOUT )) n
    while :; do
        n=$(active) || die "cannot list Jobs or pods: NOT drained"
        case "$n" in ''|*[!0-9]*) die "cannot count active Jobs: NOT drained" ;; esac
        [ "$n" -eq 0 ] && { echo "reclaimer-fence: $CJ is suspended and no Job of it is active"; return 0; }
        [ "$(date +%s)" -lt "$end" ] || die "$n Job(s) or pod(s) of $CJ still active after ${TIMEOUT}s: NOT drained"
        sleep 5
    done
}

resume() {
    k get cronjob "$CJ" -o json > "$TMP/cj" || die "cannot read CronJob $CJ"
    local paths lock alive writer
    paths=$(python3 -c 'import json, sys
c = json.load(open(sys.argv[1]))["spec"]["jobTemplate"]["spec"]["template"]["spec"]["containers"][0]
e = {x["name"]: x.get("value", "") for x in c.get("env", [])}
print(e.get("WRITER_LOCK", ""), e.get("WRITER_ALIVE", ""))' "$TMP/cj") || die "cannot read the env of $CJ"
    read -r lock alive <<<"$paths"
    [ -n "$lock" ] && [ -n "${alive:-}" ] \
        || die "$CJ has no WRITER_LOCK/WRITER_ALIVE: its deleter does not take the lock. It stays suspended."
    case "$(basename "$lock")" in
        assigned.lock)     writer=assign ;;
        deidentified.lock) writer=deidentify ;;
        packaged.lock)     writer=package ;;
        *) die "unknown writer lock $lock. $CJ stays suspended." ;;
    esac
    k rollout status "deploy/$REL-$writer" --timeout=300s >/dev/null \
        || die "the rollout of $REL-$writer is not complete. $CJ stays suspended."
    k get pods -l "app=xnat-ingest,component=$writer" -o json > "$TMP/writers" || die "cannot list $writer pods. $CJ stays suspended."
    python3 - "$alive" "$TMP/writers" <<'PY' || die "a $writer pod without the lock wrapper, or a terminating one, exists. $CJ stays suspended."
import json, sys
alive, pods = sys.argv[1], json.load(open(sys.argv[2]))["items"]
live = [p for p in pods if p.get("status", {}).get("phase") not in ("Succeeded", "Failed")]
wrapped = lambda p: f"exec 9>>{alive} && flock -s 9" in " ".join(p["spec"]["containers"][0].get("command") or [])
bad = [p["metadata"]["name"] for p in live if p["metadata"].get("deletionTimestamp") or not wrapped(p)]
for b in bad:
    print("not ready:", b, file=sys.stderr)
sys.exit(0 if live and not bad else 1)
PY
    suspend_set false
    echo "reclaimer-fence: $REL-$writer runs the lock wrapper; $CJ resumed"
}

around() {
    [ "${#RUN[@]}" -gt 0 ] || die "around needs a command after --"
    drain
    "${RUN[@]}" || die "the command failed (exit $?). $CJ stays suspended. Fix the release, then: reclaimer-fence.sh resume $REL $NS"
    resume
}

case "$CMD" in
    around) around ;;
    drain) drain ;;
    resume) resume ;;
    *) die "$USAGE" ;;
esac
