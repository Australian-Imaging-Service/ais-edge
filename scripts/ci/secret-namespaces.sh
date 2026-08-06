#!/usr/bin/env bash
# =============================================================================
# Secret contract check
# =============================================================================
#   scripts/ci/secret-namespaces.sh
#
# Renders both charts and proves that every Secret they MOUNT is either
#   (a) created by the chart itself,
#   (b) created at runtime by something we know about (cert-manager issuing a
#       Certificate, a subchart's admission-webhook hook), or
#   (c) present in sites/example-mgmt/ or sites/example-edge/secrets.example.yaml — the files every new
#       site copies — IN THE SAME NAMESPACE AND WITH THE SAME KEYS.
#
# WHY THIS EXISTS
#   A Secret is only readable from its own namespace. The shipped template used
#   to place the management secrets in namespaces named after their component
#   (seaweedfs/, observability/) while the workloads that mount them all run in
#   the release namespace. Nothing in the chart, in `helm template`, in
#   `helm install`, or in any of the eight existing CI stages notices: helm
#   reports success, and the pods sit in CreateContainerConfigError until
#   somebody reads a pod event. It was found by hand during a rebuild.
#
#   A wrong namespace and a missing key fail identically and silently, so both
#   are checked here.
#
# This is a CONTRACT test, not a lint. It compares what the charts consume
# against what the repo tells an operator to create.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
[ -f "$HERE/lib.sh" ] && . "$HERE/lib.sh"

HELM="${HELM:-helm}"
# TWO templates, because a deployment has two kinds of site and each applies its
# secrets to a DIFFERENT cluster. `site-secrets.sh apply` sends a whole file to
# whatever KUBECONFIG points at, so the management set and the edge set cannot
# share a file without one of them landing on the wrong cluster.
EXAMPLE_MGMT="$REPO/sites/example-mgmt/secrets.example.yaml"
EXAMPLE_EDGE="$REPO/sites/example-edge/secrets.example.yaml"
VALUES_MGMT="$REPO/sites/example-mgmt/values.yaml"
VALUES_EDGE="$REPO/sites/example-edge/values.yaml"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }

# --- render ------------------------------------------------------------------
# The management chart is rendered with the release name/namespace the example
# template documents, because the namespace IS what is under test.
#   NOTHING IS DISABLED HERE. An earlier version passed
#   `--set k0smotron.enabled=false` "because the Cluster CRs are not this
#   stage's concern", and that silently skipped templates/edge-clusters.yaml —
#   including its guards. sites/example-mgmt/values.yaml then shipped
#   hostnames.k0sApi / hostnames.konnectivity, which that file hard-rejects, and
#   this stage went green while a real `helm install` against the example values
#   failed outright. A check that turns off part of the chart is not checking
#   the chart.
#   orthanc.deid.policyReviewed    the example deliberately ships false — it
#                                  must not assert that a human reviewed a
#                                  de-identification profile they have never
#                                  seen. That gate is covered by ci-negative;
#                                  overriding it here keeps THIS stage about
#                                  the secret contract and nothing else.
render() { # <name> <chart> <namespace> <values-file>... then [extra helm args]
    local name="$1" chart="$2" ns="$3"; shift 3
    local -a vf=()
    while [ "$#" -gt 0 ] && [ -f "$1" ]; do vf+=(-f "$1"); shift; done
    "$HELM" template "$name" "$REPO/$chart" -n "$ns" "${vf[@]}" \
        "$@" 2>"$WORK/$name.err"
}

rendered_ok=1
render mgmt charts/mgmt ais-mgmt "$VALUES_MGMT" > "$WORK/mgmt.yaml"
if [ ! -s "$WORK/mgmt.yaml" ]; then
    bad "management chart failed to render with sites/example-mgmt/values.yaml"
    sed 's/^/        /' "$WORK/mgmt.err" | head -20
    rendered_ok=0
fi

# BOTH files, in this order, because that is exactly what install.sh gives the
# edge chart. Rendering the edge from its own file alone would pass here and
# fail in reality: the S3 endpoint, staging bucket, Loki endpoint and
# hostAliases are all DERIVED from the management file's domain and hostnames,
# so on its own the edge chart has nothing to derive them from.
render edge charts/edge xnat-ingest "$VALUES_MGMT" "$VALUES_EDGE" \
    --set orthanc.deid.policyReviewed=true > "$WORK/edge.yaml"
if [ ! -s "$WORK/edge.yaml" ]; then
    bad "edge chart failed to render with sites/example-mgmt + sites/example-edge"
    sed 's/^/        /' "$WORK/edge.err" | head -20
    rendered_ok=0
fi

# A render failure must not be able to report success. The comparison below
# would find zero required Secrets in an empty document and cheerfully declare
# the contract satisfied — which is the exact shape of the bug this stage was
# written to catch, so it is not allowed to have it.
if [ "$rendered_ok" -ne 1 ]; then
    echo
    echo "  secret-contract: ${PASS} passed, ${FAIL} failed (comparison skipped — nothing rendered)"
    exit 1
fi

# --- compare -----------------------------------------------------------------
python3 - "$EXAMPLE_MGMT" "$EXAMPLE_EDGE" "$VALUES_MGMT" "$WORK/mgmt.yaml" "$WORK/edge.yaml" <<'PY' > "$WORK/report"
import sys, yaml

mgmt_example, edge_example, values_path, *rendered = sys.argv[1:]

def load(p):
    try:
        return [d for d in yaml.safe_load_all(open(p)) if d]
    except Exception:
        return []

# What the repo tells an operator to create: (namespace, name) -> {keys}
# The union of both templates, because between them they cover both clusters.
supplied = {}
misplaced = []

# Which namespaces each template is allowed to create Secrets in. This is the
# error the split introduces and nothing else would catch: an edge Secret listed
# in the management template is applied to the management cluster, where no pod
# reads it, while the edge pod that needs it sits in
# CreateContainerConfigError. Both files stay valid YAML and both charts still
# render, so only an explicit check finds it.
ALLOWED = {
    mgmt_example: ({'ais-mgmt', 'xnat-upload'}, 'management'),
    edge_example: ({'xnat-ingest'}, 'edge'),
}

for path, (allowed_ns, role) in ALLOWED.items():
    for d in load(path):
        if d.get('kind') != 'Secret':
            continue
        md = d['metadata']
        ns = md.get('namespace')
        keys = set((d.get('stringData') or {}).keys()) | set((d.get('data') or {}).keys())
        supplied.setdefault((ns, md['name']), set()).update(keys)
        if ns not in allowed_ns:
            misplaced.append((role, ns, md['name'], sorted(allowed_ns)))

required = {}     # (ns, name) -> {keys}   (None key = mounted whole)
created   = set() # (ns, name) the chart or a known controller produces

for path in rendered:
    docs = load(path)
    for d in docs:
        md = d.get('metadata', {})
        ns = md.get('namespace')
        kind = d.get('kind')

        if kind == 'Secret':
            created.add((ns, md.get('name')))
        # cert-manager materialises this Secret from the Certificate.
        if kind == 'Certificate':
            created.add((ns, (d.get('spec') or {}).get('secretName')))

        def walk(o):
            if isinstance(o, dict):
                skr = o.get('secretKeyRef')
                if isinstance(skr, dict) and skr.get('name'):
                    required.setdefault((ns, skr['name']), set()).add(skr.get('key'))
                sn = o.get('secretName')
                if isinstance(sn, str):
                    required.setdefault((ns, sn), set()).add(None)
                for v in o.values():
                    walk(v)
            elif isinstance(o, list):
                for v in o:
                    walk(v)
        walk(d)

# Secrets generated by a subchart's own hooks. Named explicitly rather than
# pattern-matched, so a genuinely missing secret cannot hide behind a wildcard.
RUNTIME = {
    'mgmt-ingress-nginx-admission',            # ingress-nginx admission webhook cert
    'mgmt-kube-prometheus-stack-admission',    # prometheus-operator admission webhook cert
    'ais-edge-ca-secret',                      # issued by the CA Certificate
}

# cert-sync copies the CA bundle and the per-edge Loki credential INTO each
# edge cluster, so those are not the operator's to create. Read the set from
# the site's declared certSync destinations rather than hardcoding names: if
# somebody deletes a certSync entry, the Secret it used to deliver must go back
# to being reported as missing instead of silently staying excused.
try:
    vals = yaml.safe_load(open(values_path)) or {}
except Exception:
    vals = {}
edge_names = [e.get('name') for e in (vals.get('edges') or []) if e.get('name')]
for entry in ((vals.get('certSync') or {}).get('secrets') or []):
    dst = entry.get('destination') or {}
    if dst.get('namespace') and dst.get('name'):
        created.add((dst['namespace'], dst['name']))
    # The SOURCE is the operator's to create, and nothing else checks it: a
    # cert-sync source that does not exist fails at RUNTIME, hours later, as a
    # sync_failed log line and a CertSyncStale alert a day after that. Require
    # it here, per edge, with <edge> substituted the way cert-sync does.
    src = entry.get('source') or {}
    if src.get('name'):
        for en in (edge_names or ['<edge>']):
            nm = src['name'].replace('<edge>', en)
            ns = src.get('namespace') or 'ais-mgmt'
            keys = {k.replace('<edge>', en) for k in (src.get('keys') or {})}
            required.setdefault((ns, nm), set()).update(keys)

problems = []
for (ns, name), keys in sorted(required.items(), key=lambda x: (x[0][0] or '', x[0][1])):
    if name in RUNTIME or (ns, name) in created:
        continue
    if (ns, name) in supplied:
        missing = {k for k in keys if k} - supplied[(ns, name)]
        if missing:
            problems.append(('KEYS', ns, name, f"template lacks key(s) {sorted(missing)}"))
        continue
    # Right name, wrong namespace is the failure this check was written for.
    elsewhere = [n for (n, nm) in supplied if nm == name]
    if elsewhere:
        problems.append(('NAMESPACE', ns, name,
                         f"mounted from {ns!r} but the template creates it in {elsewhere!r}"))
    else:
        problems.append(('ABSENT', ns, name,
                         "not in sites/example-mgmt/ or sites/example-edge/secrets.example.yaml"))

for role, ns, name, allowed in misplaced:
    problems.append(('MISPLACED', ns, name,
                     f"declared in the {role} template, which may only create Secrets in {allowed}"))

for kind, ns, name, msg in problems:
    print(f"{kind}\t{ns}/{name}\t{msg}")
print(f"__SUMMARY__\t{len(required)}\t{len(problems)}")
PY

while IFS=$'\t' read -r kind target msg; do
    case "$kind" in
        __SUMMARY__) checked="$target"; nprob="$msg" ;;
        NAMESPACE)   bad "$target — $msg" ;;
        KEYS)        bad "$target — $msg" ;;
        ABSENT)      bad "$target — $msg" ;;
        MISPLACED)   bad "$target — $msg" ;;
        # A problem kind this loop does not know about must not vanish. Adding
        # MISPLACED above without this arm produced "0 passed, 0 failed" and
        # exit 0 — the check had found the fault and reported nothing, which is
        # the precise failure this whole stage exists to catch.
        *)           bad "unhandled problem kind ${kind@Q} for ${target} — $msg" ;;
    esac
done < "$WORK/report"

[ "${nprob:-0}" = "0" ] && ok "all ${checked:-0} mounted Secrets are satisfied in the right namespace"

# The python side and this loop must agree. If they do not, one of them has a
# bug and the honest outcome is a failure, not a quiet pass.
if [ "${nprob:-0}" != "0" ] && [ "$FAIL" -eq 0 ]; then
    bad "python reported ${nprob} problem(s) but none were printed — the report parser is broken"
fi

echo
echo "  secret-contract: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
