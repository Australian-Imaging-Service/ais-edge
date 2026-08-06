#!/usr/bin/env bash
# =============================================================================
# 7. Runtime-template survival — the silent-breakage check
# =============================================================================
# Several config files carry `{{ ... }}` that belongs to something OTHER than
# Helm and must reach the cluster verbatim:
#
#   Vector          {{ cluster }}, {{ kubernetes.pod_name }} — event-time
#                   templates, resolved per log line by Vector.
#   Loki ruler      {{ $labels.cluster }} — resolved by the ruler when an alert
#                   fires.
#   PrometheusRule  {{ $labels.* }} in annotations — resolved by Prometheus.
#   Alertmanager    {{ .CommonLabels.* }} — Go templates, resolved at notify.
#   Grafana         line_format "{{.component}}" — resolved by Loki at query.
#
# Helm evaluates `{{ }}` in anything it templates. Evaluated against the chart
# context these names do not exist, so they render as an EMPTY STRING. Nothing
# errors. The manifest applies. Vector starts. And every log line loses its
# stream labels, so every ruler rule selecting on them stops matching and every
# alert built on them stops firing — permanently, with no symptom except
# silence, which is what a healthy alerting stack also looks like.
#
# The two defences in the charts are `.Files.Get` from a files/ directory
# (Helm never templates those bytes) and, where a subchart runs `tpl` over a
# values block, backtick escaping. Both are invisible in review and easy to
# undo. This check does not care which is used: it looks at the RENDERED
# output and asserts the literal text is present in the specific object that
# has to carry it.
#
# Per-object, not a whole-file grep. Measured: the mgmt render contains
# "{{ .CommonLabels.session }}" inside a COMMENT, so a file-wide grep for that
# string passes even if the Alertmanager config itself renders empty.
#
# It also asserts the value is not empty, because `cluster: ''` is exactly what
# the breakage produces.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "$HERE/lib.sh"

ci_heading "runtime templates survive rendering"

# case <TAB> kind <TAB> object name <TAB> literal that must be present
#
# Object names use the release names render.sh installs with: mgmt and edge.
#
# NO COMMENTS OR BLANK-FIELD LINES INSIDE THE HEREDOC — the reader below splits
# on tabs and does not skip '#', so a comment becomes a case named '#'.
#
# The mgmt-slack row: the Slack receivers are a SECOND .Files.Get fragment,
# spliced into the Alertmanager config only when
# observability.alerting.slackWebhookSecretRef is set, so mgmt-slack is the only
# case that can prove they survive rendering. The literal is
# `{{ .Labels.alertname }}` rather than `{{ range .Alerts }}` deliberately: the
# latter also appears in that file's own header comment, which travels into the
# Secret, so it would pass on a comment while the real message body rendered
# empty — exactly the failure this whole check exists to catch.
expectations() {
  cat <<'EOF'
mgmt-defaults	ConfigMap	mgmt-vector	{{ cluster }}
mgmt-defaults	ConfigMap	mgmt-vector	{{ kubernetes.pod_namespace }}
mgmt-defaults	ConfigMap	mgmt-vector	{{ kubernetes.pod_name }}
mgmt-defaults	ConfigMap	loki-ruler-rules	{{ $labels.cluster }}
mgmt-defaults	Secret	alertmanager-aisedge-config	{{ .CommonLabels.
mgmt-slack	Secret	alertmanager-aisedge-config	{{ .Labels.alertname }}
mgmt-defaults	PrometheusRule	mgmt-warning	{{ $labels.
mgmt-defaults	PrometheusRule	mgmt-info	{{ $labels.
mgmt-defaults	PrometheusRule	mgmt-critical	{{ $labels.
mgmt-defaults	ConfigMap	mgmt-dashboard-pipeline-overview	line_format
mgmt-defaults	ConfigMap	mgmt-dashboard-edge-drilldown	line_format
edge-observability-on	ConfigMap	edge-vector	{{ cluster }}
edge-observability-on	ConfigMap	edge-vector	{{ kubernetes.pod_name }}
edge-observability-on	ConfigMap	edge-vector	{{ level }}
EOF
}

while IFS=$'\t' read -r case_name kind objname literal; do
  [ -n "$case_name" ] || continue
  render="$CI_RENDER_DIR/$case_name.yaml"
  if [ ! -s "$render" ]; then
    ci_fail "no render at $render — run scripts/ci/render.sh first (make ci does)"
    continue
  fi

  rc=0
  out="$(python3 - "$render" "$kind" "$objname" "$literal" 2>&1 <<'PY'
import base64, json, sys, yaml

path, kind, name, literal = sys.argv[1:5]

target = None
for doc in yaml.safe_load_all(open(path)):
    if doc and doc.get("kind") == kind and (doc.get("metadata") or {}).get("name") == name:
        target = doc
        break

if target is None:
    raise SystemExit(f"no {kind}/{name} in the render — the object that must carry this template is gone")

# Only the payload is inspected. Comments and adjacent objects are excluded on
# purpose: a whole-file grep passes on a comment while the real value is empty.
if kind == "Secret":
    payload = dict(target.get("stringData") or {})
    for k, v in (target.get("data") or {}).items():
        payload[k] = base64.b64decode(v).decode("utf-8", "replace")
elif kind in ("ConfigMap",):
    payload = dict(target.get("data") or {})
else:
    payload = {"spec": json.dumps(target.get("spec") or {})}

if not payload:
    raise SystemExit(f"{kind}/{name} has no data at all")

hits = [k for k, v in payload.items() if isinstance(v, str) and literal in v]
if not hits:
    empties = [k for k, v in payload.items() if not v]
    detail = f" (empty keys: {empties})" if empties else ""
    raise SystemExit(
        f"{kind}/{name} does not contain {literal!r}{detail}. "
        "Helm resolved a runtime template and emitted it empty: load the file with "
        ".Files.Get from a files/ directory, or escape it as {{`{{ ... }}`}} if the "
        "subchart runs tpl over it."
    )
print(",".join(hits))
PY
)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    ci_pass "$case_name $kind/$objname carries '$literal' (in $out)"
  else
    ci_fail "$case_name $kind/$objname: $out"
  fi
done < <(expectations)

ci_summary "runtime-templates"
