#!/usr/bin/env bash
# =============================================================================
# 1. helm lint + helm template across the values matrix, for BOTH charts.
# =============================================================================
# Every case in scripts/ci/values.sh must lint clean and render. The rendered
# output is kept in $CI_RENDER_DIR/<case>.yaml and is the input to the
# PVC-retention and runtime-template checks, so those assert against exactly
# what CI rendered rather than re-rendering with slightly different values.
#
# The render is also parsed as YAML. `helm template` succeeding does not mean
# the output is valid YAML — an indentation bug in a `nindent` produces
# something helm is happy to print and the API server rejects.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/values.sh
. "$HERE/values.sh"

HELM="$(ci_helm)"
rm -rf "$CI_RENDER_DIR"
mkdir -p "$CI_RENDER_DIR"

ci_heading "helm lint"
# Lint once per chart per DISTINCT values combination: lint runs the templates,
# so a combination that only renders under `helm template` is not proven.
#
# MEASURED, and the reason the output is inspected rather than the exit code:
# with helm v3.20.1 and a chart that has subcharts, a `fail` raised inside a
# template is reported as
#     engine.go:227: [INFO] Fail: <message>
#     1 chart(s) linted, 0 chart(s) failed
# and `helm lint` EXITS 0. Trusting the exit code alone would have made every
# guard in charts/mgmt invisible to the lint stage. `helm template` below does
# fail correctly, which is why both run.
while IFS=$'\t' read -r name chart valuesfiles; do
  [ -n "$name" ] || continue
  args=()
  for v in $valuesfiles; do args+=(-f "$CI_VALUES_DIR/$v"); done
  rc=0
  out="$("$HELM" lint "$REPO_ROOT/$chart" "${args[@]}" 2>&1)" || rc=$?
  bad=0
  [ "$rc" -ne 0 ] && bad=1
  printf '%s\n' "$out" | grep -qE '\[ERROR\]|\] Fail:' && bad=1
  if [ "$bad" -eq 1 ]; then
    ci_fail "lint $name (exit $rc)"
    printf '%s\n' "$out" | sed 's/^/        /'
  else
    ci_pass "lint $name"
  fi
done < <(ci_positive_cases | ci_charts_present)

ci_heading "helm template"
while IFS=$'\t' read -r name chart valuesfiles; do
  [ -n "$name" ] || continue
  args=()
  for v in $valuesfiles; do args+=(-f "$CI_VALUES_DIR/$v"); done
  # Release name differs per chart so the release-name-derived labels and
  # hostnames are exercised, not defaulted away.
  release="mgmt"; ns="ais-mgmt"
  case "$chart" in */edge) release="edge"; ns="xnat-ingest" ;; esac

  dest="$CI_RENDER_DIR/$name.yaml"
  if out="$("$HELM" template "$release" "$REPO_ROOT/$chart" "${args[@]}" \
              --namespace "$ns" 2>&1 >"$dest")"; then
    :
  else
    ci_fail "template $name"
    printf '%s\n' "$out" | sed 's/^/        /'
    rm -f "$dest"
    continue
  fi

  if [ ! -s "$dest" ]; then
    ci_fail "template $name produced NO output — a chart that renders nothing passes every other check in this suite"
    continue
  fi

  # Parse it. `helm template` will happily emit YAML the API server rejects.
  if err="$(python3 -c '
import sys, yaml
docs = list(yaml.safe_load_all(open(sys.argv[1])))
n = len([d for d in docs if d])
if n == 0:
    raise SystemExit("no Kubernetes objects in the render")
print(n)
' "$dest" 2>&1)"; then
    ci_pass "template $name ($err objects)"
  else
    ci_fail "template $name rendered invalid YAML: $err"
  fi
done < <(ci_positive_cases | ci_charts_present)

# -----------------------------------------------------------------------------
# No version-bearing label may reach a selector
# -----------------------------------------------------------------------------
# THIS CHECK EXISTS BECAUSE A ROUTINE VERSION BUMP TOOK A SITE OFFLINE, AND EVERY
# OTHER STAGE IN THIS SUITE WAS GREEN BEFORE AND AFTER IT.
#
# k0smotron copies a k0smotron.io Cluster's labels onto the Services it generates
# AND uses those labels as the Services' selectors. The chart's shared label
# helper carries helm.sh/chart (which embeds .Chart.Version) and
# app.kubernetes.io/version (.Chart.AppVersion). Bumping the chart 0.1.0 -> 0.1.1
# for an image CVE therefore regenerated a selector asking for
# helm.sh/chart=ais-mgmt-0.1.1 while the running kmc-<edge>-0 pod still carried
# 0.1.0 — endpoints dropped to zero, the child API became unreachable and
# cert-sync failed with a connection timeout. Nothing crashed, nothing restarted
# and nothing logged an error.
#
# A StatefulSet's pod template labels are fixed when its pods are created and its
# selector is immutable, so this can never self-heal.
#
# Two things are asserted, because either alone would have missed it:
#   1. no Service SELECTOR this chart renders contains a version-bearing key;
#   2. no object whose labels a controller turns into a selector carries one
#      either — today that means k0smotron.io Cluster objects.
ci_heading "no version-bearing label reaches a selector"
python3 - "$CI_RENDER_DIR" <<'PY' > "$CI_WORK_DIR/selector-labels.txt" 2>&1 || true
import os, sys, yaml

render_dir = sys.argv[1]

# Keys whose VALUE changes when the chart is released. They describe a release,
# not a workload, so they can never be part of an identity match.
VERSIONED = {"helm.sh/chart", "app.kubernetes.io/version"}

# Kinds whose metadata.labels are propagated into a Service selector by their
# controller. Add a kind here the moment another controller does the same.
SELECTOR_SOURCE_KINDS = {"Cluster"}

checked = 0
for fn in sorted(os.listdir(render_dir)):
    if not fn.endswith(".yaml"):
        continue
    case = fn[:-5]
    try:
        docs = [d for d in yaml.safe_load_all(open(os.path.join(render_dir, fn))) if d]
    except Exception as exc:
        print(f"FAIL {case}: unreadable render ({exc})")
        continue

    for d in docs:
        kind = d.get("kind")
        md = d.get("metadata") or {}
        name = md.get("name", "?")

        if kind == "Service":
            sel = (d.get("spec") or {}).get("selector") or {}
            bad = sorted(VERSIONED & set(sel))
            if bad:
                print(f"FAIL {case}: Service/{name} selector contains {bad} — "
                      "the selector stops matching its own pods on the next chart release")
                continue
            checked += 1

        # k0smotron.io only — Cluster is also a Cluster API / cluster.x-k8s.io kind
        # whose labels are not used this way, and failing on it would be noise.
        if kind in SELECTOR_SOURCE_KINDS and "k0smotron.io" in str(d.get("apiVersion", "")):
            bad = sorted(VERSIONED & set(md.get("labels") or {}))
            if bad:
                print(f"FAIL {case}: {kind}/{name} carries {bad}, and k0smotron copies "
                      "these onto the Services it generates AND selects on them — use "
                      "mgmt.selectorSafeLabels")
                continue
            checked += 1

if checked == 0:
    print("FAIL no Services or k0smotron Cluster objects were examined — "
          "the check is not looking at anything")
else:
    print(f"PASS {checked} selector-bearing object(s) carry no version label")
PY

if [ ! -s "$CI_WORK_DIR/selector-labels.txt" ]; then
  ci_fail "selector-label check produced no output"
else
  while IFS= read -r line; do
    case "$line" in
      PASS\ *) ci_pass "${line#PASS }" ;;
      FAIL\ *) ci_fail "${line#FAIL }" ;;
      *)       ci_fail "selector-label check error: $line" ;;
    esac
  done < "$CI_WORK_DIR/selector-labels.txt"
fi

# =============================================================================
# Every component a dashboard queries must be one this chart actually deploys.
# =============================================================================
# A dashboard panel selecting a component that does not exist is not an error
# anywhere: Grafana draws an empty graph, Loki answers "no data", and the
# operator reads a blank "Upload failures" panel as "no failures". That is
# strictly worse than a broken panel, because it looks like good news.
#
# This is how the dashboards arrived here: they were written for tier-2, whose
# uploader is labelled `s3-uploader`. Tier-1 runs `upload`, so ten panels were
# permanently blank on the tier where the pipeline's only uploader lives.
ci_heading "dashboards query components that exist"

DASH_DIR="$(ci_obs_chart)/files/dashboards"
if [ ! -d "$REPO_ROOT/$DASH_DIR" ]; then
  ci_skip "no dashboards in $(ci_obs_chart)"
else
  # Compared against THE CONFIGURATION THIS TIER ACTUALLY RUNS, rendered from
  # the shipped example site — not against the union of every rendered case.
  # The union was the first attempt and it silently passed: the render matrix
  # includes upload.mode=s3 fixtures, so `s3-uploader` appeared "deployed" and
  # the exact bug this check exists for went undetected on a green run.
  SITE_VALUES=""
  for cand in "$REPO_ROOT/sites/example-single/values.yaml" "$REPO_ROOT/sites/example-edge/values.yaml"; do
    [ -f "$cand" ] && { SITE_VALUES="$cand"; break; }
  done
  deployed=""
  if [ -n "$SITE_VALUES" ]; then
    deployed="$(helm template ci "$REPO_ROOT/$(ci_obs_chart)" -f "$SITE_VALUES" \
                  --set orthanc.deid.policyReviewed=true 2>/dev/null \
                | grep -o 'component: [a-z0-9-]*' | sed 's/component: //' | sort -u)"
  fi
  if [ -z "$deployed" ]; then
    ci_fail "dashboard-component check: could not render $(ci_obs_chart) from a site example to learn which components exist"
  else
    for f in "$REPO_ROOT/$DASH_DIR"/*.json; do
      [ -e "$f" ] || continue
      bad=""
      for c in $(grep -oh 'component=\\*"[a-z0-9-]*' "$f" | sed 's/.*component=\\*"//' | sort -u); do
        printf '%s\n' "$deployed" | grep -qx "$c" || bad="${bad} ${c}"
      done
      # docs/dashboards.md: "There is no `event` field on tier-1, and no panel
      # may depend on one." event=upload_started|completed|failed is the
      # convention of files/s3-uploader.sh, which only runs under
      # upload.mode: s3. A panel filtering on it here returns nothing, forever.
      # Enforced rather than trusted, because the blank panel looks identical
      # to a quiet site.
      if [ "$(ci_obs_chart)" = "charts/edge" ] && [ ! -d "$REPO_ROOT/charts/mgmt" ]; then
        if grep -q 'event *!=\|event=\\"upload_\|{{event}}' "$f"; then
          bad="${bad} <depends-on-the-'event'-field>"
        fi
      fi
      if [ -n "$bad" ]; then
        ci_fail "$(basename "$f") queries component(s)/field(s) this tier never produces:${bad} — those panels are permanently blank, which reads as 'nothing wrong'"
      else
        ci_pass "$(basename "$f") queries only deployed components"
      fi
    done
  fi
fi

ci_summary "render"
