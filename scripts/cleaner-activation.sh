#!/usr/bin/env bash
# =============================================================================
# cleaner-activation.sh: opt the staging buckets out of SeaweedFS's empty-folder
# cleaner, in the order that makes the opt-out hold, and attest it.
# =============================================================================
#   scripts/cleaner-activation.sh <mgmt release> [mgmt namespace] -- <edge>...
#
# SeaweedFS removes an empty folder on its own about 90 s after its last object
# goes, with a window in which a child written meanwhile is dropped. The mgmt
# reclaimer therefore deletes nothing from a bucket until the bucket carries two
# filer attributes: Seaweed-X-Amz-Allow-Empty-Folders=true (the cleaner opted
# out; SeaweedFS caches that policy about 5 minutes) and
# Seaweed-X-Ais-Cleaner-Drained=<time> (this procedure ran after it). Steps:
#   1  suspend every reclaim-<edge> CronJob, then wait until no Job of one runs
#      and no reclaimer pod of the release is left (a pod can outlive its Job)
#   2  scale every edge s3-uploader to zero; wait until its pods are gone, and
#      until no bucket has a multipart upload in flight (the filer's .uploads/)
#      What steps 1 and 2 change is MARKED on the object (an annotation with
#      the state before: suspended by this script, the replicas it had), so a
#      later run knows what to put back, also after a failure.
#   3  set Allow-Empty-Folders on every bucket; read it back
#   4  restart the SeaweedFS Deployment (no cached policy and no pending cleanup
#      survives it); wait for the rollout; read the attribute back
#   5  set the attestation on every bucket; read it back
#   6  scale the uploaders back to the replicas in their mark; resume the
#      CronJobs this script suspended (one suspended by someone else, with no
#      mark, stays suspended); remove the marks
# It stops at the first failure and exits non-zero. Before step 5 that leaves
# nothing attested, and what was changed by then stays changed (the CronJobs
# suspended and the uploaders at zero so far), marked: repair, then run it
# again, and the rerun puts them back. In step 6 it leaves what was resumed
# before the failure resumed and the rest still marked; the message names them,
# and a rerun resumes them too. A query that fails or answers something
# unexpected is never read as "nothing runs": it is asked again until the
# timeout, then the script stops.
#
# Each edge needs kubeconfig-<edge> in the repository root, as install.sh writes
# it. The bucket of an edge is read from its CronJob. The filer is reached
# through a port-forward to the SeaweedFS Service.
# CAUTION: any kubectl or curl error is a failure, never "nothing runs".
set -uo pipefail
REL="${1:-}"; NS=ais-mgmt
shift 2>/dev/null || set --
if [ -n "${1:-}" ] && [ "$1" != "--" ]; then NS="$1"; shift; fi
[ "${1:-}" = "--" ] && shift
EDGES=("$@")
UPNS="${UPLOAD_NAMESPACE:-xnat-upload}"; EDGENS="${EDGE_NAMESPACE:-xnat-ingest}"
TIMEOUT="${ACTIVATION_TIMEOUT:-3600}"
ANN_SUSPENDED=ais.edge/activation-suspended   # on a CronJob this script suspended: when
ANN_REPLICAS=ais.edge/activation-replicas     # on a Deployment this script scaled: the replicas before
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PF_PID=""
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null' EXIT

die() { echo "cleaner-activation: $*" >&2; exit 1; }
say() { echo "cleaner-activation: $*"; }
[ -n "$REL" ] && [ "${#EDGES[@]}" -gt 0 ] || die "usage: cleaner-activation.sh <mgmt release> [namespace] -- <edge>..."
km() { kubectl -n "$NS" "$@"; }
ku() { kubectl -n "$UPNS" "$@"; }
ke() { kubectl --kubeconfig "$ROOT/kubeconfig-$1" -n "$EDGENS" "${@:2}"; }
until_ok() {   # <seconds> <what> <command...>: poll until the command exits 0
    local end=$(( $(date +%s) + $1 )) what="$2"; shift 2
    while ! "$@"; do
        [ "$(date +%s)" -lt "$end" ] || die "timed out waiting until $what"
        sleep 5
    done
}

# --- 1. the reclaimers: suspend all, then drain --------------------------------
# The count is the fence's (scripts/reclaimer-fence.sh): a Job of a selected
# CronJob that has not ended, or a pod that is owned by one or carries the
# release's s3-reclaimer labels and has not ended or is being deleted. A pod can
# outlive its Job (background cascading deletion) and carries no edge label, so
# every reclaimer pod of the release counts. A failed or unreadable listing is
# not zero.
CJS=(); OURS=()
state() {   # <kubectl fn> <object> <annotation>: "<suspend or replicas> <annotation value>" from one read;
            # fails when the read or the parse fails (CAUTION: test THIS status, not read's)
    local raw
    raw=$($1 get "$2" -o json) || return 1
    printf '%s' "$raw" | python3 -c 'import json, sys
o = json.load(sys.stdin); spec = o.get("spec") or {}
print(str(spec["suspend"]).lower() if "suspend" in spec else spec.get("replicas", 1), (o["metadata"].get("annotations") or {}).get(sys.argv[1], ""))' "$3"
}
reclaimers_active() {
    ku get jobs -o json > "$TMP/jobs" || return 1
    ku get pods -o json > "$TMP/pods" || return 1
    python3 - "$REL" "$TMP/jobs" "$TMP/pods" "${CJS[@]}" <<'PY'
import json, sys
rel, cjs = sys.argv[1], set(sys.argv[4:])
jobs, pods = json.load(open(sys.argv[2]))["items"], json.load(open(sys.argv[3]))["items"]
owned = lambda o, kind, names: any(r.get("kind") == kind and r.get("name") in names
                                   for r in o["metadata"].get("ownerReferences", []))
mine = {j["metadata"]["name"] for j in jobs if owned(j, "CronJob", cjs)}
ended = lambda j: any(c.get("type") in ("Complete", "Failed") and c.get("status") == "True"
                      for c in j.get("status", {}).get("conditions", []))
labels = lambda p: p["metadata"].get("labels") or {}
ours = lambda p: owned(p, "Job", mine) or (labels(p).get("app.kubernetes.io/instance") == rel
                                           and labels(p).get("component") == "s3-reclaimer")
active = [j["metadata"]["name"] for j in jobs if j["metadata"]["name"] in mine and not ended(j)]
active += [p["metadata"]["name"] for p in pods if ours(p)
           and (p.get("status", {}).get("phase") not in ("Succeeded", "Failed") or p["metadata"].get("deletionTimestamp"))]
sys.exit(1 if active else 0)
PY
}
for e in "${EDGES[@]}"; do
    cj="$REL-reclaim-$e"; CJS+=("$cj")
    saved=$(state ku "cronjob/$cj" "$ANN_SUSPENDED") || die "cannot read $cj"
    read -r s mark <<<"$saved"
    case "$s" in true|false) : ;; *) die "cannot read the suspend state of $cj: '$s'" ;; esac
    # Ours to resume at the end: running now, or suspended by an earlier run of this
    # script (marked). Suspended by someone else, unmarked: it stays suspended.
    if [ "$s" != "true" ] || [ -n "$mark" ]; then OURS+=(1); else OURS+=(0); fi
    [ "$s" = "true" ] || ku annotate cronjob "$cj" "$ANN_SUSPENDED=$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite >/dev/null || die "cannot mark $cj"
    ku patch cronjob "$cj" --type=merge -p '{"spec":{"suspend":true}}' >/dev/null || die "cannot suspend $cj"
    [ "$(ku get cronjob "$cj" -o jsonpath='{.spec.suspend}')" = "true" ] || die "$cj does not read back as suspended"
done
until_ok "$TIMEOUT" "no Job or pod of a reclaimer runs" reclaimers_active
say "suspended and drained: ${CJS[*]}"

# --- 2. the producers: scale to zero, drain, no multipart upload in flight ----
BUCKET=(); DEPLOYS=()
uploader_pods_gone() {   # <edge>: the listing succeeded and named no pod
    ke "$1" get pods -l component=s3-uploader -o name > "$TMP/up" || return 1
    [ ! -s "$TMP/up" ]
}
for e in "${EDGES[@]}"; do
    b=$(ku get cronjob "$REL-reclaim-$e" -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].env[?(@.name=="S3_BUCKET")].value}') \
        || die "cannot read the bucket of $REL-reclaim-$e"
    [ -n "$b" ] || die "no S3_BUCKET in $REL-reclaim-$e"
    BUCKET+=("$b")
    ups=$(ke "$e" get deploy -l component=s3-uploader -o name) || die "cannot list the uploaders of $e"
    [ -n "$ups" ] || die "no s3-uploader Deployment on $e"
    for d in $ups; do
        saved=$(state "ke $e" "$d" "$ANN_REPLICAS") || die "cannot read $d on $e"
        read -r n mark <<<"$saved"
        case "$n" in ''|*[!0-9]*) die "cannot read the replicas of $d on $e: '$n'" ;; esac
        # the replicas before, marked once: a rerun after a failure keeps the first mark
        [ -n "$mark" ] || ke "$e" annotate "$d" "$ANN_REPLICAS=$n" --overwrite >/dev/null || die "cannot mark $d on $e"
        DEPLOYS+=("$e $d")
        ke "$e" scale "$d" --replicas=0 >/dev/null || die "cannot scale $d on $e; the uploaders scaled before it are down and every CronJob is suspended"
    done
done
for e in "${EDGES[@]}"; do until_ok "$TIMEOUT" "the uploader pods of $e are gone" uploader_pods_gone "$e"; done
say "uploaders scaled to zero on: ${EDGES[*]}"

# --- the filer, through a port-forward ---------------------------------------
forward() {
    [ -n "$PF_PID" ] && { kill "$PF_PID" 2>/dev/null; wait "$PF_PID" 2>/dev/null; }
    : > "$TMP/pf"
    kubectl -n "$NS" port-forward "svc/$REL-seaweedfs" 0:8888 > "$TMP/pf" 2>&1 & PF_PID=$!   # not km: $! must be kubectl's own PID
    until_ok 60 "the port-forward to the filer is up" grep -q 'Forwarding from' "$TMP/pf"
    FILER="http://$(sed -n 's/^Forwarding from \(127\.0\.0\.1:[0-9]*\) -> 8888.*/\1/p' "$TMP/pf" | head -1)"
    [ "$FILER" != "http://" ] || die "cannot read the port-forward address"
}
filer_json() { curl -sS -f -m 30 -H 'Accept: application/json' "$FILER$1"; }
attr() {   # <bucket> <name>: the attribute's value, from the bucket listing
    filer_json "/buckets/?limit=1000" | python3 -c 'import base64, json, sys
for e in json.load(sys.stdin).get("Entries") or []:
    if e.get("FullPath", "").rstrip("/").endswith("/" + sys.argv[1]):
        print(base64.b64decode((e.get("Extended") or {}).get(sys.argv[2]) or "").decode(errors="replace"))' "$1" "$2"
}
set_attr() {   # <bucket> <name> <value>: set, then read back
    local code
    code=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X PUT -H "$2: $3" "$FILER/buckets/$1?tagging") || die "cannot set $2 on $1"
    case "$code" in 2*) : ;; *) die "the filer answered HTTP $code to $2 on $1" ;; esac
    [ "$(attr "$1" "$2")" = "$3" ] || die "$2 on $1 does not read back as $3"
}
no_multipart() {   # <bucket>: 404 (no upload ever started) or a listing with nothing in it; anything else is not an answer
    local code
    code=$(curl -sS -m 30 -o "$TMP/uploads" -w '%{http_code}' -H 'Accept: application/json' "$FILER/buckets/$1/.uploads/?limit=1") || return 1
    case "$code" in
        404) return 0 ;;
        200) [ "$(python3 -c 'import json, sys; print(len(json.load(open(sys.argv[1])).get("Entries") or []))' "$TMP/uploads" 2>/dev/null)" = 0 ] ;;
        *)   echo "cleaner-activation: the filer answered HTTP $code for $1/.uploads/" >&2; return 1 ;;
    esac
}
forward
for b in "${BUCKET[@]}"; do until_ok "$TIMEOUT" "no multipart upload is in flight in $b" no_multipart "$b"; done

# --- 3, 4, 5. the attributes, around the restart ------------------------------
for b in "${BUCKET[@]}"; do set_attr "$b" Seaweed-X-Amz-Allow-Empty-Folders true; done
say "cleaner opted out on: ${BUCKET[*]}"
km rollout restart "deploy/$REL-seaweedfs" >/dev/null || die "cannot restart $REL-seaweedfs"
km rollout status "deploy/$REL-seaweedfs" --timeout="${TIMEOUT}s" >/dev/null || die "$REL-seaweedfs did not roll out"
forward   # the old pod is gone with its policy cache and its pending cleanups
for b in "${BUCKET[@]}"; do
    [ "$(attr "$b" Seaweed-X-Amz-Allow-Empty-Folders)" = "true" ] || die "after the restart, $b has no Allow-Empty-Folders=true"
    set_attr "$b" Seaweed-X-Ais-Cleaner-Drained "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
done
say "SeaweedFS restarted; attested on: ${BUCKET[*]}"

# --- 6. resume: what was changed goes back to what its mark says ----------------
for pair in "${DEPLOYS[@]}"; do
    read -r e d <<<"$pair"
    # The mark is the only source of the replicas to put back: a failed read, no mark or
    # a mark that is not a count stops here, with the mark kept for the next run. Never 1.
    saved=$(state "ke $e" "$d" "$ANN_REPLICAS") || die "cannot read $d on $e; it and the uploaders after it are still down and marked, every CronJob still suspended"
    read -r n mark <<<"$saved"
    case "$mark" in ''|*[!0-9]*) die "$d on $e has no usable replicas mark ('$mark'); it stays down and marked, every CronJob still suspended" ;; esac
    ke "$e" scale "$d" --replicas="$mark" >/dev/null \
        || die "cannot scale $d back on $e; it and the uploaders after it are still down and marked, every CronJob still suspended"
    ke "$e" annotate "$d" "$ANN_REPLICAS-" >/dev/null || die "cannot unmark $d on $e"
done
i=0
for cj in "${CJS[@]}"; do
    if [ "${OURS[$i]}" = 1 ]; then
        ku patch cronjob "$cj" --type=merge -p '{"spec":{"suspend":false}}' >/dev/null \
            || die "cannot resume $cj; it and the CronJobs after it stay suspended and marked"
        [ "$(ku get cronjob "$cj" -o jsonpath='{.spec.suspend}')" = "false" ] || die "$cj does not read back as resumed"
        ku annotate cronjob "$cj" "$ANN_SUSPENDED-" >/dev/null || die "cannot unmark $cj"
    fi
    i=$((i + 1))
done
say "done: the mgmt reclaimer may delete from: ${BUCKET[*]}"
