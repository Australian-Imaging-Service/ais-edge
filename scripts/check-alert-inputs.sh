#!/usr/bin/env bash
# =============================================================================
# Alert input audit — does every metric an alert depends on actually exist?
# =============================================================================
# promtool unit tests prove a rule's LOGIC: given these series, does it fire.
# They cannot prove the series exist in OUR cluster, because the test supplies
# them. That gap is exactly where SeaweedFSDiskFull lived: the expression was
# valid, the logic was right, and the metric it selected
# (kubelet_volume_stats_* for a hostPath volume) does not exist and never will.
# The alert was green from the day it was written.
#
# This script closes that gap. It extracts every metric name referenced by the
# PrometheusRules and asks the LIVE Prometheus whether each one has any series.
# A metric with no series means an alert that cannot fire, which is worse than
# no alert at all because it reads as coverage on a dashboard.
#
#   scripts/check-alert-inputs.sh                 audit against the live Prometheus
#   scripts/check-alert-inputs.sh --strict        exit 1 if any input is missing
#
# Run it after any change to the rules, and after any change to what is
# scraped. Being unable to reach Prometheus is a hard failure, not a skip:
# a silent skip in CI is the same class of problem as a silent alert.
# =============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES_DIR="${RULES_DIR:-${REPO_DIR}/charts/mgmt/files/prometheus-rules}"
NS="${PROM_NAMESPACE:-observability}"
SVC="${PROM_SERVICE:-kube-prometheus-stack-prometheus}"
PORT="${PROM_LOCAL_PORT:-19099}"
STRICT=0
[ "${1:-}" = "--strict" ] && STRICT=1

KUBECTL="${KUBECTL:-sudo k0s kubectl}"

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 2; }

# --- extract metric names from the rule expressions --------------------------
# Deliberately crude and OVER-inclusive: it is better to ask Prometheus about a
# few PromQL keywords (which harmlessly report as absent and are filtered) than
# to miss a real metric because of a clever regex.
METRICS=$(python3 - "$RULES_DIR" <<'PYEOF'
import sys, os, re, yaml
rules_dir = sys.argv[1]
names = {}
for fn in sorted(os.listdir(rules_dir)):
    if not fn.endswith((".yaml", ".yml")):
        continue
    path = os.path.join(rules_dir, fn)
    try:
        doc = yaml.safe_load(open(path))
    except Exception:
        continue
    if not isinstance(doc, dict):
        continue
    for grp in doc.get("groups") or []:
        for rule in grp.get("rules") or []:
            alert = rule.get("alert")
            expr = rule.get("expr", "")
            if not alert:
                continue
            # Strip label-matcher blocks FIRST. Without this, a matcher key
            # such as {type="used"} is extracted as if it were a metric name,
            # and then reported as "NO SERIES" — a false positive that trains
            # people to ignore the output, which defeats the whole point.
            stripped = re.sub(r'\{[^{}]*\}', '', expr)
            # ...and the label lists of the grouping/matching modifiers.
            # `ignoring(type)` / `by (cluster)` / `on (instance)` name LABELS,
            # not metrics, and reporting them as missing series is the kind of
            # false positive that teaches people to skim past real ones.
            stripped = re.sub(r'\b(?:by|without|on|ignoring|group_left|group_right)\s*\([^()]*\)',
                              ' ', stripped)
            for m in re.findall(r'\b([a-zA-Z_][a-zA-Z0-9_:]*)\b', stripped):
                names.setdefault(m, set()).add(alert)
# PromQL keywords, functions and aggregation modifiers, not metrics.
KW = {
    "sum","rate","irate","increase","count","count_over_time","avg","avg_over_time",
    "min","max","by","without","on","ignoring","group_left","group_right","and","or",
    "unless","offset","bool","absent","absent_over_time","changes","delta","idelta",
    "deriv","predict_linear","histogram_quantile","quantile","topk","bottomk","time",
    "vector","scalar","clamp_max","clamp_min","round","abs","ceil","floor","exp","ln",
    "log2","log10","sqrt","stddev","stdvar","last_over_time","max_over_time",
    "min_over_time","sum_over_time","present_over_time","label_replace","label_join",
    "group","timestamp","json","regexp","line_format","unwrap","le","namespace",
}
for name, alerts in sorted(names.items()):
    if name in KW or name.isdigit():
        continue
    print("%s\t%s" % (name, ",".join(sorted(alerts))))
PYEOF
)

[ -n "$METRICS" ] || { echo "no metrics extracted from $RULES_DIR" >&2; exit 2; }

# --- port-forward to Prometheus ---------------------------------------------
$KUBECTL -n "$NS" port-forward "svc/${SVC}" "${PORT}:9090" >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 1 20); do
    curl -sf "http://127.0.0.1:${PORT}/-/ready" >/dev/null 2>&1 && break
    sleep 1
done
if ! curl -sf "http://127.0.0.1:${PORT}/-/ready" >/dev/null 2>&1; then
    echo "ERROR: could not reach Prometheus at ${NS}/${SVC}." >&2
    echo "       Not treating this as 'nothing to report' — an unreachable" >&2
    echo "       Prometheus tells you nothing about whether the alerts work." >&2
    exit 2
fi

echo "=== Alert input audit against ${NS}/${SVC} ==="
echo
MISSING=0
PRESENT=0
while IFS=$'\t' read -r metric alerts; do
    [ -n "$metric" ] || continue
    n=$(curl -sfG --data-urlencode "query=count(${metric})" \
            "http://127.0.0.1:${PORT}/api/v1/query" 2>/dev/null \
        | python3 -c 'import sys,json
try:
    r=json.load(sys.stdin)["data"]["result"]
    print(r[0]["value"][1] if r else "0")
except Exception:
    print("ERR")' 2>/dev/null)
    case "$n" in
        ERR) printf "  ?? %-52s query failed\n" "$metric" ;;
        0)   printf "  !! %-52s NO SERIES   -> %s\n" "$metric" "$alerts"; MISSING=$((MISSING+1)) ;;
        *)   printf "  ok %-52s %s series\n" "$metric" "$n"; PRESENT=$((PRESENT+1)) ;;
    esac
done <<< "$METRICS"

echo
echo "  ${PRESENT} metric(s) present, ${MISSING} with no series."
if [ "$MISSING" -gt 0 ]; then
    echo
    echo "  Every alert listed against a NO SERIES metric CANNOT FIRE."
    echo "  That is worse than having no alert, because a silent rule looks"
    echo "  exactly like a healthy system. Either fix the expression to use a"
    echo "  metric this cluster actually produces, scrape whatever exports it,"
    echo "  or delete the rule — but do not leave it in place."
    [ "$STRICT" = "1" ] && exit 1
fi
exit 0
