#!/usr/bin/env bash
# =============================================================================
# Clean the SeaweedFS staging prefix WITHOUT destroying un-uploaded sessions.
# =============================================================================
#   bash scripts/clear-staged-s3.sh <site> [edge]           safe: empty prefixes
#   bash scripts/clear-staged-s3.sh <site> [edge] --all     DESTRUCTIVE
#
# DEFAULT MODE (production-safe): removes ONLY *empty* session prefixes —
# 0-byte directory entries holding no objects. Sessions that still contain files
# are LEFT ALONE, because a staged session may not have reached XNAT yet (XNAT
# down, credential problem, backlog) and deleting those loses undelivered data.
#
# --------------------------------------------------------------------------
# WHY EMPTY PREFIXES MATTER
#
# `xnat-ingest upload` has no S3 retention: it rebuilds its work list from a
# live listing of s3://<bucket>/staged every --loop pass. An EMPTY prefix is
# still listed as a session; the uploader "uploads" its zero resources and logs
#     Successfully uploaded all files in '<session>'
# which is the exact string the XNATUploadSuccess Loki rule matches — so one
# 0-byte prefix re-fires the alert every 60s forever and spams the inbox.
# (Observed 2026-07-29: 12 empty prefixes, ~2 success lines/minute for 2 days.)
#
# WHERE EMPTY PREFIXES COME FROM
#
#     mc rm --recursive --force edge/ingest-bucket/staged/     # <-- DO NOT
#
# On SeaweedFS that deletes the OBJECTS but leaves the DIRECTORY ENTRIES.
# Removing a directory entry requires the filer:  weed shell -> fs.rm -r
#
# --------------------------------------------------------------------------
# WHY THIS TAKES A SITE ARGUMENT NOW
#
# Every name here used to be hardcoded from the pre-consolidation layout:
# namespace `seaweedfs` with `deploy/seaweedfs`, `deploy/xnat-ingest-upload`,
# `deploy/s3-uploader`, and a single fleet-wide bucket `ingest-bucket`. The Helm
# consolidation renamed all of them — `ais-mgmt/mgmt-seaweedfs`,
# `xnat-upload/mgmt-upload-<edge>`, `xnat-ingest/edge-s3-uploader` — and made
# buckets per-site (`ingest-<edge>`).
#
# NONE of that produced an error, because every call was `|| true` or
# `2>/dev/null`: the script printed its normal output, reported "removed 0 empty
# prefixes", and changed nothing. docs/alerting-architecture.md prescribes it as
# THE remediation for the alert storm above, so the operator would have run it,
# believed it worked, and watched the alerts continue.
#
# So: resources are DISCOVERED BY LABEL (component=seaweedfs / component=upload
# + edge=<name> / component=s3-uploader), which survives a release rename, and
# every lookup and every deletion is checked. This script now fails loudly
# rather than doing nothing quietly.
# =============================================================================
set -euo pipefail
# Helpers only. This script resolves the edge and its bucket from
# sites/<site>/values.yaml below, so there is nothing for the common config
# loader to contribute — and while it still loaded config/management.env, this
# script could not start at all on a checkout that had none. It is the
# documented remediation for a staged-data alert, so "exits 1 before doing
# anything" was the worst possible failure mode.
AIS_NO_CONFIG=1 source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

MGMT_NS="ais-mgmt"
UPLOAD_NS="xnat-upload"
EDGE_NS="xnat-ingest"

SITE=""; EDGE=""; MODE="safe"
for arg in "$@"; do
    case "$arg" in
        --all) MODE="--all" ;;
        -*)    echo "unknown flag: $arg" >&2; exit 1 ;;
        *)     if [ -z "$SITE" ]; then SITE="$arg"; else EDGE="$arg"; fi ;;
    esac
done

[ -n "$SITE" ] || {
    echo "usage: $0 <site> [edge] [--all]" >&2
    echo "       <site> is a directory under sites/ — the same one install.sh takes." >&2
    exit 1
}
VALUES="${REPO_DIR}/sites/${SITE}/values.yaml"
[ -f "$VALUES" ] || { echo "ERROR: no such site: ${VALUES}" >&2; exit 1; }

# --- resolve the edge and its bucket from the SITE FILE, not from guesses -----
read -r EDGE BUCKET <<EOF
$(python3 - "$VALUES" "$EDGE" <<'PY'
import sys, yaml
vals = yaml.safe_load(open(sys.argv[1])) or {}
want = sys.argv[2] if len(sys.argv) > 2 else ""
edges = [e for e in (vals.get("edges") or []) if e.get("name")]
if not edges:
    sys.exit("ERROR: sites/<site>/values.yaml declares no edges")
if want:
    match = [e for e in edges if e["name"] == want]
    if not match:
        sys.exit("ERROR: no edge %r in this site (have: %s)" % (want, ", ".join(e["name"] for e in edges)))
    edge = match[0]
elif len(edges) == 1:
    edge = edges[0]
else:
    sys.exit("ERROR: this site has %d edges (%s) — name the one you mean"
             % (len(edges), ", ".join(e["name"] for e in edges)))
sw = vals.get("seaweedfs") or {}
# perSiteBuckets is the default and the only isolation boundary SeaweedFS has;
# a shared bucket would let any edge's credential read every other edge's data.
if sw.get("perSiteBuckets", True):
    bucket = "ingest-%s" % edge["name"]
else:
    bucket = ((sw.get("buckets") or {}).get("ingest")) or "ingest-bucket"
print(edge["name"], bucket)
PY
)
EOF
[ -n "${EDGE:-}" ] || exit 1

echo "=== clear-staged-s3: site=${SITE} edge=${EDGE} bucket=${BUCKET} ==="

# --- discover the workloads, by label ----------------------------------------
need_deploy() {   # need_deploy <kubectl-prefix> <namespace> <label> <what>
    local out
    out=$($1 get deploy -n "$2" -l "$3" -o name 2>/dev/null | head -1)
    [ -n "$out" ] || {
        echo "ERROR: no Deployment with label '$3' in namespace '$2' — cannot $4." >&2
        echo "       Is this site installed? Try: scripts/verify-live.sh ${SITE}" >&2
        exit 1
    }
    echo "$out"
}

EDGE_KC="${EDGE_KUBECONFIG:-${REPO_DIR}/kubeconfig-${EDGE}}"
[ -f "$EDGE_KC" ] || {
    echo "ERROR: edge kubeconfig not found: ${EDGE_KC}" >&2
    echo "       Needed to run rclone in the edge uploader to COUNT objects." >&2
    exit 1
}
KEDGE="kubectl --kubeconfig=$EDGE_KC"

SEAWEED=$(need_deploy "kubectl" "$MGMT_NS" "component=seaweedfs" "reach the filer")
UPLOADER=$(need_deploy "kubectl" "$UPLOAD_NS" "component=upload,edge=${EDGE}" "restart the uploader")
EDGE_UPLOADER=$(need_deploy "$KEDGE" "$EDGE_NS" "component=s3-uploader" "count objects")
echo "  filer     : ${MGMT_NS}/${SEAWEED}"
echo "  uploader  : ${UPLOAD_NS}/${UPLOADER}"
echo "  counting via ${EDGE_NS}/${EDGE_UPLOADER} on the edge"
echo

# Counting uses the S3 client in the edge uploader pod — an authoritative object
# listing — NOT `weed shell` output. weed shell prints its prompt inline
# ("> FIRST_ENTRY"), and an earlier version filtered those lines out, which made
# a session that HELD DATA look empty and deleted it. Never decide a deletion
# from weed-shell text.
#
# THE CLIENT IN THAT POD HAS CHANGED TWICE NOW, AND EACH TIME THIS SCRIPT WAS
# THE THING THAT BROKE.
#   mc -> aws:     every call was `2>/dev/null`, so `mc: command not found` was
#                  invisible. The listing came back empty, and an empty listing
#                  is indistinguishable from "no staged sessions" — the script
#                  reported "removed 0, kept 0" against a bucket that held a
#                  session.
#   aws -> rclone: `aws` is still IN the image (it is the uploader's userland),
#                  but AWS_ENDPOINT_URL and the AWS_* credentials are no longer
#                  on the pod, so `aws --endpoint-url ""` would have failed on
#                  every call. Loudly, thanks to the fix above — but failed.
# Both are the same lesson: this script reads its S3 client out of a pod it does
# not own. Read charts/edge/templates/upload.yaml before assuming a binary or an
# env var is there.
#
# `sw:` is the remote the uploader Deployment defines through RCLONE_CONFIG_SW_*;
# there is no rclone.conf to point at. rclone lives at /opt/rclone (staged by
# the initContainer) and is NOT on the default PATH of that image, so it is
# called by absolute path — the uploader script gets it via its own PATH
# prepend, which a `kubectl exec` does not inherit.
#
# Default log level, deliberately not --log-level ERROR: measured, an
# AccessDenied listing under `--log-level ERROR` exits 1 and prints NOTHING at
# all, which would hand the operator a bare failure with no reason. At the
# default level the same call prints "Failed to lsf: ... AccessDenied". The one
# NOTICE it adds on every call ("Config file not found - using defaults") is
# expected and goes to stderr, clear of the listings parsed below.
RCLONE() { $KEDGE -n "$EDGE_NS" exec "$EDGE_UPLOADER" -- /opt/rclone/rclone "$@"; }

# Deletion goes through the filer: only `fs.rm -r` removes the directory ENTRY.
# Checked, not `|| true` — a filer that refuses must not read as success.
WEED() {
    kubectl -n "$MGMT_NS" exec "$SEAWEED" -- \
        sh -c "printf '%s\n' '$1' | weed shell" 2>&1
}

# Session prefixes, one bare name per line. `--dirs-only` asks rclone for the
# prefixes directly instead of parsing them out of a human listing, which is
# what the old `awk '/PRE /'` was doing against `aws s3 ls`.
# A FAILED listing must never look like an empty bucket — abort instead.
s3ls() {
    local out rc err
    err=$(mktemp)
    out=$(RCLONE lsf "sw:${BUCKET}/staged/" --dirs-only 2>"$err"); rc=$?
    if [ $rc -ne 0 ]; then
        echo "ERROR: could not list sw:${BUCKET}/staged/ from ${EDGE_UPLOADER}:" >&2
        sed 's/^/       /' "$err" >&2
        echo "       Refusing to continue: an unreadable listing is not an empty one." >&2
        rm -f "$err"
        exit 1
    fi
    rm -f "$err"
    printf '%s\n' "$out" | sed 's#/$##' | grep -v '^$' || true
}

# Authoritative recursive object count; echoes ERR if the command failed, and
# the caller KEEPS the prefix on ERR.
#
# THE THREE-WAY rc TEST THAT USED TO LIVE HERE IS GONE BECAUSE THE AMBIGUITY IS.
# `aws s3 ls` did not exit 0 on an empty prefix — it exited 1 with no output,
# indistinguishable by exit code from a broken call, so this function had to
# separate "rc=1 and silent" (empty) from "rc=1 and noisy" (broken). Getting
# that wrong marked every empty prefix "count FAILED", and the fail-safe then
# KEPT it — the one thing this script exists to remove was the one thing it
# could never remove.
#
# MEASURED for `rclone lsf -R --files-only` against SeaweedFS 4.34:
#
#   prefix holding objects   rc=0    one line per object on stdout
#   EMPTY / absent prefix    rc=0    no output   <- the ambiguity, resolved
#   credential cannot see it rc=1    reason on STDERR, stdout empty
#   endpoint unreachable     rc=1    reason on STDERR, stdout empty
#
# So the exit code alone is now the authoritative/failed signal, and stdout is
# only ever data. Keep it that way: do NOT fold stderr into stdout here. That
# `2>&1` is precisely what forced the old three-way test, because it also
# swept in `kubectl exec`'s own "command terminated with exit code 1" line and
# made a silent failure look like output.
s3count() {
    local out rc err
    err=$(mktemp)
    out=$(RCLONE lsf "sw:${BUCKET}/staged/$1/" -R --files-only 2>"$err"); rc=$?
    rm -f "$err"
    if [ $rc -ne 0 ]; then
        echo "ERR"
        return
    fi
    # Tested explicitly rather than piped through `grep -c`. On no match grep
    # PRINTS 0 and EXITS 1, so the old `... | grep -c ... || echo 0` emitted a
    # SECOND zero — and now that rc=0 can mean "empty", the caller would read
    # "0\n0", match neither "0" nor "ERR", and report the prefix as holding
    # objects. Every empty prefix would then be kept forever, which is the same
    # bug the aws-era rc handling above was written to fix.
    if [ -z "$out" ]; then
        echo 0
    else
        printf '%s\n' "$out" | grep -c '[^[:space:]]'
    fi
}

filer_rm() {
    local path="/buckets/${BUCKET}/staged/$1"
    if ! WEED "fs.rm -r ${path}" >/dev/null; then
        echo "  WARNING: filer refused to remove ${path}" >&2
        return 1
    fi
}

FAILED=0
if [ "$MODE" = "--all" ]; then
    echo "!!! DESTRUCTIVE MODE: wiping ALL of s3://${BUCKET}/staged !!!"
    echo "    Sessions that have NOT yet been uploaded to XNAT will be lost from"
    echo "    staging. (Originals still exist in the edge facility backup.)"
    echo "    Use this only to reset a demo/test environment."
    if [ "${AIS_AUTO_CONFIRM:-}" != "yes" ]; then
        read -rp "    Type 'wipe' to continue: " REPLY
        [ "$REPLY" = "wipe" ] || { echo "aborted"; exit 1; }
    fi
    if WEED "fs.rm -r /buckets/${BUCKET}/staged" >/dev/null; then
        echo "  staged/ wiped."
    else
        echo "  ERROR: the filer refused to wipe staged/ — nothing was removed." >&2
        exit 1
    fi
else
    echo "=== Safe clean of s3://${BUCKET}/staged — EMPTY prefixes only ==="
    EMPTY=0; KEPT=0
    # CAPTURED FIRST, ON ITS OWN LINE. `for p in $(s3ls)` runs s3ls in a
    # command-substitution SUBSHELL, so the `exit 1` it takes on an unreadable
    # listing kills only that subshell — `set -e` never sees it, the loop
    # iterates zero times, and the script goes on to print "removed 0 empty
    # prefix(es); kept 0 session(s) with data" and exit 0. Measured: that is
    # exactly the silent no-op the abort was added to prevent, and the abort
    # could not prevent it from inside a `$( )`. As a plain assignment the
    # substitution's status IS the command status, and set -e stops here.
    PREFIXES=$(s3ls)
    for p in $PREFIXES; do
        n=$(s3count "$p")
        # FAIL-SAFE: if the count cannot be determined, KEEP. Never delete on
        # uncertainty.
        if [ "$n" = "ERR" ]; then
            echo "  KEEPING (count FAILED)  : $p   <- never delete on uncertainty"
            KEPT=$((KEPT+1)); continue
        fi
        if [ "$n" = "0" ]; then
            echo "  removing EMPTY prefix : $p"
            if filer_rm "$p"; then EMPTY=$((EMPTY+1)); else FAILED=$((FAILED+1)); fi
        else
            echo "  KEEPING (${n} objects) : $p   <- may not be uploaded to XNAT yet"
            KEPT=$((KEPT+1))
        fi
    done
    echo
    echo "  removed ${EMPTY} empty prefix(es); kept ${KEPT} session(s) with data."
    [ "$FAILED" -gt 0 ] && echo "  ${FAILED} removal(s) FAILED — see the warnings above." >&2
    [ "$KEPT" -gt 0 ] && {
        echo "  NOTE: kept sessions will keep being re-processed each 60s loop"
        echo "        (the uploader has no S3 retention). That is correct while"
        echo "        they are undelivered. Once XNAT has them they are safe to"
        echo "        remove with: bash scripts/clear-staged-s3.sh ${SITE} ${EDGE} --all"
    }
fi

echo
echo "--- restarting ${UPLOADER} so the next loop starts from a clean listing ---"
kubectl -n "$UPLOAD_NS" rollout restart "$UPLOADER"
kubectl -n "$UPLOAD_NS" rollout status "$UPLOADER" --timeout=180s 2>&1 | tail -1

echo
echo "=== verify ==="
echo "  kubectl -n ${UPLOAD_NS} logs ${UPLOADER} --since=3m | grep -E 'Found [0-9]+ sessions'"
echo "  (repeated 'Successfully uploaded' for the SAME session every ~60s means"
echo "   empty prefixes remain — re-run this script)"

exit $([ "$FAILED" -gt 0 ] && echo 1 || echo 0)
