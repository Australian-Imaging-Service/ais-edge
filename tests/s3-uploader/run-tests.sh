#!/usr/bin/env bash
# =============================================================================
# s3-uploader test harness
# =============================================================================
#   tests/s3-uploader/run-tests.sh
#
# charts/edge/files/s3-uploader.sh against a stub rclone, over a real tree, one pass
# at a time (PASSES=1). The stub records every call and, during a copy, whether the
# upload-tree writer lock is held and the request file claimed. Each case asserts on
# what is left on disk (the session, the state file, the request files) and on the
# calls, not on log text. The uploader must never delete a session: that is the
# staged-reclaimer's, after its proof.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO/charts/edge/files/s3-uploader.sh"
WORK="${TMPDIR:-/tmp}/s3-uploader-tests"
PASS=0; FAIL=0; FAILED=()
_R=$'\033[31m'; _G=$'\033[32m'; _B=$'\033[1m'; _O=$'\033[0m'
SESS="proj.subj.visit"

run_case() {   # <name> [env...]: setup_<name> writes the fixtures, assert_<name> reads calls.log and the tree
    local name="$1"; shift
    local S="$WORK/$name"; rm -rf "$S"; mkdir -p "$S/data/deidentified/$SESS/1.scan/DICOM" "$S/state/recopy" "$S/locks"
    CASE_DIR="$S"; : > "$S/calls.log"; : > "$S/observed"
    printf 'x' > "$S/data/deidentified/$SESS/1.scan/DICOM/f1.dcm"; printf '{}' > "$S/data/deidentified/$SESS/1.scan/DICOM/__MANIFEST__.json"
    find "$S/data/deidentified/$SESS" -exec touch -d '10 minutes ago' {} +   # settled: nothing written within SETTLE_MINUTES
    HOLD=""; EXPECT_RC=0   # a setup may expect the loop to stop (exit 1): a missing tool, a lock error
    "setup_$name"
    local out rc
    out=$(cd "$S" && env -i PATH="$HERE:/usr/bin:/bin" SCENARIO="$S" HOME="$S" \
          S3_BUCKET=bucket EDGE_NAME=edge-a S3_PREFIX=staged ASSIGNED_DIR="$S/data/deidentified" STATE_DIR="$S/state" \
          PIPELINE_ROOT="$S/data" INTERVAL=0 SETTLE_MINUTES=1 WRITER_LOCK="$S/locks/deidentified.lock" LOCK_WAIT=1 \
          RECOPY_DIR="$S/state/recopy" PASSES=1 STOP_DELAY=0 RCLONE_CONFIG_SW_ENDPOINT=http://stub "$@" bash "$SCRIPT" 2>&1); rc=$?
    [ -n "$HOLD" ] && { kill "$HOLD" 2>/dev/null; wait "$HOLD" 2>/dev/null; }
    printf '%s\n' "$out" > "$S/out.log"
    local ok=1 why=""
    if [ "$rc" != "$EXPECT_RC" ]; then ok=0; why="exit $rc, expected $EXPECT_RC: $(printf '%s' "$out" | tail -1 | cut -c1-120)"
    elif printf '%s' "$out" | grep -qE "unbound variable|command not found|: line [0-9]+:"; then ok=0; why="shell error: $(printf '%s' "$out" | grep -oE '.*(unbound variable|command not found|: line [0-9]+:.*)' | head -1)"
    elif [ ! -d "$S/data/deidentified/$SESS" ]; then ok=0; why="THE SESSION WAS DELETED by the uploader"
    elif declare -F "assert_$name" >/dev/null 2>&1; then
        local extra; if ! extra=$("assert_$name" "$S/calls.log" "$S/out.log" 2>&1); then ok=0; why="$extra"; fi
    fi
    if [ "$ok" = 1 ]; then printf '  %sPASS%s  %-34s\n' "$_G" "$_O" "$name"; PASS=$((PASS+1))
    else printf '  %sFAIL%s  %-34s %s\n' "$_R" "$_O" "$name" "$why"; FAIL=$((FAIL+1)); FAILED+=("$name: $why"); printf '%s\n' "$out" | sed 's/^/          /' | tail -5; fi
}
copies()    { grep -c '^rclone copy ' "$1"; }
flags_ok()  { grep -q -- '^rclone copy .* --copy-links .* --s3-chunk-size 64Mi --s3-max-upload-parts 10000 --s3-use-multipart-etag=true' "$1" || { echo "the copy lacks the contract flags: $(grep '^rclone copy' "$1" | head -1)"; return 1; }; }
observed()  { grep -q -F -- "$1" "$CASE_DIR/observed" || { echo "not observed during the copy: $1 (observed: $(tr '\n' ';' < "$CASE_DIR/observed"))"; return 1; }; }
hold_lock() { ( exec 9>>"$CASE_DIR/locks/deidentified.lock"; flock 9; sleep 30 ) & HOLD=$!; sleep 0.3; }

# A settled session: copied once with the contract flags, under the lock, the state file written, the session kept.
setup_copies_once()  { :; }
assert_copies_once() { [ "$(copies "$1")" = 1 ] && flags_ok "$1" && ! grep -q -- '--ignore-times' "$1" && observed "lock-held $SESS" && [ -s "$CASE_DIR/state/$SESS" ]; }
# The same session on the next pass: unchanged fingerprint, nothing copied, nothing said.
# (The fixture sorts under LC_ALL=C: the script runs under env -i, in the C locale.)
setup_unchanged_skipped()  { printf 'x' > "$CASE_DIR/state/$SESS"; FP=$(cd "$CASE_DIR/data/deidentified/$SESS" && find -L . -type f -exec stat -c '%n %s %Y' {} + | LC_ALL=C sort | md5sum | cut -d' ' -f1); printf '%s\n' "$FP" > "$CASE_DIR/state/$SESS"; }
assert_unchanged_skipped() { [ "$(copies "$1")" = 0 ] && ! grep -q 'upload_' "$2"; }
# The writer lock is busy: the session is skipped this pass, nothing copied, no state file.
setup_lock_busy()  { hold_lock; }
assert_lock_busy() { [ "$(copies "$1")" = 0 ] && grep -q '"event":"upload_skipped".*writer lock' "$2" && [ ! -e "$CASE_DIR/state/$SESS" ]; }
# A repair request for an unchanged session: claimed (renamed) for the copy, copied with --ignore-times, removed on success.
setup_recopy_done()  { setup_unchanged_skipped; printf 'reclaimer: f1.dcm not_in_s3\n' > "$CASE_DIR/state/recopy/$SESS"; }
assert_recopy_done() { [ "$(copies "$1")" = 1 ] && grep -q -- '--ignore-times' "$1" && observed "claimed $SESS" && [ ! -e "$CASE_DIR/state/recopy/$SESS" ] && [ ! -e "$CASE_DIR/state/recopy/$SESS.claimed" ] && grep -q '"event":"recopy_done"' "$2"; }
# The copy of a request fails: the request goes back to pending.
setup_recopy_failed()  { setup_recopy_done; : > "$CASE_DIR/copy.fail"; }
assert_recopy_failed() { grep -q '"event":"upload_failed"' "$2" && [ -s "$CASE_DIR/state/recopy/$SESS" ] && [ ! -e "$CASE_DIR/state/recopy/$SESS.claimed" ]; }
# A request written DURING the copy keeps the plain name and survives the success.
setup_request_during_copy()  { setup_recopy_done; : > "$CASE_DIR/request.during"; }
assert_request_during_copy() { [ "$(copies "$1")" = 1 ] && [ -s "$CASE_DIR/state/recopy/$SESS" ] && grep -q during-copy "$CASE_DIR/state/recopy/$SESS" && [ ! -e "$CASE_DIR/state/recopy/$SESS.claimed" ]; }
# A request claimed by a run that died: back to pending at start-up, then served.
setup_claimed_at_startup()  { setup_unchanged_skipped; printf 'old\n' > "$CASE_DIR/state/recopy/$SESS.claimed"; }
assert_claimed_at_startup() { grep -q '"event":"recopy_requeued"' "$2" && [ "$(copies "$1")" = 1 ] && grep -q -- '--ignore-times' "$1" && [ ! -e "$CASE_DIR/state/recopy/$SESS.claimed" ] && [ ! -e "$CASE_DIR/state/recopy/$SESS" ]; }
# The endpoint probe fails before the copy: the request goes back to pending.
setup_probe_fails_request_kept()  { setup_recopy_done; echo once > "$CASE_DIR/lsd.fail.pending"; }
assert_probe_fails_request_kept() { [ "$(copies "$1")" = 0 ] && [ -s "$CASE_DIR/state/recopy/$SESS" ] && [ ! -e "$CASE_DIR/state/recopy/$SESS.claimed" ]; }
# A session still being written (younger than the settle window) is not copied.
setup_unsettled()  { touch "$CASE_DIR/data/deidentified/$SESS/1.scan/DICOM/f1.dcm"; }
assert_unsettled() { [ "$(copies "$1")" = 0 ]; }
# The script deletes nothing, ever: no rm of a session anywhere in it.
setup_no_delete_in_script()  { :; }
assert_no_delete_in_script() { ! grep -qE 'rm -rf? +"?\$session_dir' "$SCRIPT" || { echo "the script removes a session"; return 1; }; }

# --- the tools, checked by use at startup; a lock error is never contention ----------------
# A PATH with every tool but flock (what amazon/aws-cli:2.31.19 gave the loop): it stops
# before its first session, names the tool, and never reads the gap as a busy lock.
tools_without() {   # <tool>: $CASE_DIR/bin links every executable of /usr/bin and /bin except <tool>
    local d="$CASE_DIR/bin" p f; mkdir -p "$d"
    for p in /usr/bin /bin; do for f in "$p"/*; do [ -f "$f" ] && [ -x "$f" ] && [ "${f##*/}" != "$1" ] && ln -sf "$f" "$d/${f##*/}"; done; done
}
setup_tool_missing()  { tools_without flock; EXPECT_RC=1; }
assert_tool_missing() { grep -q '"event":"dependency_missing".* flock.*refusing to start upload loop' "$2" && ! grep -q 'upload_' "$2" && [ ! -e "$CASE_DIR/state/$SESS" ]; }
# busybox flock answers to the name and has no -w and no -E: caught by use, not by name.
setup_tool_busybox_flock() {
    mkdir -p "$CASE_DIR/bin"
    printf '#!/usr/bin/env bash\ncase " $* " in *" -w "*|*" -E "*) echo "flock: unrecognized option" >&2; exit 1 ;; esac\nexec /usr/bin/flock "$@"\n' > "$CASE_DIR/bin/flock"
    chmod +x "$CASE_DIR/bin/flock"; EXPECT_RC=1
}
assert_tool_busybox_flock() { grep -q '"event":"dependency_missing".*flock(-w,-E)' "$2" && ! grep -q 'upload_' "$2"; }
# The lock file cannot be opened: lock_failed, the loop stops, the request goes back to pending.
setup_lock_open_error()  { setup_recopy_done; EXPECT_RC=1; }
assert_lock_open_error() { [ "$(copies "$1")" = 0 ] && grep -q '"event":"lock_failed".*cannot open' "$2" && ! grep -q '"event":"upload_skipped"' "$2" && [ -s "$CASE_DIR/state/recopy/$SESS" ] && [ ! -e "$CASE_DIR/state/recopy/$SESS.claimed" ]; }
# flock fails after the startup probe passed, and not with the timeout exit: the same.
setup_lock_exec_error() {
    mkdir -p "$CASE_DIR/bin"
    printf '#!/usr/bin/env bash\n[ -e "$SCENARIO/flock.probed" ] && exit 1\n: > "$SCENARIO/flock.probed"\nexec /usr/bin/flock "$@"\n' > "$CASE_DIR/bin/flock"
    chmod +x "$CASE_DIR/bin/flock"; EXPECT_RC=1
}
assert_lock_exec_error() { [ "$(copies "$1")" = 0 ] && grep -q '"event":"lock_failed".*exit 1,' "$2" && ! grep -q '"event":"upload_skipped"' "$2" && [ ! -e "$CASE_DIR/state/$SESS" ]; }

printf '%s== s3-uploader ==%s\n' "$_B" "$_O"
run_case copies_once
run_case unchanged_skipped
run_case lock_busy
run_case recopy_done
run_case recopy_failed
run_case request_during_copy
run_case claimed_at_startup
run_case unsettled
run_case no_delete_in_script
run_case tool_missing        PATH="$HERE:$WORK/tool_missing/bin"
run_case tool_busybox_flock  PATH="$WORK/tool_busybox_flock/bin:$HERE:/usr/bin:/bin"
run_case lock_open_error     WRITER_LOCK=/proc/no-such-dir/deidentified.lock
run_case lock_exec_error     PATH="$WORK/lock_exec_error/bin:$HERE:/usr/bin:/bin"
printf '\n%ss3-uploader: %d passed, %d failed%s\n' "$_B" "$PASS" "$FAIL" "$_O"
if [ "$FAIL" -gt 0 ]; then printf '%sFAILURES:%s\n' "$_R" "$_O"; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
