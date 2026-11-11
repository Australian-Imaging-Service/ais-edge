#!/usr/bin/env bash
# =============================================================================
# Orthanc exposure: the REST API gets a node port only on purpose
# =============================================================================
# A Service type applies to every port in the Service. When one Service held
# both Orthanc ports, orthanc.expose.dicom: nodePort made it NodePort, and the
# API server gave the REST API (it can delete studies) a node port too, which
# it picked itself. No rendered value showed it: the http port had no nodePort
# field, so only a live Service had the number.
#
# This stage renders every exposure setting and checks the rendered objects:
#   - <release>-orthanc is ClusterIP, with the DICOM and HTTP ports, always;
#   - a NodePort Service holds the HTTP port only with orthanc.expose.http:
#     nodePort, and then it holds nothing else;
#   - a NodePort Service holds the DICOM port only with orthanc.expose.dicom:
#     nodePort or both, and then it holds nothing else;
#   - no container gives the HTTP port a hostPort;
#   - expose.http: nodePort with auth off, and an unknown expose.http word,
#     do not render.
# A control feeds the checker the old one-Service shape: it must fail.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "$HERE/lib.sh"

# shellcheck source=scripts/ci/values.sh
. "$HERE/values.sh" >/dev/null
HELM="$(ci_helm)"
ci_heading "Orthanc exposure (edge chart)"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
BASE=(-f "$CI_VALUES_DIR/edge-base.yaml")

# check <file> <dicom> <http>: prints problems, one per line; none = pass.
check() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, yaml
path, dicom, http = sys.argv[1:4]
docs = [d for d in yaml.safe_load_all(open(path)) if d]
svcs = [d for d in docs if d.get("kind") == "Service" and d["metadata"]["name"].startswith("edge-orthanc")]
bad = []
main = [s for s in svcs if s["metadata"]["name"] == "edge-orthanc"]
if len(main) != 1:
    bad.append(f"expected one Service edge-orthanc, found {len(main)}")
else:
    m = main[0]["spec"]
    if m.get("type", "ClusterIP") != "ClusterIP":
        bad.append(f"edge-orthanc is {m.get('type')}, not ClusterIP")
    names = sorted(p["name"] for p in m["ports"])
    if names != ["dicom", "http"]:
        bad.append(f"edge-orthanc ports are {names}, not dicom and http")
    if any("nodePort" in p for p in m["ports"]):
        bad.append("edge-orthanc sets a nodePort")
want = {"dicom": dicom in ("nodePort", "both"), "http": http == "nodePort"}
for port in ("dicom", "http"):
    holders = [s for s in svcs if s["spec"].get("type") == "NodePort"
               and any(p["name"] == port for p in s["spec"]["ports"])]
    if want[port] and len(holders) != 1:
        bad.append(f"expected one NodePort Service with the {port} port, found {len(holders)}")
    if not want[port] and holders:
        bad.append(f"NodePort Service {holders[0]['metadata']['name']} holds the {port} port, which nothing asked for")
    for s in holders:
        if len(s["spec"]["ports"]) != 1:
            bad.append(f"NodePort Service {s['metadata']['name']} holds {len(s['spec']['ports'])} ports, not only {port}")
for d in docs:
    spec = d.get("spec", {}).get("template", {}).get("spec", {})
    for c in spec.get("containers", []) + spec.get("initContainers", []):
        for p in c.get("ports", []) or []:
            if p.get("hostPort") and p.get("name") != "dicom":
                bad.append(f"{d['kind']} {d['metadata']['name']} gives port {p.get('name')} a hostPort")
print("\n".join(bad))
PY
}

for dicom in hostPort nodePort both; do
  for http in ClusterIP nodePort; do
    for auth in true false; do
      c="dicom=$dicom http=$http auth=$auth"
      out="$W/render.yaml"
      if ! "$HELM" template edge "$REPO_ROOT/charts/edge" -n xnat-ingest "${BASE[@]}" \
        --set "orthanc.expose.dicom=$dicom" --set "orthanc.expose.http=$http" \
        --set "orthanc.auth.enabled=$auth" >"$out" 2>"$W/err"; then
        if [ "$http" = nodePort ] && [ "$auth" = false ] &&
          grep -q 'puts the Orthanc REST API on a node port with no login' "$W/err"; then
          ci_pass "$c: refused (an API node port with no login)"
        else
          ci_fail "$c: did not render: $(head -c 300 "$W/err")"
        fi
        continue
      fi
      if [ "$http" = nodePort ] && [ "$auth" = false ]; then
        ci_fail "$c: rendered an API node port with no login"
        continue
      fi
      problems="$(check "$out" "$dicom" "$http")"
      if [ -z "$problems" ]; then
        ci_pass "$c: API exposure as asked, one port per NodePort Service"
      else
        ci_fail "$c: $(printf '%s' "$problems" | tr '\n' ';')"
      fi
    done
  done
done

if "$HELM" template edge "$REPO_ROOT/charts/edge" -n xnat-ingest "${BASE[@]}" \
  --set orthanc.expose.http=NodePort >/dev/null 2>"$W/err"; then
  ci_fail "expose.http=NodePort (wrong case) rendered; it must be refused"
elif grep -q 'orthanc.expose.http must be ClusterIP or nodePort' "$W/err"; then
  ci_pass "expose.http=NodePort (wrong case): refused with the allowed words"
else
  ci_fail "expose.http=NodePort: refused for another reason: $(head -c 300 "$W/err")"
fi

# Control: the old shape, one NodePort Service with both ports for
# dicom=nodePort. The checker must report the HTTP port.
cat >"$W/old.yaml" <<'EOF'
apiVersion: v1
kind: Service
metadata: {name: edge-orthanc}
spec:
  type: NodePort
  ports:
    - {name: dicom, port: 4242, nodePort: 30042}
    - {name: http, port: 8042}
EOF
if check "$W/old.yaml" nodePort ClusterIP | grep -q 'holds the http port, which nothing asked for'; then
  ci_pass "control: the old one-Service shape is caught"
else
  ci_fail "control: the checker passed the old one-Service shape"
fi

ci_summary "orthanc-exposure"
