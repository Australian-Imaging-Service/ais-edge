#!/usr/bin/env bash
# =============================================================================
# Loki alert-rule tests — the gap promtool cannot cover
# =============================================================================
# `promtool test rules` unit-tests the PROMETHEUS rules. The Loki rules had no
# harness at all, and they are where this repo's worst alerting bugs have lived:
#
#   * XNATAuthFailure matched a tqdm progress bar reading "401.71it/s" and paged
#     during a perfectly healthy upload.
#   * XNATUploadSuccess used a range shorter than the emitter's loop period, so
#     it resolved and re-fired every minute — one mail per loop, for two days.
#   * ReclaimerRunUnavailable fired on a single transient miss of an hourly job
#     and produced 21 of ~30 notifications in one Alertmanager lifetime.
#
# Every one of those is a LOGIC bug in a valid expression, so nothing that only
# checks syntax would have caught any of them. This runs the REAL expressions,
# extracted from charts/mgmt/files/loki-ruler-rules.yaml by alert name, against
# a real Loki, over log lines whose timestamps we control.
#
# THE RULES ARE NEVER COPIED HERE. A test that asserts against its own copy of
# an expression passes forever after the real one is edited.
#
# The Loki version is derived from the PINNED SUBCHART in charts/mgmt/Chart.yaml
# so the tests and production cannot drift apart.
#
#   tests/loki-rules/run-tests.sh
#   CI_REQUIRE_LOKI_TESTS=1   a skipped run (no docker) becomes a failure
#   LOKI_KEEP=1               leave the container up for inspection
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# WHICH CHART SHIPS THE RULES depends on the tier: tier-2 keeps them in
# charts/mgmt, tier-1 in charts/edge (there is no management chart on a single
# node). Resolved rather than hardcoded so the same harness exercises both.
if [ -d "${REPO_ROOT}/charts/mgmt" ]; then
  OBS_CHART="charts/mgmt"
else
  OBS_CHART="charts/edge"
fi
# Tier-2 splits upload into its own namespace; tier-1 has exactly one.
TIER_NS="$(grep -m1 '^namespace:' "${REPO_ROOT}/${OBS_CHART}/values.yaml" | awk '{print $2}')"
TIER_NS="${TIER_NS:-xnat-upload}"
RULES="${REPO_ROOT}/${OBS_CHART}/files/loki-ruler-rules.yaml"
PORT="${LOKI_TEST_PORT:-33100}"
NAME="loki-rule-test"
WORK="$(mktemp -d)"

_G=$'\033[32m'; _R=$'\033[31m'; _Y=$'\033[33m'; _B=$'\033[1m'; _O=$'\033[0m'
PASS=0; FAIL=0; FAILED=()
pass() { PASS=$((PASS+1)); printf '  %sPASS%s  %-38s %s\n' "$_G" "$_O" "$1" "$2"; }
fail() { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  %sFAIL%s  %-38s %s\n' "$_R" "$_O" "$1" "$2"; }
SKIP=0
skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s  %-38s %s\n' "$_Y" "$_O" "$1" "$2"; }

cleanup() {
    [ "${LOKI_KEEP:-0}" = "1" ] || docker rm -f "$NAME" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

[ -f "$RULES" ] || { echo "no rules file at $RULES" >&2; exit 2; }

if ! command -v docker >/dev/null 2>&1 || ! docker ps >/dev/null 2>&1; then
    # A skip is reported as a skip, never folded into a pass — the same rule the
    # rest of this repo's checks follow.
    printf '%sSKIP%s  loki-rules: docker is not usable, so the Loki rules were NOT tested\n' "$_Y" "$_O"
    [ "${CI_REQUIRE_LOKI_TESTS:-0}" = "1" ] && { echo "CI_REQUIRE_LOKI_TESTS=1 — treating as failure" >&2; exit 1; }
    exit 0
fi

# Version comes from the pinned dependency's own comment (`version: "7.1.0"
# # app 3.6.8`), so bumping the subchart moves the tests with it.
LOKI_APP="$(python3 - "$REPO_ROOT/$OBS_CHART/Chart.yaml" <<'PY'
import re, sys
txt = open(sys.argv[1]).read()
m = re.search(r'-\s*name:\s*loki\s*\n\s*version:\s*"[^"]+"\s*#\s*app\s*([0-9][0-9.]*)', txt)
print(m.group(1) if m else "")
PY
)"
[ -n "$LOKI_APP" ] || { echo "could not read the pinned Loki app version from Chart.yaml" >&2; exit 2; }
IMAGE="grafana/loki:${LOKI_APP}"

printf '%s== Loki rule tests (%s) ==%s\n' "$_B" "$IMAGE" "$_O"

cat > "$WORK/loki.yaml" <<'EOF'
auth_enabled: false
server: {http_listen_port: 3100, log_level: error}
common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem: {chunks_directory: /loki/chunks, rules_directory: /loki/rules}
  replication_factor: 1
  ring: {kvstore: {store: inmemory}}
schema_config:
  configs:
    - from: 2020-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index: {prefix: index_, period: 24h}
limits_config:
  # Fixtures are deliberately backdated up to ~72h to exercise `offset`
  # windows, so the usual freshness limits must be off HERE. Production keeps
  # them on; this is a throwaway instance.
  reject_old_samples: false
  ingestion_rate_mb: 64
  ingestion_burst_size_mb: 128
  max_query_length: 0h
  max_query_lookback: 0s
ingester:
  # reject_old_samples:false IS NOT ENOUGH. The ingester independently drops an
  # entry older than max_chunk_age (default 2h) and the push still returns 204,
  # so 13 of 19 fixture lines vanished silently and the offset-window cases
  # "passed" against no data at all. That is the same vacuous-pass this harness
  # exists to catch, so the limit is raised here AND every fixture is verified
  # as ingested before any case is evaluated.
  max_chunk_age: 720h
EOF

docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" -p "${PORT}:3100" \
    -v "$WORK/loki.yaml:/etc/loki/local-config.yaml:ro" \
    "$IMAGE" -config.file=/etc/loki/local-config.yaml >/dev/null 2>&1 || {
    echo "could not start $IMAGE" >&2; exit 2; }

for _ in $(seq 1 60); do
    curl -sf "http://localhost:${PORT}/ready" >/dev/null 2>&1 && break
    sleep 1
done
curl -sf "http://localhost:${PORT}/ready" >/dev/null 2>&1 || {
    echo "Loki did not become ready" >&2; docker logs "$NAME" 2>&1 | tail -20; exit 2; }

NOW_NS=$(( $(date +%s) * 1000000000 ))

# -----------------------------------------------------------------------------
# Fixtures.  <minutes-ago> <TAB> <stream-labels-json> <TAB> <log line>
#
# `cluster` is a STREAM label because that is how Vector sets it in production.
# It is deliberately NOT also placed in the JSON body: Loki renames a parsed
# field that collides with an existing stream label to <name>_extracted, so a
# fixture carrying both would silently test a different label than the rule
# groups by.
# -----------------------------------------------------------------------------
fixtures() {
cat <<EOF
30	{"namespace":"xnat-upload","component":"s3-reclaimer","cluster":"rec-stuck"}	{"component":"s3-reclaimer","event":"reclaim_unavailable","session":"","reason":"xnat_probe_failed"}
90	{"namespace":"xnat-upload","component":"s3-reclaimer","cluster":"rec-stuck"}	{"component":"s3-reclaimer","event":"reclaim_unavailable","session":"","reason":"xnat_probe_failed"}
30	{"namespace":"xnat-upload","component":"s3-reclaimer","cluster":"rec-ok"}	{"component":"s3-reclaimer","event":"reclaim_unavailable","session":"","reason":"xnat_probe_failed"}
10	{"namespace":"xnat-upload","component":"s3-reclaimer","cluster":"rec-ok"}	{"component":"s3-reclaimer","event":"reclaim_finished","session":"","message":"examined=2 removed=0"}
2	{"namespace":"xnat-upload","cluster":"auth-once"}	{"level":"ERROR","message":"Invalid status for response from XNATSession (status 401, accepted status: [200, 201])"}
1	{"namespace":"xnat-upload","cluster":"auth-many"}	{"level":"ERROR","message":"Invalid status for response from XNATSession (status 401, accepted status: [200, 201])"}
3	{"namespace":"xnat-upload","cluster":"auth-many"}	{"level":"ERROR","message":"Invalid status for response from XNATSession (status 401, accepted status: [200, 201])"}
5	{"namespace":"xnat-upload","cluster":"auth-many"}	{"level":"ERROR","message":"Invalid status for response from XNATSession (status 401, accepted status: [200, 201])"}
7	{"namespace":"xnat-upload","cluster":"auth-many"}	{"level":"ERROR","message":"Invalid status for response from XNATSession (status 401, accepted status: [200, 201])"}
9	{"namespace":"xnat-upload","cluster":"auth-many"}	{"level":"ERROR","message":"Invalid status for response from XNATSession (status 401, accepted status: [200, 201])"}
1	{"namespace":"xnat-upload","cluster":"auth-tqdm"}	Processing staged sessions: 100%|##########| 1/1 [00:00<00:00, 401.71it/s]
2	{"namespace":"xnat-upload","cluster":"auth-tqdm"}	Processing staged sessions: 100%|##########| 1/1 [00:00<00:00, 403.02it/s]
3	{"namespace":"xnat-upload","cluster":"auth-tqdm"}	Processing staged sessions: 100%|##########| 1/1 [00:00<00:00, 401.10it/s]
4	{"namespace":"xnat-upload","cluster":"auth-tqdm"}	Processing staged sessions: 100%|##########| 1/1 [00:00<00:00, 403.55it/s]
5	{"namespace":"xnat-upload","cluster":"auth-tqdm"}	Processing staged sessions: 100%|##########| 1/1 [00:00<00:00, 401.99it/s]
3600	{"namespace":"xnat-upload","component":"s3-reclaimer","cluster":"stage-lost"}	{"component":"s3-reclaimer","event":"reclaim_skipped","session":"proj.SUBJ.SESS","message":"too young"}
3600	{"namespace":"xnat-upload","component":"s3-reclaimer","cluster":"stage-ok"}	{"component":"s3-reclaimer","event":"reclaim_skipped","session":"proj.SUBJ.SESS","message":"too young"}
60	{"namespace":"xnat-upload","component":"s3-reclaimer","cluster":"stage-ok"}	{"component":"s3-reclaimer","event":"reclaim_confirmed","session":"proj.SUBJ.SESS","message":"have=1"}
60	{"namespace":"xnat-upload","component":"s3-reclaimer","cluster":"stage-new"}	{"component":"s3-reclaimer","event":"reclaim_skipped","session":"proj.NEW.SESS","message":"too young"}
2	{"namespace":"xnat-ingest","component":"data-policy","cluster":"disk-low"}	{"component":"data-policy","event":"stage_report","stage":"originals.facilityBackup","location":"/facility-backup","free_pct":4,"min_free_pct":10,"entries":9,"oldest_age_s":50}
2	{"namespace":"xnat-ingest","component":"data-policy","cluster":"disk-ok"}	{"component":"data-policy","event":"stage_report","stage":"originals.facilityBackup","location":"/facility-backup","free_pct":56,"min_free_pct":10,"entries":9,"oldest_age_s":50}
2	{"namespace":"xnat-ingest","component":"data-policy","cluster":"quar-stuck"}	{"component":"data-policy","event":"stage_report","stage":"originals.quarantine","location":"/facility-backup/__unmapped_aet__","free_pct":56,"entries":3,"oldest_age_s":172800,"alert_after_s":86400}
2	{"namespace":"xnat-ingest","component":"data-policy","cluster":"quar-fresh"}	{"component":"data-policy","event":"stage_report","stage":"originals.quarantine","location":"/facility-backup/__unmapped_aet__","free_pct":56,"entries":1,"oldest_age_s":600,"alert_after_s":86400}
2	{"namespace":"xnat-ingest","component":"data-policy","cluster":"quar-empty"}	{"component":"data-policy","event":"stage_report","stage":"originals.quarantine","location":"/facility-backup/__unmapped_aet__","free_pct":56,"entries":0,"oldest_age_s":0,"alert_after_s":86400}
EOF
}

# case-name  alert  cluster-label  expect(fire|nofire)  description
cases() {
cat <<'EOF'
reclaimer_stuck	ReclaimerRunUnavailable	rec-stuck	fire	aborted twice, never recovered
reclaimer_recovered	ReclaimerRunUnavailable	rec-ok	nofire	aborted, then a run finished — must not page
auth_single_401	XNATAuthFailure	auth-once	nofire	one self-healing session expiry
auth_persistent_401	XNATAuthFailure	auth-many	fire	5 rejections in 15m — credential really broken
auth_progress_bar	XNATAuthFailure	auth-tqdm	nofire	tqdm "401.71it/s" must never match
staged_unconfirmed	SessionStagedNotConfirmedInXNAT	stage-lost	fire	seen 60h ago, never confirmed
staged_confirmed	SessionStagedNotConfirmedInXNAT	stage-ok	nofire	confirmed inside the 72h window
staged_too_recent	SessionStagedNotConfirmedInXNAT	stage-new	nofire	only 1h old — outside the offset window
disk_below_threshold	EdgeDiskLow	disk-low	fire	4% free vs minFreeDiskPercent 10
disk_above_threshold	EdgeDiskLow	disk-ok	nofire	56% free — comfortably above the limit
quarantine_stuck	QuarantinedDataUnresolved	quar-stuck	fire	oldest 48h vs alertAfter 24h
quarantine_fresh	QuarantinedDataUnresolved	quar-fresh	nofire	rejected 10m ago — operator has not had time
quarantine_empty	QuarantinedDataUnresolved	quar-empty	nofire	nothing quarantined at all
EOF
}

# --- push ---------------------------------------------------------------------
# The builder is written to a FILE rather than fed by heredoc: `python3 - <<'PY'`
# takes its script from stdin, so combining it with `< <(fixtures)` made the
# fixtures the script and produced a SyntaxError plus an empty push.
cat > "$WORK/mkpush.py" <<'PY'
import sys, json, collections
now = int(sys.argv[1])
streams = collections.defaultdict(list)
for raw in sys.stdin:
    raw = raw.rstrip("\n")
    if not raw.strip():
        continue
    mins, labels, line = raw.split("\t", 2)
    ts = str(now - int(mins) * 60 * 1000000000)
    streams[labels].append([ts, line])
out = {"streams": [{"stream": json.loads(k), "values": sorted(v, key=lambda x: int(x[0]))}
                   for k, v in streams.items()]}
json.dump(out, open(sys.argv[2], "w"))
total = sum(len(v) for v in streams.values())
open(sys.argv[3], "w").write(str(total))
print("  pushed %d lines across %d streams" % (total, len(streams)))
PY
fixtures | sed "s/\"namespace\":\"xnat-upload\"/\"namespace\":\"${TIER_NS}\"/g" | python3 "$WORK/mkpush.py" "$NOW_NS" "$WORK/push.json" "$WORK/expected_count" || {
    echo "could not build the push payload" >&2; exit 2; }

code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:${PORT}/loki/api/v1/push" \
        -H 'Content-Type: application/json' --data-binary @"$WORK/push.json")
[ "$code" = "204" ] || { echo "push failed (HTTP $code)" >&2; exit 2; }
sleep 3

# -----------------------------------------------------------------------------
# EVERY FIXTURE MUST BE QUERYABLE BEFORE ANY CASE RUNS.
#
# A 204 from the push API does NOT mean the lines were stored: the ingester
# drops entries it considers too old and still answers 204. That silently
# removed 13 of 19 fixtures once, and the offset-window cases then "passed"
# against no data at all — a green suite asserting nothing. A vacuous pass is
# precisely the class of bug these tests exist to find, so the harness verifies
# its own inputs first and refuses to report on cases it cannot really test.
# -----------------------------------------------------------------------------
expected="$(cat "$WORK/expected_count")"
lookback=$(( NOW_NS - 200 * 3600 * 1000000000 ))
# The selector must cover EVERY namespace the fixtures use. It was
# xnat-upload only, and the moment edge-side data-policy fixtures were added in
# xnat-ingest the count came up short — correctly, since a guard that only
# looks where it already knows to look is the thing it is guarding against.
stored="$(curl -sG "http://localhost:${PORT}/loki/api/v1/query_range" \
            --data-urlencode 'query={namespace=~"xnat-upload|xnat-ingest"}' \
            --data-urlencode "start=${lookback}" --data-urlencode "end=${NOW_NS}" \
            --data-urlencode 'limit=5000' \
          | python3 -c "
import sys, json
try: d = json.load(sys.stdin)
except Exception: print(-1); raise SystemExit
print(sum(len(s.get('values', [])) for s in d.get('data', {}).get('result', [])))")"
if [ "${stored:--1}" != "$expected" ]; then
    printf '  %sFAIL%s  fixture_ingestion: pushed %s lines, only %s are queryable\n' \
        "$_R" "$_O" "$expected" "${stored:--1}"
    echo "        The push returned 204 but Loki did not keep everything, so every"
    echo "        result below would be measured against missing data. Check"
    echo "        ingester.max_chunk_age and limits_config in this harness."
    exit 1
fi
printf '  %sPASS%s  %-38s all %s fixture lines queryable\n' "$_G" "$_O" "fixture_ingestion" "$expected"

# --- evaluate -----------------------------------------------------------------
while IFS=$'\t' read -r name alert cluster expect desc; do
    [ -n "${name:-}" ] || continue
    # An alert that does not exist ON THIS TIER is not a failure: tier-1 has no
    # S3 reclaimer and no staging bucket, so ReclaimerRunUnavailable and
    # SessionStagedNotConfirmedInXNAT are absent by design. Skipped with a
    # reason rather than deleted, so the same table serves both tiers.
    if ! grep -q "alert: ${alert}\b" "$RULES"; then
        skip "$name" "$alert is not in this tier's ruleset"
        continue
    fi
    expr="$(python3 - "$RULES" "$alert" "$REPO_ROOT/$OBS_CHART/values.yaml" <<'PY'

import sys, re, yaml

d = yaml.safe_load(open(sys.argv[1]))
expr = None
for g in d.get("groups", []):
    for r in g.get("rules", []):
        if r.get("alert") == sys.argv[2]:
            expr = r["expr"].strip()
if expr is None:
    raise SystemExit("alert %s not found in the rules file" % sys.argv[2])

# The rules file is stored with __DP_*__ sentinels because LogQL cannot compare
# two extracted fields, so the operator's threshold is substituted in at render
# time by charts/mgmt/templates/observability.yaml. The tests must perform the
# SAME substitution, from the SAME values, or they would either fail to parse or
# silently test a different number than production runs.
dp = (yaml.safe_load(open(sys.argv[3])) or {}).get("dataPolicy", {})
orig = dp.get("originals", {})

def seconds(v):
    v = str(v).strip()
    if v in ("", "forever", "never"):
        return "-1"
    mult = {"s": 1, "m": 60, "h": 3600, "d": 86400, "w": 604800, "y": 31536000}
    if v[-1] in mult and v[:-1].isdigit():
        return str(int(v[:-1]) * mult[v[-1]])
    return v

expr = expr.replace("__DP_MIN_FREE_DISK_PCT__",
                    str(orig.get("facilityBackup", {}).get("minFreeDiskPercent", 10)))
expr = expr.replace("__DP_QUARANTINE_ALERT_AFTER_S__",
                    seconds(orig.get("quarantine", {}).get("alertAfter", "24h")))

left = re.findall(r"__DP_[A-Z_]+__", expr)
if left:
    raise SystemExit("unsubstituted sentinel(s) in %s: %s — the harness and the "
                     "chart disagree about what to replace" % (sys.argv[2], left))
print(expr)
PY
    )" || { fail "$name" "could not extract expression for $alert"; continue; }

    got="$(curl -sG "http://localhost:${PORT}/loki/api/v1/query" \
             --data-urlencode "query=${expr}" --data-urlencode "time=${NOW_NS}" \
           | python3 -c "
import sys, json
try: d = json.load(sys.stdin)
except Exception: print('ERR'); raise SystemExit
if d.get('status') != 'success': print('ERR'); raise SystemExit
want = '$cluster'
print('fire' if any(s['metric'].get('cluster') == want for s in d['data']['result']) else 'nofire')")"

    if [ "$got" = "ERR" ]; then
        fail "$name" "query error for $alert"
    elif [ "$got" = "$expect" ]; then
        pass "$name" "$expect — $desc"
    else
        fail "$name" "expected $expect, got $got ($alert / cluster=$cluster) — $desc"
    fi
done < <(cases)

printf '\n%sloki-rules: %d passed, %d failed, %d skipped (not in %s)%s\n' "$_B" "$PASS" "$FAIL" "$SKIP" "$OBS_CHART" "$_O"
if [ "$FAIL" -gt 0 ]; then printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
exit 0
