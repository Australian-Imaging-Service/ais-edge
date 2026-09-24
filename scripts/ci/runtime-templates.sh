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

# =============================================================================
# dataPolicy `location` must match where the data ACTUALLY is
# =============================================================================
# Each dataPolicy stage declares a location so the policy engine can walk paths
# instead of knowing about Orthanc or xnat-ingest — that is what lets the
# de-identifier or the ingest path be replaced without rewriting retention.
#
# The cost of that indirection is a NEW way to fail silently: if a template's
# path moves and the declared location does not follow, the engine walks a
# directory that no longer exists. Nothing errors. An empty directory reports
# zero files, zero bytes and nothing to reclaim — which is indistinguishable
# from a healthy, tidy site. This is the same shape as every other silent
# failure in this repo, so it gets a guard rather than a comment.
#
# Checked against edge-everything-on because it has fileDrop enabled; the
# fileDrop container is not rendered at all when that path is off, so a
# defaults-only case would pass the fileDrop line vacuously.
ci_heading "dataPolicy locations point at real paths"

loc_render="$CI_RENDER_DIR/edge-everything-on.yaml"
if [ ! -s "$loc_render" ]; then
  ci_fail "no render at $loc_render — run scripts/ci/render.sh first"
else
  # 2>&1 IS LOAD-BEARING: SystemExit writes its message to stderr, so without
  # it this reported "FAIL dataPolicy locations:" with nothing after the colon
  # — a guard that fires but cannot say what drifted.
  loc_out="$(python3 - "$loc_render" "$REPO_ROOT/charts/edge/values.yaml" 2>&1 <<'PY'
import re, sys, yaml

render = open(sys.argv[1]).read()
dp = (yaml.safe_load(open(sys.argv[2])) or {}).get("dataPolicy") or {}

targets = []
for group in ("originals", "derived"):
    for stage, cfg in (dp.get(group) or {}).items():
        if isinstance(cfg, dict) and cfg.get("location"):
            targets.append((f"{group}.{stage}", cfg["location"]))
sub = ((dp.get("originals") or {}).get("quarantine") or {}).get("subPath")
if sub:
    targets.append(("originals.quarantine.subPath", sub))

if not targets:
    raise SystemExit("no dataPolicy stage declares a location — the schema regressed")

missing = []
for name, value in targets:
    # Word-boundary-ish: /data/grouped must not be satisfied by /data/grouped-old
    if not re.search(re.escape(value) + r"(?![\w-])", render):
        missing.append(f"{name}={value}")

if missing:
    raise SystemExit(
        "declared location(s) appear nowhere in the rendered edge chart: "
        + ", ".join(missing)
        + ". Either a template's path moved and the dataPolicy default did not "
          "follow, or the reverse. The engine would walk a path that does not "
          "exist and report it as empty — which looks exactly like a tidy site."
    )
print(f"{len(targets)} location(s) verified against the rendered chart")
PY
  )" && ci_pass "$loc_out" || ci_fail "dataPolicy locations: $loc_out"
fi

# -----------------------------------------------------------------------------
# The policy engine reads the trees the uploader and assign actually write
# -----------------------------------------------------------------------------
# data-policy decides what to delete from three env values: the tree assign
# writes (ASSIGNED_DIR), the tree the uploader fingerprinted (UPLOAD_SOURCE_DIR)
# and where the markers live. Each is set in a different template from a
# different helper, and a wrong one fails silently in the dangerous direction:
# the engine compares a marker against the wrong tree. The shell tests cannot
# see this, because they set the env themselves.
#
# STRICT LOAD. PyYAML keeps the LAST of two duplicate keys without a word, and
# so does the API server. tier-1-solution shipped an env entry with two
# `value:` keys, and ASSIGNED_DIR reached the pod as "86400". Every edge render
# is loaded with duplicate keys refused, not only the data-policy object.
#
# Both layouts must be present, or one engine's wiring is checked vacuously:
# the orthanc layout (upload source == ASSIGNED_DIR) and the ingest layout
# (upload source is the deidentified tree, assign still writes ASSIGNED_DIR).
#
# EXTERNAL_RECLAIM_STAGE must name a row of stages.tsv, and at least one render
# must set it. The engine compares it against field 1 of that table, and it is
# checked before any reclaim condition, so it is what keeps this engine off a
# tree the staged-reclaimer CronJob owns. fingerprint-contract.sh checks the
# same thing from a site file of its own; on tier-1-solution that render stopped
# rendering and the check has been skipping, so this one runs on CI's renders.
ci_heading "data-policy reads the trees the uploader and assign write"

# 2>&1: SystemExit writes to stderr (see above).
wire_out="$(python3 - "$CI_RENDER_DIR" 2>&1 <<'PY'
import glob, os, re, sys, yaml

class StrictLoader(yaml.SafeLoader):
    pass

def no_duplicate_keys(loader, node, deep=False):
    seen = {}
    for k, _ in node.value:
        key = loader.construct_object(k, deep=deep)
        if key in seen:
            raise yaml.constructor.ConstructorError(
                None, None, "duplicate key %r (lines %d and %d)" % (key, seen[key] + 1, k.start_mark.line + 1), k.start_mark)
        seen[key] = k.start_mark.line
    return loader.construct_mapping(node, deep=deep)

StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_duplicate_keys)

def containers(doc):
    spec = doc.get("spec") or {}
    tpl = spec.get("template") or {}
    return (tpl.get("spec") or {}).get("containers") or []

def env(c):
    return {e["name"]: e.get("value") for e in c.get("env") or [] if "value" in e}

problems, checked, delegated, layouts = [], 0, 0, set()
for path in sorted(glob.glob(os.path.join(sys.argv[1], "edge-*.yaml"))):
    case = os.path.basename(path)[:-len(".yaml")]
    try:
        docs = [d for d in yaml.load_all(open(path), Loader=StrictLoader) if d]
    except yaml.YAMLError as e:
        problems.append("%s: %s" % (case, " ".join(str(e).split())))
        continue
    dp = up = None
    rows = {}
    for d in docs:
        for c in containers(d):
            if d.get("kind") == "DaemonSet" and c.get("name") == "data-policy":
                dp = env(c)
            if d.get("kind") == "Deployment" and c.get("name") == "uploader":
                up = env(c)
        if d.get("kind") == "ConfigMap" and "stages.tsv" in (d.get("data") or {}):
            rows = {r[0]: r for r in (l.split("\t") for l in d["data"]["stages.tsv"].splitlines() if l.strip())}
    if dp is None:
        continue
    checked += 1
    src, adir = dp.get("UPLOAD_SOURCE_DIR") or "", dp.get("ASSIGNED_DIR") or ""
    layouts.add("ingest" if src != adir else "orthanc")
    if not src.startswith("/"):
        problems.append("%s: UPLOAD_SOURCE_DIR=%r is not an absolute path" % (case, src))
    if "derived.assigned" in rows and adir != rows["derived.assigned"][2]:
        problems.append("%s: ASSIGNED_DIR=%r but the assigned stage is at %r" % (case, adir, rows["derived.assigned"][2]))
    if up is not None:
        if src != up.get("ASSIGNED_DIR"):
            problems.append("%s: UPLOAD_SOURCE_DIR=%r but the s3-uploader reads %r" % (case, src, up.get("ASSIGNED_DIR")))
        if dp.get("UPLOAD_STATE_DIR") != up.get("STATE_DIR"):
            problems.append("%s: UPLOAD_STATE_DIR=%r but the s3-uploader writes %r" % (case, dp.get("UPLOAD_STATE_DIR"), up.get("STATE_DIR")))
    for name, r in rows.items():
        word = r[5] if len(r) > 5 else ""
        if word == "onUploaded" and r[2] != src:
            problems.append("%s: %s is onUploaded at %r but the uploader reads %r" % (case, name, r[2], src))
        if word == "onAssigned" and name != "derived.grouped":
            problems.append("%s: %s uses onAssigned, which only derived.grouped may" % (case, name))
    ext = dp.get("EXTERNAL_RECLAIM_STAGE") or ""
    if ext:
        delegated += 1
        if ext not in rows:
            problems.append("%s: EXTERNAL_RECLAIM_STAGE=%r is not a row in stages.tsv, so the engine never recognises the CronJob's tree" % (case, ext))
    if not re.fullmatch(r"[0-9]+", dp.get("STUCK_AFTER_S") or ""):
        problems.append("%s: STUCK_AFTER_S=%r is not a number of seconds" % (case, dp.get("STUCK_AFTER_S")))

if checked == 0:
    problems.append("no edge render carries the data-policy DaemonSet: the check would pass on nothing")
for want in ("orthanc", "ingest"):
    if checked and want not in layouts:
        problems.append("no render exercises the %s layout, so its wiring goes unchecked" % want)
if checked and not delegated:
    problems.append("no render sets EXTERNAL_RECLAIM_STAGE, so the delegation wiring goes unchecked")
if problems:
    raise SystemExit("; ".join(problems))
print("%d edge render(s) load without duplicate keys and wire data-policy to the uploader's trees (layouts: %s; %d delegate a stage)"
      % (checked, ", ".join(sorted(layouts)), delegated))
PY
)" && ci_pass "$wire_out" || ci_fail "data-policy wiring: $wire_out"

# -----------------------------------------------------------------------------
# install.sh's generated edge hostnames must match the chart's
# -----------------------------------------------------------------------------
# The chart renders the Ingress and the certificate SANs for each hosted control
# plane; install.sh writes the /etc/hosts entries that let the edge RESOLVE
# those names. They derive the same hostname independently, from two different
# defaults, and nothing joined them up: the chart used konnectivityPrefix
# `konnectivity`, install.sh hardcoded `konnect-`. /etc/hosts then pointed at a
# name nothing served and the worker join failed with "no such host" from public
# DNS — which reads as a site DNS problem, not a repo one.
# 2>&1: SystemExit writes its message to STDERR, and a bare $( ) captures only
# stdout — so the failure arrived as "edge hostnames: " with nothing after it.
host_out="$(python3 - "$HERE/../.." 2>&1 <<'PY'
import re, sys, pathlib
# The repo root arrives as argv[1]: this block is fed to python on STDIN, so
# __file__ is "<stdin>" and any path derived from it is wrong.
root = pathlib.Path(sys.argv[1]).resolve()
chart = (root / "charts/mgmt/values.yaml").read_text()
inst  = (root / "install.sh").read_text()

def chart_prefix(key):
    m = re.search(r"^\s*%s:\s*(\S+)" % key, chart, re.M)
    return m.group(1).strip('"\'') if m else None

def install_prefix(var):
    # export VAR="${OVERRIDE:-<prefix>-${EDGE_NAME}.${INTERNAL_DOMAIN}}"
    m = re.search(r'export %s="\$\{[A-Z_]+:-([a-z0-9-]+?)-\$\{EDGE_NAME\}' % var, inst)
    return m.group(1) if m else None

pairs = [("apiPrefix", "K0S_API_HOSTNAME"), ("konnectivityPrefix", "KONNECTIVITY_HOSTNAME")]
bad = []
for ckey, ivar in pairs:
    c, i = chart_prefix(ckey), install_prefix(ivar)
    if c is None: bad.append("charts/mgmt/values.yaml has no %s" % ckey)
    elif i is None: bad.append("install.sh: could not read the %s fallback" % ivar)
    elif c != i: bad.append("%s=%r but install.sh generates %r-<edge>" % (ckey, c, i))

if bad:
    raise SystemExit("; ".join(bad) + ". The edge would resolve a hostname the chart never serves.")
print("%d edge hostname prefix(es) agree between chart and install.sh" % len(pairs))
PY
)" && ci_pass "$host_out" || ci_fail "edge hostnames: $host_out"

# -----------------------------------------------------------------------------
# One join implementation, two delivery paths
# -----------------------------------------------------------------------------
# scripts/06 (join: ssh) and scripts/06b (join: bundle) must both deliver
# scripts/files/edge-join.sh rather than carry their own copy of the join. A
# second copy drifts, and the symptom would be "joins over ssh but not from a
# bundle" — discovered at a hospital, by someone who cannot see the management
# cluster. Assert both reference the shared file and that neither has grown its
# own `k0s install worker`.
join_out="$(python3 - "$HERE/../.." 2>&1 <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
shared = root / "scripts/files/edge-join.sh"
if not shared.is_file():
    raise SystemExit("scripts/files/edge-join.sh is missing — both join paths depend on it")

problems = []
for rel in ("scripts/06-join-edge-worker.sh", "scripts/06b-make-bootstrap.sh"):
    text = (root / rel).read_text()
    if "files/edge-join.sh" not in text:
        problems.append("%s no longer delivers scripts/files/edge-join.sh" % rel)
    if "k0s install worker" in text:
        problems.append("%s contains its own 'k0s install worker' — the join has been copied" % rel)

if "k0s install worker" not in shared.read_text():
    problems.append("scripts/files/edge-join.sh no longer installs the worker")

if problems:
    raise SystemExit("; ".join(problems))
print("both join paths deliver the one shared edge-join.sh")
PY
)" && ci_pass "$join_out" || ci_fail "join paths: $join_out"

ci_summary "runtime-templates"
