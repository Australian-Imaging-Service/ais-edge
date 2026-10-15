#!/usr/bin/env bash
# =============================================================================
# s3-uploader image tests: the loop INSIDE the image the chart ships it in
# =============================================================================
#   tests/s3-uploader/image-tests.sh
#   CI_REQUIRE_UPLOADER_IMAGE=1   a skipped run (no docker) becomes a failure
#
# run-tests.sh proves the loop's logic with the host's bash and tools, so it
# cannot see what the pinned image lacks. amazon/aws-cli:2.31.19 had no flock:
# every copy on the test edge was skipped as lock contention for five hours,
# and the suite was green (2026-10-14). This runs charts/edge/files/s3-uploader.sh
# inside upload.s3.shell.image, with the rclone binary lifted out of
# upload.s3.image the way the initContainer lifts it, over a real session tree
# (a regular file and a symlink, as assign builds them), one pass. rclone's
# local backend stands in for the bucket: rclone takes the S3 flags for any
# backend, so the copy line runs unchanged. The assertions are the copy, not the
# log text: the objects and their bytes, the state file, the session still there.
#
# THE SCRIPT IS NEVER COPIED HERE. It is bind-mounted from charts/edge/files/.
# The images are read from values.yaml, so this cannot drift onto others.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/charts/edge/files/s3-uploader.sh"
_G=$'\033[32m'; _R=$'\033[31m'; _Y=$'\033[33m'; _B=$'\033[1m'; _O=$'\033[0m'
PASS=0; FAIL=0; FAILED=()
pass() { PASS=$((PASS+1)); printf '  %sPASS%s  %-30s %s\n' "$_G" "$_O" "$1" "$2"; }
fail() { FAIL=$((FAIL+1)); FAILED+=("$1: $2"); printf '  %sFAIL%s  %-30s %s\n' "$_R" "$_O" "$1" "$2"; }

if ! command -v docker >/dev/null 2>&1 || ! docker ps >/dev/null 2>&1; then
    printf '%sSKIP%s  s3-uploader-image: docker unusable, so the loop was NOT run in its image\n' "$_Y" "$_O"
    [ "${CI_REQUIRE_UPLOADER_IMAGE:-0}" = "1" ] && exit 1
    exit 0
fi
read -r SHELL_IMAGE RCLONE_IMAGE < <(python3 -c "
import yaml
s3 = yaml.safe_load(open('$REPO/charts/edge/values.yaml'))['upload']['s3']
print(s3['shell']['image']['repository'] + ':' + s3['shell']['image']['tag'], s3['image']['repository'] + ':' + s3['image']['tag'])")
[ -n "${SHELL_IMAGE:-}" ] && [ -n "${RCLONE_IMAGE:-}" ] || { echo "cannot read the images from charts/edge/values.yaml" >&2; exit 2; }
printf '%s== s3-uploader inside %s, rclone from %s ==%s\n' "$_B" "$SHELL_IMAGE" "$RCLONE_IMAGE" "$_O"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Every container runs as this user, so the tree, the lock and the state it
# writes are ours to read and remove afterwards.
ME="$(id -u):$(id -g)"
SESS="proj.subj.visit"

# The binary, lifted exactly as charts/edge/templates/upload.yaml lifts it.
mkdir -p "$WORK/rclone-bin"
docker run --rm --user "$ME" -v "$WORK/rclone-bin:/opt/rclone" --entrypoint /bin/sh "$RCLONE_IMAGE" \
    -c "cp /usr/local/bin/rclone /opt/rclone/rclone" >/dev/null 2>&1 \
    && [ -x "$WORK/rclone-bin/rclone" ] || { echo "cannot lift rclone out of $RCLONE_IMAGE" >&2; exit 2; }

# A session as assign leaves it: one regular file, one symlink into another
# folder of the pipeline volume, the manifest; quiet for longer than the settle
# window.
build_case() {   # <dir>
    local d="$1/deidentified/$SESS/1.scan/DICOM"
    rm -rf "$1"; mkdir -p "$d" "$1/targets" "$1/bucket" "$1/state/recopy" "$1/locks"
    head -c 4096 /dev/urandom > "$d/f1.dcm"
    head -c 4096 /dev/urandom > "$1/targets/f2.dcm"
    ln -s ../../../../targets/f2.dcm "$d/f2.dcm"
    printf '{"datatype":"medimage/dicom-series","checksums":{}}' > "$d/__MANIFEST__.json"
    find "$1/deidentified" "$1/targets" -exec touch -h -d '10 minutes ago' {} +
}
run_loop() {   # <case dir> <extra docker args...>: one pass of the loop inside the shell image; output in out.log
    local d="$1"; shift
    docker run --rm --user "$ME" \
        -v "$SCRIPT:/scripts/s3-uploader.sh:ro" -v "$WORK/rclone-bin:/opt/rclone:ro" -v "$d:/data" \
        -e S3_BUCKET=/data/bucket -e EDGE_NAME=edge-a -e S3_PREFIX=staged -e ASSIGNED_DIR=/data/deidentified \
        -e STATE_DIR=/data/state -e PIPELINE_ROOT=/data -e INTERVAL=0 -e SETTLE_MINUTES=1 \
        -e WRITER_LOCK=/data/locks/deidentified.lock -e LOCK_WAIT=5 -e RECOPY_DIR=/data/state/recopy -e PASSES=1 \
        -e RCLONE_CONFIG_SW_TYPE=local -e HOME=/tmp -e STOP_DELAY=0 "$@" \
        "$SHELL_IMAGE" /bin/bash /scripts/s3-uploader.sh > "$d/out.log" 2>&1
}

# 1. One copy, with the real image's tools and the real rclone.
C="$WORK/copy"; build_case "$C"
if run_loop "$C"; then
    B="$C/bucket/staged/$SESS/1.scan/DICOM"
    if ! grep -q '"event":"upload_completed"' "$C/out.log"; then fail copy_completes "no upload_completed: $(tail -1 "$C/out.log")"
    elif grep -qE '"event":"(dependency_missing|lock_failed|upload_skipped|upload_failed)"' "$C/out.log"; then fail copy_completes "$(grep -oE '"event":"[a-z_]*"' "$C/out.log" | tr '\n' ' ')"
    elif [ ! -f "$B/f1.dcm" ] || ! cmp -s "$B/f1.dcm" "$C/deidentified/$SESS/1.scan/DICOM/f1.dcm"; then fail copy_completes "f1.dcm is not in the bucket with its bytes"
    elif [ ! -f "$B/f2.dcm" ] || ! cmp -s "$B/f2.dcm" "$C/targets/f2.dcm"; then fail copy_completes "the symlinked f2.dcm is not in the bucket with its target's bytes (--copy-links)"
    elif [ ! -f "$B/__MANIFEST__.json" ]; then fail copy_completes "the manifest is not in the bucket"
    elif ! grep -qE '^[0-9a-f]{32}$' "$C/state/$SESS" 2>/dev/null; then fail copy_completes "no fingerprint in the state file"
    elif [ ! -f "$C/deidentified/$SESS/1.scan/DICOM/f1.dcm" ]; then fail copy_completes "THE SESSION WAS DELETED by the uploader"
    elif ! grep -q '"files":3,"dicoms":2' "$C/out.log"; then fail copy_completes "the counts are not files 3, dicoms 2: $(grep -o '"files":[0-9]*,"dicoms":[0-9]*' "$C/out.log" | head -1)"
    else pass copy_completes "upload_completed, 3 objects with the source bytes, state file written, session kept"
    fi
else
    fail copy_completes "the loop exited $?: $(grep -oE '"event":"[a-z_]*"[^}]*' "$C/out.log" | tail -1 | cut -c1-160)"
fi

# 2. The same session on a second pass: unchanged fingerprint, nothing copied,
#    nothing said. The state file came from pass 1.
if [ -s "$C/state/$SESS" ] && run_loop "$C" && ! grep -q 'upload_' "$C/out.log"; then
    pass unchanged_is_silent "a second pass over the same tree copies nothing"
else
    fail unchanged_is_silent "$(grep -oE '"event":"[a-z_]*"' "$C/out.log" | tr '\n' ' ')"
fi

# 3. The probe inside this image: a flock that answers to the name and has no
#    -w and no -E (busybox) ahead on the PATH. The loop must stop before any
#    session, naming flock, and must not report a busy lock.
P="$WORK/probe"; build_case "$P"; mkdir -p "$P/bin"
printf '#!/bin/bash\ncase " $* " in *" -w "*|*" -E "*) echo "flock: unrecognized option" >&2; exit 1 ;; esac\nexec /usr/bin/flock "$@"\n' > "$P/bin/flock"
chmod +x "$P/bin/flock"
run_loop "$P" -e PATH=/data/bin:/usr/local/bin:/usr/bin:/bin; rc=$?
if [ "$rc" = 1 ] && grep -q '"event":"dependency_missing".*flock(-w,-E).*refusing to start upload loop' "$P/out.log" && ! grep -q 'upload_' "$P/out.log"; then
    pass probe_catches_busybox_flock "exit 1, dependency_missing names flock, no session touched"
else
    fail probe_catches_busybox_flock "exit $rc: $(grep -oE '"event":"[a-z_]*"' "$P/out.log" | tr '\n' ' ')"
fi

# 4. A lock that cannot be opened inside this image: lock_failed and exit 1, not
#    a skipped session.
L="$WORK/lock"; build_case "$L"
run_loop "$L" -e WRITER_LOCK=/proc/no-such-dir/deidentified.lock; rc=$?
if [ "$rc" = 1 ] && grep -q '"event":"lock_failed"' "$L/out.log" && ! grep -q '"event":"upload_skipped"' "$L/out.log" && [ ! -e "$L/bucket/staged/$SESS" ]; then
    pass lock_error_stops_the_loop "exit 1, lock_failed, nothing copied"
else
    fail lock_error_stops_the_loop "exit $rc: $(grep -oE '"event":"[a-z_]*"' "$L/out.log" | tr '\n' ' ')"
fi

printf '\n%ss3-uploader-image: %d passed, %d failed%s\n' "$_B" "$PASS" "$FAIL" "$_O"
if [ "$FAIL" -gt 0 ]; then printf '%sFAILURES:%s\n' "$_R" "$_O"; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
