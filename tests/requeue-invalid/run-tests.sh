#!/usr/bin/env bash
# =============================================================================
# charts/edge/files/requeue-invalid.py (the chart ships it into the label pod)
# against fixture trees, then the pinned image.
# =============================================================================
# The folder names have the real shape the 0.19.0 label stage writes
# (<project>.<subject>.INVALID_MISSING_<TAG>_<8 letters or digits>, seen live
# on 2026-11-10). Each case asserts on the TREE afterwards (what moved, what
# stayed), not only on the exit code. The last case loads the requeued folder
# with the pinned accessionflow image: the tool must read the new labels from
# the folder name. Without docker that case skips; CI_REQUIRE_REQUEUE_IMAGE=1
# makes it a failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "$HERE/../../scripts/ci/lib.sh"
PY="$REPO_ROOT/charts/edge/files/requeue-invalid.py"
ci_heading "requeue-invalid"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
BAD="test_project.MRN1.INVALID_MISSING_ACCESSIONNUMBER_ognMmX8R"
UID_DIR="1_2_826_0_1_9"

fixture() {   # fixture <root>: one invalid session, as the label stage leaves it
    local r="$1"; rm -rf "$r"
    mkdir -p "$r/assigned/__invalid__/$BAD/1.localizer/DICOM" "$r/grouped" "$r/deidentified" "$r/LOGS" "$r/.locks"
    echo dicom > "$r/assigned/__invalid__/$BAD/1.localizer/DICOM/a.dcm"
    cat > "$r/assigned/__invalid__/$BAD/__METADATA__.json" <<EOF
{"__uid__": "$UID_DIR", "__labels__": {"project": "test_project", "subject": "MRN1", "session": "INVALID_MISSING_ACCESSIONNUMBER_ognMmX8R"},
 "PatientID": "MRN1", "StudyDate": "20261110", "StudyTime": "034148", "StudyDescription": "test_project",
 "Modality": "MR", "AccessionNumber": "", "StudyInstanceUID": "1.2.826.0.1.9"}
EOF
}
run() { python3 "$PY" --root "$R" --operator ci@test --lock-wait 1 "$@" > "$W/out" 2>&1; echo $?; }
expect() {   # expect <name> <want-exit> <got-exit> <grep in output> [path that must exist] [path that must be gone]
    local name="$1" want="$2" got="$3" text="$4" have="${5:-}" gone="${6:-}"
    if [ "$got" != "$want" ]; then ci_fail "$name: exit $got, want $want: $(tail -2 "$W/out" | tr '\n' ' ')"; return; fi
    if [ -n "$text" ] && ! grep -q -- "$text" "$W/out"; then ci_fail "$name: output lacks '$text': $(tail -2 "$W/out" | tr '\n' ' ')"; return; fi
    if [ -n "$have" ] && [ ! -e "$R/$have" ]; then ci_fail "$name: $have is missing"; return; fi
    if [ -n "$gone" ] && [ -e "$R/$gone" ]; then ci_fail "$name: $gone is still there"; return; fi
    ci_pass "$name"
}

R="$W/t"; fixture "$R"
expect "list names the folder and the missing label" 0 "$(run list)" "session=ACCESSIONNUMBER"
expect "show prints the study details for the look-up" 0 "$(run show "$BAD")" "PatientID          MRN1"
expect "requeue refuses without the missing value" 2 "$(run requeue "$BAD")" "give --session" "assigned/__invalid__/$BAD"
expect "requeue refuses an illegal value (space)" 2 "$(run requeue "$BAD" --session 'ACC 1')" "not a legal label" "assigned/__invalid__/$BAD"
expect "requeue refuses a value with a dot" 2 "$(run requeue "$BAD" --session 'ACC.1')" "not a legal label" "assigned/__invalid__/$BAD"
expect "requeue refuses a label that is not missing" 2 "$(run requeue "$BAD" --session ACC1 --subject OTHER)" "is not missing" "assigned/__invalid__/$BAD"
expect "requeue refuses a folder that does not exist" 3 "$(run requeue test_project.MRN9.INVALID_MISSING_ACCESSIONNUMBER_zzzzzzzz --session ACC1)" "no folder"

mkdir -p "$R/grouped/_.$UID_DIR"
expect "requeue refuses while a grouped copy of the study remains" 2 "$(run requeue "$BAD" --session ACC1)" "quarantine it" "assigned/__invalid__/$BAD"
rmdir "$R/grouped/_.$UID_DIR"

mkdir -p "$R/assigned/test_project.MRN1.ACC1"
expect "requeue refuses a name already waiting in assigned/" 2 "$(run requeue "$BAD" --session ACC1)" "already exists" "assigned/__invalid__/$BAD"
expect "--allow-existing still refuses a merge into assigned/" 2 "$(run requeue "$BAD" --session ACC1 --allow-existing)" "cannot be merged" "assigned/__invalid__/$BAD"
rmdir "$R/assigned/test_project.MRN1.ACC1"

mkdir -p "$R/deidentified/test_project.MRN1.ACC1"
expect "requeue refuses a name already downstream" 2 "$(run requeue "$BAD" --session ACC1)" "already exists" "assigned/__invalid__/$BAD"

# The lock: a label pass holds assigned.lock.
python3 -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1],os.O_CREAT|os.O_RDWR); fcntl.flock(fd,fcntl.LOCK_EX); time.sleep(6)' "$R/.locks/assigned.lock" &
holder=$!; sleep 1
expect "requeue waits for the label pass's lock, then gives up" 4 "$(run requeue "$BAD" --session ACC1 --allow-existing)" "assigned.lock is held" "assigned/__invalid__/$BAD"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

expect "requeue --allow-existing moves when the same study is downstream" 0 "$(run requeue "$BAD" --session ACC1 --allow-existing)" '"to": "test_project.MRN1.ACC1"' "assigned/test_project.MRN1.ACC1" "assigned/__invalid__/$BAD"
if grep -q '"event": "invalid_requeued"' "$R/LOGS/requeue-audit.jsonl" 2>/dev/null && grep -q '"operator": "ci@test"' "$R/LOGS/requeue-audit.jsonl"; then
    ci_pass "the audit line names the operator and the move"
else
    ci_fail "no audit line in LOGS/requeue-audit.jsonl"
fi
expect "the files moved untouched" 0 "$(cmp -s "$R/assigned/test_project.MRN1.ACC1/1.localizer/DICOM/a.dcm" <(echo dicom); echo $?)" ""

# THE EDGE COMMAND (scripts/files/ais-requeue): no kubectl, no repository. It finds the
# running label container through k0s ctr and runs the chart's copy of the tool in it.
# A fake k0s on PATH emulates ctr: it lists containers only for the asked namespace,
# reports task states, and runs the real tool on the fixture tree for "tasks exec".
FAKE="$W/fakebin"; mkdir -p "$FAKE"
cat > "$FAKE/k0s" <<'K0S'
#!/bin/sh
[ "$1 $2 $3" = "ctr -n k8s.io" ] || { echo "fake k0s: unexpected $*" >&2; exit 9; }
shift 3
case "$1 $2" in
  "containers ls")
    case "$4" in *"io.kubernetes.container.name\"==assign,labels.\"io.kubernetes.pod.namespace\"==${FAKE_NS:-xnat-ingest}") ;; *) exit 0 ;; esac
    for c in $FAKE_RUNNING $FAKE_STOPPED; do echo "$c"; done ;;
  "tasks ls")
    echo "TASK PID STATUS"
    for c in $FAKE_RUNNING; do echo "$c 101 RUNNING"; done
    for c in $FAKE_STOPPED; do echo "$c 0 STOPPED"; done ;;
  "tasks exec")
    shift 2; [ "$1" = "--exec-id" ] && shift 2
    echo "$1" >> "$FAKE_LOG"; shift
    if [ "$1" = test ]; then [ -z "${FAKE_NO_TOOL:-}" ]; exit $?; fi
    [ "$1 $2" = "python3 /opt/ais-edge/requeue-invalid.py" ] || { echo "fake k0s: unexpected exec $*" >&2; exit 9; }
    shift 2; [ "$1 $2" = "--root /data" ] && shift 2
    exec python3 "$FAKE_TOOL" --root "$FAKE_ROOT" "$@" ;;
  *) echo "fake k0s: unexpected $*" >&2; exit 9 ;;
esac
K0S
printf '#!/bin/sh\n[ "$1" = -u ] && { echo "${FAKE_UID:-0}"; exit 0; }\nexec /usr/bin/id "$@"\n' > "$FAKE/id"
chmod +x "$FAKE/k0s" "$FAKE/id"
CMD="$REPO_ROOT/scripts/files/ais-requeue"
R="$W/e"; fixture "$R"
edge() { PATH="$FAKE:$PATH" FAKE_ROOT="$R" FAKE_TOOL="$PY" FAKE_LOG="$W/exec.log" sh "$CMD" "$@" > "$W/out" 2>&1; echo $?; }
: > "$W/exec.log"
expect "edge command: list runs the chart's tool in the running container" 0 \
  "$(FAKE_RUNNING=c-new FAKE_STOPPED=c-old edge list)" "session=ACCESSIONNUMBER"
grep -qx c-new "$W/exec.log" && ! grep -qx c-old "$W/exec.log" \
  && ci_pass "edge command: the stopped container of an earlier pod is never used" \
  || ci_fail "edge command: exec went to $(sort -u "$W/exec.log" | tr '\n' ' ')"
expect "edge command: AIS_NAMESPACE selects another namespace" 0 \
  "$(AIS_NAMESPACE=site-a FAKE_NS=site-a FAKE_RUNNING=c-a edge list)" "session=ACCESSIONNUMBER"
expect "edge command: no running label container is a clear refusal" 2 \
  "$(FAKE_RUNNING= FAKE_STOPPED=c-old edge list)" "no running label (assign) container"
expect "edge command: a chart without the tool says to upgrade" 2 \
  "$(FAKE_NO_TOOL=1 FAKE_RUNNING=c-new edge list)" "Upgrade the edge release"
expect "edge command: the tool's exit code comes through (3, not found)" 3 \
  "$(FAKE_RUNNING=c-new edge requeue test_project.MRN9.INVALID_MISSING_ACCESSIONNUMBER_zzzzzzzz --session ACC1)" "no folder"
expect "edge command: refuses without sudo" 2 \
  "$(FAKE_UID=1000 FAKE_RUNNING=c-new edge list)" "run it with sudo"
expect "edge command: requeue moves the folder" 0 \
  "$(FAKE_RUNNING=c-new edge requeue "$BAD" --session ACC2)" '"to": "test_project.MRN1.ACC2"' "assigned/test_project.MRN1.ACC2" "assigned/__invalid__/$BAD"
R="$W/t"

# THE REAL TOOL reads the new labels from the folder name.
IMAGE="$(python3 -c "import yaml, sys; i = yaml.safe_load(open(sys.argv[1]))['ingest']['image']; print(i['repository'] + ':' + i['tag'])" "$REPO_ROOT/charts/edge/values.yaml")"
if command -v docker >/dev/null 2>&1 && docker image inspect "$IMAGE" >/dev/null 2>&1; then
    out=$(docker run --rm --network none --memory 512m -v "$R/assigned:/a:ro" --entrypoint python3 "$IMAGE" -c '
from pathlib import Path
from accessionflow.model.accession import Accession
s = Accession.load(Path("/a/test_project.MRN1.ACC1"), require_manifest=False, check_checksums=False)
print(dict(s.labels))' 2>&1 | tail -1)
    if printf '%s' "$out" | grep -q "'session': 'ACC1'" && printf '%s' "$out" | grep -q "'subject': 'MRN1'"; then
        ci_pass "accessionflow loads the requeued folder with the new labels ($out)"
    else
        ci_fail "accessionflow did not read the new labels: $out"
    fi
elif [ "${CI_REQUIRE_REQUEUE_IMAGE:-0}" = "1" ]; then
    ci_fail "$IMAGE unavailable: cannot load the requeued folder with the real tool"
else
    ci_skip "$IMAGE unavailable: the real-tool load was not checked"
fi
ci_summary "requeue-invalid"
