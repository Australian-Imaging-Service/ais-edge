#!/usr/bin/env bash
# =============================================================================
# 6. Greenfield install into an EMPTY kind cluster
# =============================================================================
# Both charts must install into a cluster that has never seen them, with NO
# adoption step. Otherwise `scripts/adopt-existing.sh` quietly becomes a
# prerequisite and a brand-new site cannot be built from the chart alone —
# which is only discovered by the person standing up the first new site.
#
# WHAT THIS RUNS
#   1. kind cluster, pinned node image, nothing in it.
#   2. Prerequisites only, pinned: the cert-manager and k0smotron CRDs, and the
#      cert-manager namespace. Both operators are installed out of band on
#      every cluster we have — certManager.enabled defaults to false and
#      scripts/02 installs k0smotron — so their absence from the chart is the
#      design, not a gap. Neither OPERATOR is run here: the chart needs the API
#      server to accept its ClusterIssuer / Certificate / Cluster objects, not
#      anything to reconcile them.
#   3. `helm install` for real, so every object is CREATED. This is the half
#      that proves no adoption is required: on a cluster with pre-existing
#      unlabelled objects, Helm aborts here, and on an empty one it must not.
#   4. `helm upgrade --dry-run=server` — every object re-validated by a real
#      API server now that the subchart CRDs exist: schema, defaulting,
#      admission. Also the upgrade path.
#   5. `helm uninstall`, then assert the PVCs and PVs are STILL THERE. This
#      measures the retention that pvc-retention.sh only reads off the
#      manifest.
#
# WHAT IT DOES NOT COVER, stated rather than implied:
#   * Hooks are skipped (--no-hooks). The seaweedfs bucket-creation hook talks
#     to a SeaweedFS that is not running here and would fail for a reason that
#     has nothing to do with greenfield installability. Hook coverage needs a
#     real deployment and is not this job.
#   * Nothing is waited on. Pods do not become Ready: there are no 1500Gi
#     hostPath volumes and no DICOM. This asserts the manifests apply, not that
#     the system works.
#
# If docker or kind is unavailable the job SKIPS and says so. It does not pass.
# Set CI_REQUIRE_GREENFIELD=1 (the GitHub workflow does) to make the skip a
# hard failure, so an unavailable runner cannot read as coverage.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/values.sh
. "$HERE/values.sh"

CLUSTER_NAME="${CI_KIND_CLUSTER:-ais-edge-greenfield}"
KEEP_CLUSTER="${CI_KIND_KEEP:-0}"

ci_heading "greenfield install (kind)"

unavailable() {
  local rc=0
  if [ "${CI_REQUIRE_GREENFIELD:-0}" = "1" ]; then
    ci_fail "greenfield: $1 (CI_REQUIRE_GREENFIELD=1)"
    rc=1
  else
    ci_skip "greenfield NOT RUN: $1 — the charts are not proven installable by this run"
  fi
  ci_summary "greenfield" || rc=1
  exit "$rc"
}

command -v docker >/dev/null 2>&1 || unavailable "docker is not installed"
docker info >/dev/null 2>&1        || unavailable "the docker daemon is not reachable"
KUBECTL="$(ci_kubectl 2>/dev/null || true)"
[ -n "$KUBECTL" ] || unavailable "kubectl is not installed (scripts/ci/tools.sh kind)"
KIND="$(ci_kind 2>/dev/null || true)"
[ -n "$KIND" ] || unavailable "kind $CI_PIN_KIND_VERSION is not installed (scripts/ci/tools.sh kind)"
HELM="$(ci_helm)"

# Which kubectl, said out loud. ci_kubectl accepts a non-pinned one so the job
# can run on a developer's machine; if that is what happened, the run should
# not silently look identical to the pinned CI one.
kubectl_ver="$("$KUBECTL" version --client 2>/dev/null | head -1)"
case "$kubectl_ver" in
  *"$CI_PIN_KUBECTL_VERSION"*) ci_pass "kubectl $CI_PIN_KUBECTL_VERSION (pinned) at $KUBECTL" ;;
  *) ci_skip "kubectl is NOT the pinned $CI_PIN_KUBECTL_VERSION but ${kubectl_ver:-unknown} at $KUBECTL — the greenfield result is not from the pinned toolchain" ;;
esac

KUBECONFIG_FILE="$CI_WORK_DIR/kind.kubeconfig"
export KUBECONFIG="$KUBECONFIG_FILE"

cleanup() {
  if [ "$KEEP_CLUSTER" = "1" ]; then
    echo "  (CI_KIND_KEEP=1 — leaving cluster $CLUSTER_NAME up; KUBECONFIG=$KUBECONFIG_FILE)"
  else
    "$KIND" delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 1. An empty cluster. Deleted first so a leftover from a previous run cannot
#    make this test pass by having the objects already adopted.
"$KIND" delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
if "$KIND" create cluster --name "$CLUSTER_NAME" \
      --image "$CI_PIN_KIND_NODE_IMAGE" \
      --kubeconfig "$KUBECONFIG_FILE" --wait 180s >/dev/null 2>&1; then
  ci_pass "kind cluster $CLUSTER_NAME created from $CI_PIN_KIND_NODE_IMAGE"
else
  ci_fail "could not create the kind cluster"
  ci_summary "greenfield" || true
  exit 1
fi

# Prove it really is empty of anything of ours before we start.
if "$KUBECTL" get ns 2>/dev/null | grep -qE '^(ais-mgmt|xnat-ingest|edge-alpha)\b'; then
  ci_fail "the cluster is not empty — this test is meaningless unless it starts from nothing"
else
  ci_pass "cluster is empty: no ais-mgmt / xnat-ingest / edge-* namespaces"
fi

# -----------------------------------------------------------------------------
# 2. Prerequisite CRDs, pinned. CRDs only — see the header.
crd_dir="$CI_WORK_DIR/prereq-crds"
rm -rf "$crd_dir"; mkdir -p "$crd_dir"

fetch_crds() { # fetch_crds <label> <url> <dest>  -> prints the CRD count
  local label="$1" url="$2" dest="$3"
  local raw="$crd_dir/.$label.raw.yaml" errf="$crd_dir/.$label.curl.err"
  # curl's own stderr is captured rather than merged: with --retry it reports
  # each failed attempt, so a transient DNS failure that the retry recovered
  # from would otherwise be printed inside a PASS line.
  if ! _ci_fetch "$url" "$raw" 2>"$errf"; then
    printf 'download from %s failed: %s\n' "$url" "$(tr '\n' ' ' <"$errf")"
    return 1
  fi
  python3 -c '
import sys, yaml
src, dest = sys.argv[1], sys.argv[2]
crds = [d for d in yaml.safe_load_all(open(src))
        if d and d.get("kind") == "CustomResourceDefinition"]
if not crds:
    raise SystemExit("no CustomResourceDefinition in the downloaded manifest")
for c in crds:
    # The k0smotron CRDs declare a CONVERSION WEBHOOK served by the operator
    # (k0smotron.io/v1beta1 -> v1beta2). With the operator absent the API
    # server cannot even store a Cluster object:
    #   conversion webhook for k0smotron.io/v1beta1, Kind=Cluster failed:
    #   service "k0smotron-webhook-service-control-plane" not found
    # Strategy None lets the API server persist the object as written, which
    # is what this job needs to assert.
    #
    # SO BE PRECISE ABOUT WHAT IS PROVEN: that the chart CREATES its objects
    # in a cluster that started empty, and that they are schema-valid. NOT
    # that k0smotron accepts them — the operator, and its conversion and
    # validation webhooks, are not running here.
    if (c.get("spec") or {}).get("conversion", {}).get("strategy") == "Webhook":
        c["spec"]["conversion"] = {"strategy": "None"}
with open(dest, "w") as fh:
    yaml.safe_dump_all(crds, fh)
print(len(crds))
' "$raw" "$dest"
}

cm_url="https://github.com/cert-manager/cert-manager/releases/download/${CI_PIN_CERT_MANAGER_VERSION}/cert-manager.crds.yaml"
k0s_url="https://github.com/k0sproject/k0smotron/releases/download/${CI_PIN_K0SMOTRON_VERSION}/control-plane-components.yaml"

prereq_ok=1
for spec in "cert-manager|$cm_url" "k0smotron|$k0s_url"; do
  label="${spec%%|*}"; url="${spec#*|}"
  if n="$(fetch_crds "$label" "$url" "$crd_dir/$label.yaml" 2>&1)"; then
    # --server-side: the cert-manager CRDs exceed the 256KB last-applied
    # annotation that client-side apply writes.
    if "$KUBECTL" apply --server-side --force-conflicts -f "$crd_dir/$label.yaml" >/dev/null 2>&1; then
      ci_pass "prerequisite CRDs applied: $label ($n CRDs, pinned)"
    else
      ci_fail "applying $label CRDs failed"
      prereq_ok=0
    fi
  else
    ci_fail "prerequisite $label CRDs: $n"
    prereq_ok=0
  fi
done

if [ "$prereq_ok" = 0 ]; then
  ci_summary "greenfield" || true
  exit 1
fi
"$KUBECTL" wait --for=condition=Established --timeout=120s \
  crd/clusterissuers.cert-manager.io crd/certificates.cert-manager.io \
  crd/clusters.k0smotron.io >/dev/null 2>&1 || true

# certManager.clusterResourceNamespace names the namespace the RUNNING
# cert-manager controller was started with. The chart deliberately does not
# create it — cert-manager is installed out of band on every cluster we have —
# so it is a prerequisite here for the same reason the CRDs are.
if "$KUBECTL" create namespace "cert-manager" >/dev/null 2>&1; then
  ci_pass "prerequisite namespace created: cert-manager (certManager.clusterResourceNamespace)"
else
  ci_fail "could not create the cert-manager namespace"
fi

# -----------------------------------------------------------------------------
# 3 + 4. Install for real, then validate against the API server.
#
# THE ORDER IS DELIBERATE AND IT IS NOT THE OBVIOUS ONE. `--dry-run=server`
# before the first install FAILS on a fresh cluster, and not because anything
# is wrong: kube-prometheus-stack ships the monitoring.coreos.com CRDs in its
# own crds/ directory, and Helm applies subchart CRDs only during a REAL
# install. A dry run therefore sees no Prometheus / Alertmanager /
# PrometheusRule / ServiceMonitor kinds and reports
#   "no matches for kind ... ensure CRDs are installed first"
# for 16 objects. Measured on kind v1.35.5 with helm v3.20.1, and already noted
# in charts/mgmt/Chart.yaml. Install first, dry-run second.
#
# NEITHER CHART CREATES ITS WORKLOAD NAMESPACE, AND THAT IS DELIBERATE.
#
# The rule is uniform across both charts and written out in full in
# charts/edge/templates/namespace.yaml: NAMESPACES AND SECRETS FIRST, WORKLOADS
# SECOND. A workload that mounts a Secret cannot start before that Secret
# exists, and the Secret cannot exist before its namespace does. In a real
# install `scripts/site-secrets.sh apply` creates every namespace its Secrets
# name, and install.sh runs it before the corresponding release.
#
# So this job has to do the same thing, or it is not testing the install path.
#
# It used to claim, as "measured", that charts/mgmt created xnat-upload and
# charts/edge created xnat-ingest. Neither has ever been true. Both installs
# failed with `namespaces "xnat-upload" not found` and `namespaces
# "xnat-ingest" not found`, and nobody saw it because greenfield is in
# ALL_STAGES (make ci) and not FAST_STAGES (make ci-fast).
#
# `--create-namespace` still only covers the RELEASE namespace, which for
# charts/mgmt is ais-mgmt. The workload namespaces are pre-created below
# instead. Do NOT switch to --create-namespace for those: Helm would create
# them without ownership metadata and a later release that does render a
# Namespace aborts with "invalid ownership metadata", which looks exactly like
# the adoption collision this job exists to disprove.
prepare_workload_namespaces() { # <namespace>...
  for ns in "$@"; do
    if "$KUBECTL" get namespace "$ns" >/dev/null 2>&1; then
      ci_pass "workload namespace already present: $ns"
    elif "$KUBECTL" create namespace "$ns" >/dev/null 2>&1; then
      ci_pass "workload namespace pre-created, as site-secrets.sh apply would: $ns"
    else
      ci_fail "could not create workload namespace $ns"
    fi
  done
}
install_case() { # install_case <release> <namespace> <create-ns:0|1> <chart> <values...>
  local release="$1" ns="$2" create_ns="$3" chart="$4"; shift 4
  local args=()
  for v in "$@"; do args+=(-f "$CI_VALUES_DIR/$v"); done
  [ "$create_ns" = "1" ] && args+=(--create-namespace)

  if out="$("$HELM" install "$release" "$REPO_ROOT/$chart" \
              --namespace "$ns" \
              --no-hooks --wait=false --timeout 10m "${args[@]}" 2>&1)"; then
    ci_pass "greenfield install: $release into an empty cluster, no adoption step"
  else
    ci_fail "greenfield install: $release"
    printf '%s\n' "$out" | tail -30 | sed 's/^/        /'
    return 1
  fi

  # Every object re-validated by the API server now that the CRDs exist:
  # schema, defaulting, admission. This is also the upgrade path.
  if out="$("$HELM" upgrade "$release" "$REPO_ROOT/$chart" \
              --namespace "$ns" --dry-run=server "${args[@]}" 2>&1)"; then
    ci_pass "server-side validation: $release"
  else
    ci_fail "server-side validation: $release"
    printf '%s\n' "$out" | tail -20 | sed 's/^/        /'
    return 1
  fi
}

# xnat-upload  the management uploader and the s3-staged reclaimer live here,
#              not in the release namespace, because they mount the XNAT and
#              staging credentials and nothing else in ais-mgmt should read them.
# xnat-ingest  every object charts/edge renders goes here (.Values.namespace);
#              the chart never references .Release.Namespace.
# The per-edge namespaces are NOT listed: templates/edge-clusters.yaml does
# render those, and pre-creating them would cause the ownership collision the
# note above warns about.
prepare_workload_namespaces xnat-upload xnat-ingest

mgmt_ok=0
# TIER-1 ships no management chart, so there is no mgmt release to install.
# Skipping is correct here; failing would demand a chart this branch does not
# have. The count is reported so a green run cannot be mistaken for full
# coverage.
if [ -d "$REPO_ROOT/charts/mgmt" ]; then
  install_case mgmt ais-mgmt 1 charts/mgmt mgmt-base.yaml mgmt-two-edges.yaml && mgmt_ok=1
else
  ci_skip "greenfield install: mgmt — this branch ships no charts/mgmt (single node)"
  mgmt_ok=1
fi
edge_ok=0
install_case edge default 0 charts/edge edge-base.yaml && edge_ok=1

# The per-edge namespace and Cluster CR are exactly the objects that already
# exist unowned on the live management cluster (§8). Creating them here from
# nothing is the greenfield claim.
if [ "$mgmt_ok" = 1 ]; then
  if "$KUBECTL" get cluster.k0smotron.io -A -o name 2>/dev/null | grep -q .; then
    ci_pass "k0smotron Cluster objects created from the chart alone"
  else
    ci_fail "no k0smotron Cluster object was created — the per-edge control planes did not come from the chart"
  fi
fi

# -----------------------------------------------------------------------------
# 5. Retention, measured rather than read off a manifest.
if [ "$edge_ok" = 1 ]; then
  before="$("$KUBECTL" get pvc -n xnat-ingest -o name 2>/dev/null | sort || true)"
  pv_before="$("$KUBECTL" get pv -o name 2>/dev/null | sort || true)"
  if [ -z "$before" ]; then
    ci_fail "the edge release created no PVCs, so uninstall retention cannot be measured"
  else
    "$HELM" uninstall edge --namespace default >/dev/null 2>&1 || true
    after="$("$KUBECTL" get pvc -n xnat-ingest -o name 2>/dev/null | sort || true)"
    pv_after="$("$KUBECTL" get pv -o name 2>/dev/null | sort || true)"
    if [ "$before" = "$after" ] && [ "$pv_before" = "$pv_after" ]; then
      ci_pass "helm uninstall left every edge PVC and PV in place ($(printf '%s' "$before" | grep -c .) PVCs)"
    else
      ci_fail "helm uninstall removed storage that holds received DICOM. Before: [$before] [$pv_before]  After: [$after] [$pv_after]"
    fi
  fi
fi

ci_summary "greenfield"
