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
    echo "       Needed to run 'mc' in the edge uploader to COUNT objects." >&2
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

# Counting uses the AWS CLI from the edge uploader pod — an authoritative object
# listing — NOT `weed shell` output. weed shell prints its prompt inline
# ("> FIRST_ENTRY"), and an earlier version filtered those lines out, which made
# a session that HELD DATA look empty and deleted it. Never decide a deletion
# from weed-shell text.
#
# `mc` USED TO BE THE TOOL AND IS NOT INSTALLED ANY MORE. The consolidated
# uploader runs amazon/aws-cli, which has `aws` and python3 and no `mc` at all.
# Every call here was `2>/dev/null`, so `mc: command not found` was invisible:
# the listing came back empty, and an empty listing is indistinguishable from
# "no staged sessions" — the script reported "removed 0, kept 0" against a
# bucket that held a session, which is the same quiet no-op as the stale names.
# Errors are surfaced now, and an unreadable listing aborts instead of reading
# as "nothing to do".
AWSCLI() { $KEDGE -n "$EDGE_NS" exec "$EDGE_UPLOADER" -- \
             sh -c "aws --endpoint-url \"\$AWS_ENDPOINT_URL\" $1"; }

# Deletion goes through the filer: only `fs.rm -r` removes the directory ENTRY.
# Checked, not `|| true` — a filer that refuses must not read as success.
WEED() {
    kubectl -n "$MGMT_NS" exec "$SEAWEED" -- \
        sh -c "printf '%s\n' '$1' | weed shell" 2>&1
}

# Session prefixes. `aws s3 ls` prints them as "   PRE <name>/".
# A FAILED listing must never look like an empty bucket — abort instead.
s3ls() {
    local out rc
    out=$(AWSCLI "s3 ls s3://${BUCKET}/staged/" 2>&1); rc=$?
    if [ $rc -ne 0 ]; then
        echo "ERROR: could not list s3://${BUCKET}/staged/ from ${EDGE_UPLOADER}:" >&2
        printf '%s\n' "$out" | sed 's/^/       /' >&2
        echo "       Refusing to continue: an unreadable listing is not an empty one." >&2
        exit 1
    fi
    printf '%s\n' "$out" | awk '/PRE /{print $NF}' | sed 's#/$##' | grep -v '^$' || true
}

# Authoritative recursive object count; echoes ERR if the command failed, and
# the caller KEEPS the prefix on ERR.
#
# `aws s3 ls` DOES NOT EXIT 0 ON AN EMPTY PREFIX. Measured against this cluster:
#
#   prefix holding objects   rc=0    one line per object
#   EMPTY prefix             rc=1    no output at all
#   genuinely broken call    rc=255  "Could not connect to the endpoint URL..."
#
# Treating any non-zero rc as failure therefore marked every empty prefix
# "count FAILED", and the fail-safe then KEPT it — so the one thing this script
# exists to remove was the one thing it could never remove. Separate the three:
# only rc=1 WITH no output is an empty prefix.
#
# `kubectl exec` ALSO WRITES ITS OWN LINE. When the remote command exits
# non-zero it prints "command terminated with exit code 1" on stderr, so with
# 2>&1 the output of an empty prefix is not empty and the test above still fell
# through to ERR. Strip kubectl's own diagnostic before deciding.
kubectl_noise() { grep -v '^command terminated with exit code [0-9]*$' || true; }

s3count() {
    local out rc body
    out=$(AWSCLI "s3 ls --recursive s3://${BUCKET}/staged/$1/" 2>&1); rc=$?
    body=$(printf '%s\n' "$out" | kubectl_noise | tr -d '[:space:]')
    if [ $rc -eq 0 ]; then
        printf '%s\n' "$out" | kubectl_noise | grep -c '[^[:space:]]' || echo 0
    elif [ $rc -eq 1 ] && [ -z "$body" ]; then
        echo 0
    else
        echo "ERR"
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
    for p in $(s3ls); do
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
