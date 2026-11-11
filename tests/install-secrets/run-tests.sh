#!/usr/bin/env bash
# =============================================================================
# tests/install-secrets/run-tests.sh: install.sh with NO secrets.enc.yaml.
# =============================================================================
# install.sh runs from a scratch copy of the repo against a stub kubectl. The
# stub answers `get secret` from a list, or fails as an unreachable or
# forbidden API. With stdin not a terminal, install.sh runs without prompts
# (-y). The stub fails every other kubectl call, so a run that passes the
# Secrets check stops in step 1 (`kubectl get nodes`): nothing is installed.
#   fresh, no file                       refused, names installMode: existing
#   existing, no file, all Secrets       goes on, step 2 skipped
#   existing, no file, one Secret absent refused, names it
#   existing, no file, API unreachable   refused: an error is not "present"
#   existing, no file, API forbidden     refused the same way
#   existing, no file, chart not render  refused
#   observability on                     its two Secrets are needed too
#   a secrets file (not encrypted)       the old path, unchanged
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/install-secrets-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
_R=$'\033[31m'; _G=$'\033[32m'; _B=$'\033[1m'; _O=$'\033[0m'
PASS=0; FAIL=0; FAILED=()
pass() { PASS=$((PASS + 1)); printf '  %sPASS%s  %s\n' "$_G" "$_O" "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILED+=("$1"); printf '  %sFAIL%s  %s\n' "$_R" "$_O" "$1"; }

for t in helm python3; do
    command -v "$t" >/dev/null 2>&1 || { echo "install-secrets: $t is required"; exit 1; }
done

# --- a scratch repo: the installer, its scripts and the chart --------------------
R="$WORK/repo"
mkdir -p "$R/sites/t" "$WORK/bin"
cp "$REPO/install.sh" "$R/"
cp -r "$REPO/scripts" "$REPO/charts" "$R/"
site() {   # <installMode> [extra python edits]: sites/t/values.yaml from example-single
    python3 - "$REPO/sites/example-single/values.yaml" "$R/sites/t/values.yaml" "$1" "${2:-}" <<'PY'
import sys, yaml
src, dst, mode, extra = sys.argv[1:5]
v = yaml.safe_load(open(src))
v["nodeIP"] = "192.0.2.10"
v["installMode"] = mode
v.setdefault("deid", {})["policyReviewed"] = True
v.setdefault("observability", {}).setdefault("stack", {})["enabled"] = False
if extra == "observability":
    st = v["observability"]["stack"]
    st["enabled"] = True
    st.setdefault("alerting", {}).update({"emailTo": "ci@example.org", "smtpHost": "smtp.example.org"})
if extra == "no-render":
    v["deid"]["policyReviewed"] = False
yaml.safe_dump(v, open(dst, "w"), sort_keys=False)
PY
    rm -f "$R/sites/t/secrets.enc.yaml"
}

# --- the stub kubectl ---------------------------------------------------------
cat > "$WORK/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
ns=default; name=""; kind=""
while [ $# -gt 0 ]; do
    case "$1" in
        --namespace|-n) ns="$2"; shift 2 ;;
        secret) kind=secret; name="$2"; shift 2 ;;
        -o) shift 2 ;;
        *) shift ;;
    esac
done
if [ "$kind" != secret ]; then echo "stub kubectl: no cluster here (step 1 reached)" >&2; exit 1; fi
echo "$ns/$name" >> "$STUB_LOG"
case "${STUB_MODE:-list}" in
    down) echo "The connection to the server 127.0.0.1:6443 was refused - did you specify the right host or port?" >&2; exit 1 ;;
    forbidden) echo "Error from server (Forbidden): secrets \"$name\" is forbidden: User \"op\" cannot get resource \"secrets\"" >&2; exit 1 ;;
esac
if grep -qx -- "$ns/$name" "$STUB_PRESENT"; then echo "secret/$name"; exit 0; fi
echo "Error from server (NotFound): secrets \"$name\" not found" >&2
exit 1
EOF
chmod +x "$WORK/bin/kubectl"
export STUB_LOG="$WORK/kubectl.log" STUB_PRESENT="$WORK/present"

# run <case>: install.sh t, stdin not a terminal; sets RC and OUT
run() {
    : > "$STUB_LOG"
    OUT="$(cd "$R" && PATH="$WORK/bin:$PATH" KUBECONFIG="$WORK/none" bash ./install.sh t 2>&1 </dev/null)"
    RC=$?
    printf '%s\n' "$OUT" > "$WORK/out-$1.txt"
}
has() { printf '%s' "$OUT" | grep -q -- "$1"; }
step1() { has "=== 01: Using existing Kubernetes cluster ===" && has "step 1 reached"; }

echo "${_B}install.sh with no secrets.enc.yaml${_O}"

site fresh
printf 'xnat-ingest/xnat-credentials\nxnat-ingest/orthanc-deid-salt\n' > "$STUB_PRESENT"
run fresh
if [ "$RC" -ne 0 ] && has "no sites/t/secrets.enc.yaml" && has "installMode: existing (the cluster must already exist)"; then
    pass "fresh, no file: refused, and the message names installMode: existing"
else fail "fresh, no file: rc=$RC (see $WORK/out-fresh.txt)"; fi

site existing
run all-present
if has "the cluster has every Secret that the chart needs (xnat-ingest/orthanc-deid-salt xnat-ingest/xnat-credentials)" \
   && has "Step 2 is skipped" && step1 && [ "$(wc -l < "$STUB_LOG")" -eq 2 ]; then
    pass "existing, no file, both Secrets in the cluster: goes on to step 1, step 2 skipped"
else fail "existing, all present: rc=$RC, queries $(wc -l < "$STUB_LOG") ($(printf '%s' "$OUT" | grep -E 'ERROR|cluster has' | head -2))"; fi

printf 'xnat-ingest/orthanc-deid-salt\n' > "$STUB_PRESENT"
run one-absent
if [ "$RC" -ne 0 ] && has "the cluster does not have: xnat-ingest/xnat-credentials" && ! step1; then
    pass "existing, no file, xnat-credentials absent: refused before step 1, and named"
else fail "existing, one absent: rc=$RC ($(printf '%s' "$OUT" | grep ERROR | head -1))"; fi

STUB_MODE=down run down
if [ "$RC" -ne 0 ] && has "could not be asked for Secret" && has "An error does not mean the Secret is there"; then
    pass "existing, no file, API unreachable: refused (an error is not 'present')"
else fail "existing, unreachable: rc=$RC ($(printf '%s' "$OUT" | grep ERROR | head -1))"; fi

STUB_MODE=forbidden run forbidden
if [ "$RC" -ne 0 ] && has "could not be asked for Secret" && has "Forbidden"; then
    pass "existing, no file, API forbidden: refused the same way"
else fail "existing, forbidden: rc=$RC ($(printf '%s' "$OUT" | grep ERROR | head -1))"; fi

site existing no-render
printf 'xnat-ingest/xnat-credentials\nxnat-ingest/orthanc-deid-salt\n' > "$STUB_PRESENT"
run no-render
if [ "$RC" -ne 0 ] && has "does not render with this site file" && [ ! -s "$STUB_LOG" ]; then
    pass "existing, no file, the chart does not render: refused, no Secret asked"
else fail "existing, no render: rc=$RC ($(printf '%s' "$OUT" | grep ERROR | head -1))"; fi

site existing observability
run observability
if [ "$RC" -ne 0 ] && has "xnat-ingest/alertmanager-smtp" && has "xnat-ingest/grafana-admin-credentials"; then
    pass "observability on, its Secrets absent: refused, and both named"
else fail "observability: rc=$RC ($(printf '%s' "$OUT" | grep ERROR | head -1))"; fi
printf 'xnat-ingest/xnat-credentials\nxnat-ingest/orthanc-deid-salt\nxnat-ingest/alertmanager-smtp\nxnat-ingest/grafana-admin-credentials\n' > "$STUB_PRESENT"
run observability-present
if step1 && [ "$(wc -l < "$STUB_LOG")" -eq 4 ]; then
    pass "observability on, all four Secrets in the cluster: goes on to step 1"
else fail "observability, all present: rc=$RC, queries $(wc -l < "$STUB_LOG")"; fi

site existing
printf 'apiVersion: v1\nkind: Secret\nmetadata: {name: x}\n' > "$R/sites/t/secrets.enc.yaml"
run file-plain
if [ "$RC" -ne 0 ] && has "is NOT encrypted" && [ ! -s "$STUB_LOG" ]; then
    pass "a secrets file that is not encrypted: the old refusal, unchanged"
else fail "file present: rc=$RC ($(printf '%s' "$OUT" | grep ERROR | head -1))"; fi

echo
printf '%sinstall-secrets:%s %d passed, %d failed\n' "$_B" "$_O" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { printf '  failed: %s\n' "${FAILED[@]}"; exit 1; }
