#!/usr/bin/env bash
# =============================================================================
# Clean the SeaweedFS staging prefix WITHOUT destroying un-uploaded sessions.
# =============================================================================
# DEFAULT MODE (safe, production-safe): removes ONLY *empty* session prefixes
# — 0-byte directory entries that hold no objects. Sessions that still contain
# files are LEFT ALONE, because a staged session may not have reached XNAT yet
# (XNAT down, credential problem, backlog); deleting those would lose data that
# has not yet been delivered.
#
#   bash scripts/clear-staged-s3.sh                # safe: empty prefixes only
#   bash scripts/clear-staged-s3.sh --all          # DESTRUCTIVE: wipe staged/
#
# --------------------------------------------------------------------------
# WHY EMPTY PREFIXES MATTER
#
# `xnat-ingest upload` has no S3 retention: it rebuilds its work list from a
# live listing of s3://<bucket>/staged every --loop pass. An EMPTY prefix is
# still listed as a session; the uploader "uploads" its zero resources and
# logs
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
# =============================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/00-common.sh"

BUCKET="${S3_BUCKET:-ingest-bucket}"
MODE="${1:-safe}"

# --------------------------------------------------------------------------
# Counting is done with `mc ls --recursive` (authoritative object listing) from
# the edge s3-uploader pod, NOT by parsing `weed shell` output. weed shell
# prints its prompt inline ("> FIRST_ENTRY"), and an earlier version of this
# script filtered those lines out — which made a session that HELD DATA look
# empty and deleted it. Never decide a deletion from weed-shell text.
#
# Deletion still has to go through the filer, because only `fs.rm -r` removes
# the directory ENTRY (mc removes objects but leaves a 0-byte prefix behind).
#
# FAIL-SAFE: if the object count cannot be determined for any reason, the
# prefix is KEPT. We never delete on uncertainty.
# --------------------------------------------------------------------------
EDGE_KC="${EDGE_KUBECONFIG:-}"
if [ -z "$EDGE_KC" ]; then
    EDGE_KC=$(ls "${REPO_DIR}"/kubeconfig-* 2>/dev/null | head -1)
fi
if [ ! -f "$EDGE_KC" ]; then
    echo "ERROR: no edge kubeconfig found (set EDGE_KUBECONFIG=...)." >&2
    echo "       Needed to run 'mc' in the edge s3-uploader pod to count objects." >&2
    exit 1
fi
KEDGE="kubectl --kubeconfig=$EDGE_KC"

MC() { $KEDGE -n xnat-ingest exec deploy/s3-uploader -- sh -c "$1" 2>/dev/null; }
WEED() { kubectl -n seaweedfs exec deploy/seaweedfs -- sh -c "printf '$1\n' | weed shell" >/dev/null 2>&1 || true; }

# list session prefixes (mc: one per line, trailing slash)
s3ls() { MC "mc ls edge/${BUCKET}/staged/ 2>/dev/null" | awk '{print $NF}' | sed 's#/$##' | grep -v '^$' || true; }

# authoritative recursive object count; echoes ERR if the command failed
s3count() {
    local out
    out=$(MC "mc ls --recursive edge/${BUCKET}/staged/$1/ 2>/dev/null | wc -l" | tr -d ' \r')
    case "$out" in ''|*[!0-9]*) echo "ERR" ;; *) echo "$out" ;; esac
}

filer_rm() { WEED "fs.rm -r /buckets/${BUCKET}/staged/$1"; }

if [ "$MODE" = "--all" ]; then
    echo "!!! DESTRUCTIVE MODE: wiping ALL of s3://${BUCKET}/staged !!!"
    echo "    Sessions that have NOT yet been uploaded to XNAT will be lost from"
    echo "    staging. (Originals still exist in the edge facility backup.)"
    echo "    Use this only to reset a demo/test environment."
    if [ "${AIS_AUTO_CONFIRM:-}" != "yes" ]; then
        read -p "    Type 'wipe' to continue: " -r REPLY
        [ "$REPLY" = "wipe" ] || { echo "aborted"; exit 1; }
    fi
    kubectl -n seaweedfs exec deploy/seaweedfs -- sh -c \
        "printf 'fs.rm -r /buckets/${BUCKET}/staged\n' | weed shell" >/dev/null 2>&1 || true
    echo "  staged/ wiped."
else
    echo "=== Safe clean of s3://${BUCKET}/staged — EMPTY prefixes only ==="
    EMPTY=0; KEPT=0
    for p in $(s3ls); do
        n=$(s3count "$p")
        if [ "$n" = "ERR" ]; then
            echo "  KEEPING (count FAILED)  : $p   <- never delete on uncertainty"
            KEPT=$((KEPT+1)); continue
        fi
        if [ "$n" = "0" ]; then
            echo "  removing EMPTY prefix : $p"
            filer_rm "$p"; EMPTY=$((EMPTY+1))
        else
            echo "  KEEPING (${n} objects) : $p   <- may not be uploaded to XNAT yet"
            KEPT=$((KEPT+1))
        fi
    done
    echo ""
    echo "  removed ${EMPTY} empty prefix(es); kept ${KEPT} session(s) with data."
    [ "$KEPT" -gt 0 ] && {
        echo "  NOTE: kept sessions will keep being re-processed each 60s loop"
        echo "        (the uploader has no S3 retention). That is correct while"
        echo "        they are undelivered. Once XNAT has them they are safe to"
        echo "        remove with: bash scripts/clear-staged-s3.sh --all"
    }
fi

echo ""
echo "--- restarting xnat-ingest-upload so the next loop starts from a clean listing ---"
kubectl -n xnat-upload rollout restart deploy/xnat-ingest-upload >/dev/null 2>&1 || true
kubectl -n xnat-upload rollout status deploy/xnat-ingest-upload --timeout=180s 2>&1 | tail -1

echo ""
echo "=== verify ==="
echo "  kubectl -n xnat-upload logs deploy/xnat-ingest-upload --since=3m | grep -E 'Found [0-9]+ sessions'"
echo "  (repeated 'Successfully uploaded' for the SAME session every ~60s means"
echo "   empty prefixes remain — re-run this script)"
