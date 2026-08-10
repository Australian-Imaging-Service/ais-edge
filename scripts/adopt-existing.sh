#!/usr/bin/env bash
# =============================================================================
# adopt-existing.sh — give pre-existing objects the Helm ownership metadata a
#                     release needs, so the first `helm install` can proceed.
# =============================================================================
# THE PROBLEM THIS SOLVES
#
# Objects created imperatively (kubectl apply, or one of the scripts/0*.sh
# steps) carry no ownership metadata. Helm 3 refuses to take over such an
# object and aborts the whole install before applying anything:
#
#   Error: rendered manifests contain a resource that already exists.
#   Unable to continue with install: Namespace "edge-dev" in namespace "" exists
#   and cannot be imported into the current release: invalid ownership metadata;
#   label validation error: missing key "app.kubernetes.io/managed-by"; ...
#
# Helm considers an object part of a release when it carries all three of:
#
#   label      app.kubernetes.io/managed-by = Helm
#   annotation meta.helm.sh/release-name    = <release>
#   annotation meta.helm.sh/release-namespace = <the release's namespace>
#
# (release-namespace is the namespace the RELEASE lives in — not necessarily
# the namespace of the object.)
#
# This script sets exactly those three fields, on exactly the objects the
# chart renders, and on nothing else.
#
# -----------------------------------------------------------------------------
# WHY THERE IS NO --force AND NO `helm install --replace`
#
# Both are the usual suggestions for this error and neither is used here.
#
#   * `helm upgrade --force` changes how Helm APPLIES an object (replace, and
#     for some kinds delete-then-recreate). It does not change who owns it, so
#     it does not address this error — and where it does take effect, deleting
#     and recreating an object such as Cluster/<edge> is the exact outcome the
#     chart's `helm.sh/resource-policy: keep` annotation exists to prevent
#     (see charts/mgmt/templates/edge-clusters.yaml).
#   * `helm install --replace` reuses the NAME of a deleted release. It rewrites
#     release history, not object ownership.
#
# More importantly: an ownership collision is information. It says the cluster
# is not in the state you believe it is. This script therefore refuses to touch
# any object that is already owned by a DIFFERENT release, and exits non-zero
# so a human looks at it. There is deliberately no flag to override that.
#
# -----------------------------------------------------------------------------
# WHAT ADOPTION MEANS AFTERWARDS
#
# Once an object is adopted, the next `helm upgrade` applies the CHART's
# rendered spec over whatever is live. Adoption is therefore also the moment
# the live spec stops being authoritative. Read the dry-run plan with that in
# mind; anything you do not want managed by this release, exclude.
#
# -----------------------------------------------------------------------------
# USAGE
#
#   scripts/adopt-existing.sh --release <name> --namespace <ns> --chart <dir> \
#       [-f values.yaml]... [--set k=v]... [--exclude Kind/name]... \
#       [--record <path>] [--apply] [--yes]
#
#   Default is a DRY RUN: it prints the plan and changes nothing, in the
#   cluster or on disk. --apply is the only thing that writes.
#
#   -f / --values    passed through to `helm template` (repeatable)
#   --set            passed through to `helm template` (repeatable)
#   --exclude        leave an object alone, e.g.
#                    --exclude StorageClass/hostpath-pipeline (repeatable,
#                    matched as <Kind>/<name>). It does NOT suppress conflict
#                    reporting, and it does not make `helm install` accept the
#                    object — it only means this script does not patch it.
#   --record <path>  where to write the JSON record. Written on --apply always
#                    (default: adoption-records/adopt-<release>-<ns>-<ts>.json);
#                    in dry-run only if this flag is given explicitly.
#   --apply          make the changes. Prompts for confirmation.
#   --yes            skip the confirmation prompt (for non-interactive use).
#
# EXAMPLE
#
#   scripts/adopt-existing.sh --release mgmt --namespace ais-mgmt \
#       --chart charts/mgmt -f sites/dev/values.yaml            # dry run
#   scripts/adopt-existing.sh ... --apply                        # then this
#
# The object list comes from rendering the chart and then querying the cluster
# for each rendered object. Nothing is hardcoded, so a chart change or a new
# edge site is picked up with no edit here.
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RELEASE=""
NAMESPACE=""
CHART=""
HELM_ARGS=()
EXCLUDES=()
RECORD=""
RECORD_EXPLICIT=0
APPLY=0
ASSUME_YES=0

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[adopt] $*"; }
usage() { sed -n '/^# USAGE/,/^# =\{10,\}$/p' "$0" | sed '$d' | sed 's/^# \?//'; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --release)          RELEASE="${2:-}"; shift 2 ;;
        --namespace|-n)     NAMESPACE="${2:-}"; shift 2 ;;
        --chart)            CHART="${2:-}"; shift 2 ;;
        -f|--values)        HELM_ARGS+=(--values "${2:-}"); shift 2 ;;
        --set)              HELM_ARGS+=(--set "${2:-}"); shift 2 ;;
        --exclude)          EXCLUDES+=("${2:-}"); shift 2 ;;
        --record)           RECORD="${2:-}"; RECORD_EXPLICIT=1; shift 2 ;;
        --apply)            APPLY=1; shift ;;
        --yes)              ASSUME_YES=1; shift ;;
        -h|--help)          usage ;;
        *)                  die "unknown argument: $1  (try --help)" ;;
    esac
done

[ -n "$RELEASE" ]   || usage
[ -n "$NAMESPACE" ] || usage
[ -n "$CHART" ]     || usage
[ -d "$CHART" ]     || die "chart directory not found: $CHART"

command -v helm    >/dev/null 2>&1 || die "helm is required"
command -v kubectl >/dev/null 2>&1 || die "kubectl is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required (used to parse the rendered manifests)"
python3 -c 'import yaml' 2>/dev/null || die "python3 needs PyYAML (apt install python3-yaml)"

CONTEXT="$(kubectl config current-context 2>/dev/null)" || die "kubectl has no current context"
SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"

TMPDIR_ADOPT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ADOPT"' EXIT
RENDERED="${TMPDIR_ADOPT}/rendered.yaml"
OBJECTS="${TMPDIR_ADOPT}/objects.tsv"
RESULTS="${TMPDIR_ADOPT}/results.tsv"
: > "$RESULTS"

# -----------------------------------------------------------------------------
# 1. Render the chart. This is also a free correctness check: every render-time
#    guard in the chart runs here, so a chart that would not install cannot be
#    adopted for either.
# -----------------------------------------------------------------------------
info "context : ${CONTEXT}${SERVER:+  (${SERVER})}"
info "release : ${RELEASE}  namespace: ${NAMESPACE}"
info "chart   : ${CHART}"
echo
if ! helm template "$RELEASE" "$CHART" --namespace "$NAMESPACE" \
        ${HELM_ARGS[@]+"${HELM_ARGS[@]}"} \
        > "$RENDERED" 2>"${TMPDIR_ADOPT}/render.err"; then
    cat "${TMPDIR_ADOPT}/render.err" >&2
    die "the chart does not render with these values, so there is nothing to adopt it for. Fix the render first."
fi

# -----------------------------------------------------------------------------
# 2. Turn the rendered manifests into one line per object.
#    Emitted, 0x1f-separated (see meta_of below for why not a tab):
#    <kubectl resource spec> <Kind> <name> <lookup ns> <declared ns> <hook?>
#    The resource spec is fully qualified (<kind>.<version>.<group>) on purpose:
#    `Cluster` alone is ambiguous — k0smotron.io and cluster.x-k8s.io both
#    define one, and kubectl would resolve it by whichever API group sorts
#    first, which is not a thing to leave to chance on a delete-capable script.
# -----------------------------------------------------------------------------
python3 - "$RENDERED" "$NAMESPACE" > "$OBJECTS" <<'PY'
import sys, yaml

path, release_ns = sys.argv[1], sys.argv[2]
with open(path) as fh:
    docs = list(yaml.safe_load_all(fh))

seen = set()
for doc in docs:
    if not isinstance(doc, dict):
        continue
    kind = doc.get("kind")
    api = doc.get("apiVersion", "")
    meta = doc.get("metadata") or {}
    name = meta.get("name")
    if not kind or not name:
        continue
    if "/" in api:
        group, version = api.split("/", 1)
    else:
        group, version = "", api
    res = kind.lower() if not group else "%s.%s.%s" % (kind.lower(), version, group)
    # Declared namespace and lookup namespace are kept apart. A manifest that
    # declares none is either cluster-scoped or relying on the release
    # namespace, and the manifest alone cannot tell you which — so the lookup
    # uses the release namespace (harmless: kubectl ignores -n for a
    # cluster-scoped resource) while the display stays honest about what was
    # actually declared.
    declared = meta.get("namespace") or ""
    ns = declared or release_ns
    hook = "hook" if (meta.get("annotations") or {}).get("helm.sh/hook") else "-"
    key = (res, name, ns)
    if key in seen:
        continue
    seen.add(key)
    print("\x1f".join([res, kind, name, ns, declared, hook]))
PY

TOTAL=$(wc -l < "$OBJECTS" | tr -d ' ')
info "chart renders ${TOTAL} object(s); checking each against the cluster"
echo

# -----------------------------------------------------------------------------
# 3. Classify each rendered object against what is actually in the cluster.
# -----------------------------------------------------------------------------
# Prints managed-by, release-name, release-namespace and namespace for an object
# as it exists in the cluster, empty strings where absent. The last field is the
# LIVE namespace, empty for a cluster-scoped object — the rendered manifest
# cannot be trusted for that, since most subcharts omit metadata.namespace on
# namespaced objects and let the release namespace apply.
#
# THE SEPARATOR IS US (0x1f), NOT A TAB, and that is load-bearing. Tab is IFS
# whitespace, so `IFS=$'\t' read` collapses runs of tabs and drops leading ones:
# an object with no managed-by label but a namespace parses as managed-by=<the
# namespace>, and an unowned object reads as owned by another release. Measured
# here — Service/mgmt-cert-manager-metrics ("Helm", "", "", "cert-manager") was
# reported as a conflict with release "cert-manager", which would have stopped
# an install that was fine. A non-whitespace IFS preserves empty fields.
meta_of() {
    python3 -c '
import json, sys
try:
    obj = json.load(sys.stdin)
except ValueError:
    sys.exit(3)
m = obj.get("metadata") or {}
lab = m.get("labels") or {}
ann = m.get("annotations") or {}
print("\x1f".join([lab.get("app.kubernetes.io/managed-by", ""),
                   ann.get("meta.helm.sh/release-name", ""),
                   ann.get("meta.helm.sh/release-namespace", ""),
                   m.get("namespace", "")]))
'
}

is_excluded() {
    local kind="$1" name="$2" e
    for e in ${EXCLUDES+"${EXCLUDES[@]}"}; do
        [ "$e" = "${kind}/${name}" ] && return 0
    done
    return 1
}

N_ADOPT=0; N_OWNED=0; N_CREATE=0; N_CONFLICT=0; N_SKIP=0

printf '  %-9s %-52s %s\n' "STATUS" "OBJECT" "DETAIL"
printf '  %-9s %-52s %s\n' "------" "------" "------"

while IFS=$'\x1f' read -r res kind name ns declared hook; do
    [ -n "$res" ] || continue
    # Until the object is found in the cluster, only the DECLARED namespace is
    # known to be true, so an object that declares none is shown without one
    # rather than being labelled with a namespace it may not be in.
    if [ -n "$declared" ]; then label="${kind}/${name} (ns ${declared})"; else label="${kind}/${name}"; fi

    # Every object is looked up, including excluded and hook ones. Exclusion
    # decides what gets PATCHED; it must not decide what gets REPORTED, or
    # `--exclude` would become the force flag this script does not have.
    if ! json="$(kubectl get "$res" "$name" -n "$ns" -o json 2>/dev/null)"; then
        if [ "$hook" = "hook" ]; then
            N_SKIP=$((N_SKIP + 1))
            printf '  %-9s %-52s %s\n' "skip" "$label" "helm hook — Helm creates it itself"
        else
            N_CREATE=$((N_CREATE + 1))
            printf '  %-9s %-52s %s\n' "create" "$label" "not in the cluster — helm will create it"
        fi
        continue
    fi

    IFS=$'\x1f' read -r cur_mgr cur_rel cur_relns live_ns < <(printf '%s' "$json" | meta_of)
    # From here on `ns` is the object's REAL namespace, empty for a
    # cluster-scoped object. It was the release namespace up to this point
    # only because that is the safest thing to look a manifest up under.
    # Carrying the release namespace forward onto a Namespace or a
    # ClusterIssuer would put a namespace into the record, and into the record's
    # revert commands, for an object that is not in one — a record that reads
    # as fact and is not.
    ns="$live_ns"
    if [ -n "$ns" ]; then
        label="${kind}/${name} (ns ${ns})"
    else
        label="${kind}/${name} (cluster-scoped)"
    fi

    # A conflict is reported before anything else, whatever the object is.
    if { [ -n "$cur_rel" ] && [ "$cur_rel" != "$RELEASE" ]; } || \
       { [ -n "$cur_relns" ] && [ "$cur_relns" != "$NAMESPACE" ]; }; then
        N_CONFLICT=$((N_CONFLICT + 1))
        printf '  %-9s %-52s %s\n' "CONFLICT" "$label" \
            "owned by release ${cur_rel:-?} in ${cur_relns:-?}"
        printf 'conflict\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
            "$res" "$kind" "$name" "$ns" "$cur_mgr" "$cur_rel" "$cur_relns" >> "$RESULTS"
        continue
    fi

    if [ "$cur_rel" = "$RELEASE" ] && [ "$cur_relns" = "$NAMESPACE" ] && [ "$cur_mgr" = "Helm" ]; then
        N_OWNED=$((N_OWNED + 1))
        printf '  %-9s %-52s %s\n' "owned" "$label" "already owned by this release"
        continue
    fi

    if [ "$hook" = "hook" ]; then
        # Hook objects are created and deleted by Helm outside the release
        # manifest, so ownership metadata is not what governs them and
        # adopting one would not change whether the install succeeds. An
        # existing one is still worth seeing: depending on the hook's
        # delete-policy, Helm may fail on it as "already exists".
        N_SKIP=$((N_SKIP + 1))
        printf '  %-9s %-52s %s\n' "skip" "$label" "helm hook, already in the cluster — not adopted"
        continue
    fi

    if is_excluded "$kind" "$name"; then
        # Excluded, and it exists without ownership metadata. `helm install`
        # will still refuse to import it — excluding it here only means THIS
        # script leaves it alone.
        N_SKIP=$((N_SKIP + 1))
        printf '  %-9s %-52s %s\n' "skip" "$label" "excluded — helm will still refuse to import it"
        continue
    fi

    N_ADOPT=$((N_ADOPT + 1))
    detail="no ownership metadata"
    [ -n "$cur_mgr" ] && detail="managed-by=${cur_mgr}, no release annotations"
    [ -n "$cur_rel$cur_relns" ] && detail="partial ownership metadata"
    printf '  %-9s %-52s %s\n' "ADOPT" "$label" "$detail"
    printf 'adopt\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
        "$res" "$kind" "$name" "$ns" "$cur_mgr" "$cur_rel" "$cur_relns" >> "$RESULTS"
done < "$OBJECTS"

echo
info "adopt: ${N_ADOPT}   already owned: ${N_OWNED}   helm will create: ${N_CREATE}   skipped: ${N_SKIP}   conflicts: ${N_CONFLICT}"

# -----------------------------------------------------------------------------
# 4. Conflicts stop everything. See the header for why there is no override.
# -----------------------------------------------------------------------------
if [ "$N_CONFLICT" -gt 0 ]; then
    echo
    echo "REFUSING TO PROCEED: ${N_CONFLICT} object(s) belong to a different Helm release." >&2
    echo "That means the cluster is not in the state this release assumes. Nothing has" >&2
    echo "been changed. Decide deliberately which release should own each object —" >&2
    echo "there is no flag here that will paper over it." >&2
    exit 2
fi

if [ "$N_ADOPT" -eq 0 ]; then
    echo
    info "nothing to adopt. Install directly:"
    info "  helm upgrade --install ${RELEASE} ${CHART} --namespace ${NAMESPACE} --create-namespace ..."
    exit 0
fi

# -----------------------------------------------------------------------------
# 5. Dry run stops here, having written nothing anywhere.
# -----------------------------------------------------------------------------
TS="$(date -u +%Y%m%dT%H%M%SZ)"
[ -n "$RECORD" ] || RECORD="${REPO_DIR}/adoption-records/adopt-${RELEASE}-${NAMESPACE}-${TS}.json"

OUTCOMES="${TMPDIR_ADOPT}/outcomes.tsv"
: > "$OUTCOMES"

write_record() {
    local mode="$1"
    mkdir -p "$(dirname "$RECORD")"
    python3 - "$RESULTS" "$RECORD" "$mode" "$RELEASE" "$NAMESPACE" "$CHART" "$CONTEXT" "$SERVER" "$TS" "$OUTCOMES" <<'PY'
import json, os, sys

results, out, mode, release, ns, chart, context, server, ts, outcomes_path = sys.argv[1:11]

# Per-object outcome, so the record says what actually happened rather than
# what was planned. A patch that failed must not read as an adoption.
outcomes = {}
if os.path.exists(outcomes_path):
    with open(outcomes_path) as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line:
                continue
            res, name, objns, state = line.split("\x1f")
            outcomes[(res, name, objns)] = state

objects = []
with open(results) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        status, res, kind, name, objns, mgr, rel, relns = line.split("\x1f")
        if status != "adopt":
            continue
        # Enough to undo this by hand. `-` suffixed keys remove a key; where a
        # value was already present, restore it instead.
        # objns is empty for a cluster-scoped object, and `-n ''` is rejected by
        # kubectl, so the flag is omitted rather than emitted empty.
        scope = (" -n %s" % objns) if objns else ""
        revert = ["kubectl annotate %s %s%s meta.helm.sh/release-name- meta.helm.sh/release-namespace- --overwrite"
                  % (res, name, scope)]
        if mgr:
            revert.append("kubectl label %s %s%s app.kubernetes.io/managed-by=%s --overwrite" % (res, name, scope, mgr))
        else:
            revert.append("kubectl label %s %s%s app.kubernetes.io/managed-by- --overwrite" % (res, name, scope))
        objects.append({
            "resource": res, "kind": kind, "name": name, "namespace": objns,
            "outcome": outcomes.get((res, name, objns), "planned"),
            "before": {
                "app.kubernetes.io/managed-by": mgr,
                "meta.helm.sh/release-name": rel,
                "meta.helm.sh/release-namespace": relns,
            },
            "after": {
                "app.kubernetes.io/managed-by": "Helm",
                "meta.helm.sh/release-name": release,
                "meta.helm.sh/release-namespace": ns,
            },
            "revert": revert,
        })

record = {
    "mode": mode,                 # "planned" (dry run) or "applied"
    "timestamp_utc": ts,
    "kube_context": context,
    "kube_server": server,
    "release": release,
    "release_namespace": ns,
    "chart": chart,
    # Only object identities and the three ownership fields are recorded.
    # Nothing reads or stores object spec, data or credentials.
    "objects": objects,
}
with open(out, "w") as fh:
    json.dump(record, fh, indent=2, sort_keys=True)
    fh.write("\n")
print(len(objects))
PY
}

if [ "$APPLY" -ne 1 ]; then
    echo
    info "DRY RUN — nothing was changed."
    if [ "$RECORD_EXPLICIT" -eq 1 ]; then
        write_record planned >/dev/null
        info "plan written to ${RECORD}"
    fi
    info "to make these ${N_ADOPT} change(s):  $0 <same arguments> --apply"
    exit 0
fi

# -----------------------------------------------------------------------------
# 6. Apply.
# -----------------------------------------------------------------------------
if [ "$ASSUME_YES" -ne 1 ]; then
    echo
    echo "  About to label and annotate ${N_ADOPT} object(s) in:"
    echo "    context : ${CONTEXT}"
    echo "    server  : ${SERVER}"
    echo "  After this, \`helm upgrade\` will apply the chart's rendered spec over them."
    read -rp "  Type the release name (${RELEASE}) to proceed: " confirm
    [ "$confirm" = "$RELEASE" ] || die "aborted — nothing changed"
fi

PATCH=$(printf '{"metadata":{"labels":{"app.kubernetes.io/managed-by":"Helm"},"annotations":{"meta.helm.sh/release-name":"%s","meta.helm.sh/release-namespace":"%s"}}}' \
    "$RELEASE" "$NAMESPACE")

FAILED=0
while IFS=$'\x1f' read -r status res kind name ns _mgr _rel _relns; do
    [ "$status" = "adopt" ] || continue
    # `ns` is empty for a cluster-scoped object, and `-n ''` is not the same as
    # omitting -n: kubectl treats the empty string as an explicit namespace and
    # rejects it.
    nsargs=()
    where="cluster-scoped"
    if [ -n "$ns" ]; then nsargs=(-n "$ns"); where="ns ${ns}"; fi
    if kubectl patch "$res" "$name" ${nsargs[@]+"${nsargs[@]}"} --type=merge -p "$PATCH" >/dev/null; then
        info "adopted ${kind}/${name} (${where})"
        printf '%s\x1f%s\x1f%s\x1fadopted\n' "$res" "$name" "$ns" >> "$OUTCOMES"
    else
        echo "FAILED to adopt ${kind}/${name} (${where})" >&2
        printf '%s\x1f%s\x1f%s\x1ffailed\n' "$res" "$name" "$ns" >> "$OUTCOMES"
        FAILED=$((FAILED + 1))
    fi
done < "$RESULTS"

write_record applied >/dev/null
echo
info "record written to ${RECORD}"
info "it lists the previous value of every field changed, and a revert command per object."

if [ "$FAILED" -gt 0 ]; then
    die "${FAILED} object(s) could not be patched. Each object in the record carries its own outcome (adopted / failed). Re-run the dry run to see the current state."
fi

echo
info "now install:"
info "  helm upgrade --install ${RELEASE} ${CHART} --namespace ${NAMESPACE} ${HELM_ARGS[*]}"
