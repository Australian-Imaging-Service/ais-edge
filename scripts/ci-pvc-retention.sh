#!/usr/bin/env bash
# =============================================================================
# 5. PVC retention assertion
# =============================================================================
# Renders both charts across the whole matrix and FAILS if anything that holds
# data can be deleted automatically.
#
# WHY THIS EXISTS. `helm.sh/resource-policy: keep` was used as the retention
# story throughout both charts. It governs HELM, and nothing else. The Loki
# StatefulSet carried the annotation AND
#     persistentVolumeClaimRetentionPolicy: {whenDeleted: Delete, whenScaled: Delete}
# so scaling it to zero — or deleting the StatefulSet — took the log store with
# it, annotation and all. The annotation had been assumed sufficient in one
# place, so it has to be assumed to have been assumed sufficient everywhere
# until something checks. This is that something.
#
# WHAT IS ASSERTED, and each is a different mechanism:
#
#   1. persistentVolumeClaimRetentionPolicy — anywhere at any depth, including
#      inside subchart output — must not say Delete for whenDeleted or
#      whenScaled. This is the StatefulSet controller, which the annotation
#      does not reach.
#   2. Every PersistentVolumeClaim object carries helm.sh/resource-policy: keep.
#      This is `helm uninstall`.
#   3. Every volumeClaimTemplate / volumeClaimTemplates entry, at any depth,
#      carries the same annotation — this covers StatefulSets and the
#      Prometheus / Alertmanager CRs, whose templates the operator turns into
#      real PVCs.
#   4. Every PersistentVolume uses persistentVolumeReclaimPolicy: Retain. This
#      is the bytes on the node: with Delete, releasing the claim deletes the
#      backing directory.
#
# Traversal is by SHAPE, not by kind. A kind list would have missed the
# Prometheus and Alertmanager CRs, which are not StatefulSets and do carry a
# volumeClaimTemplate, and it would miss whatever a subchart bump introduces
# next.
#
# LIMIT, stated rather than implied: this reads rendered manifests. A PVC that
# a subchart creates at runtime through an operator, from a template not
# present in the render, is invisible here.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci-lib.sh
. "$HERE/ci-lib.sh"

ci_heading "PVC retention"

shopt -s nullglob
renders=("$CI_RENDER_DIR"/*.yaml)
if [ "${#renders[@]}" -eq 0 ]; then
  ci_fail "no renders in $CI_RENDER_DIR — run scripts/ci-render.sh first (make ci does)"
  ci_summary "pvc-retention" || true
  exit 1
fi

for render in "${renders[@]}"; do
  case_name="$(basename "$render" .yaml)"
  rc=0
  out="$(python3 - "$render" <<'PY'
import sys, yaml

KEEP = ("helm.sh/resource-policy", "keep")
problems = []
checked = 0

def annotated_keep(meta):
    return (meta or {}).get("annotations", {}).get(KEEP[0]) == KEEP[1]

def where(kind, name, path):
    return f"{kind}/{name}" + (f" at {path}" if path else "")

def walk(node, path, kind, name):
    """Find retention-relevant shapes at any depth, including subchart output."""
    global checked
    if isinstance(node, dict):
        # 1. StatefulSet-controller-driven deletion.
        p = node.get("persistentVolumeClaimRetentionPolicy")
        if isinstance(p, dict):
            checked += 1
            for field in ("whenDeleted", "whenScaled"):
                if p.get(field) == "Delete":
                    problems.append(
                        f"{where(kind, name, path)}: persistentVolumeClaimRetentionPolicy.{field}=Delete. "
                        "helm.sh/resource-policy: keep does not govern the StatefulSet controller — "
                        "this volume is deleted when the StatefulSet is deleted or scaled to zero."
                    )
        # 3. Templates the controller/operator turns into real PVCs.
        for key in ("volumeClaimTemplate", "volumeClaimTemplates"):
            v = node.get(key)
            if v is None:
                continue
            entries = v if isinstance(v, list) else [v]
            for i, t in enumerate(entries):
                if not isinstance(t, dict):
                    continue
                checked += 1
                if not annotated_keep(t.get("metadata")):
                    tname = (t.get("metadata") or {}).get("name", f"[{i}]")
                    problems.append(
                        f"{where(kind, name, path)}: {key} {tname} has no helm.sh/resource-policy: keep annotation"
                    )
        for k, v in node.items():
            walk(v, f"{path}.{k}" if path else k, kind, name)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, f"{path}[{i}]", kind, name)

for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not doc or not isinstance(doc, dict):
        continue
    kind = doc.get("kind", "?")
    name = (doc.get("metadata") or {}).get("name", "?")

    # 2. PVC objects.
    if kind == "PersistentVolumeClaim":
        checked += 1
        if not annotated_keep(doc.get("metadata")):
            problems.append(
                f"PersistentVolumeClaim/{name} has no helm.sh/resource-policy: keep annotation — "
                "helm uninstall would delete it"
            )

    # 4. The bytes on the node.
    if kind == "PersistentVolume":
        checked += 1
        policy = (doc.get("spec") or {}).get("persistentVolumeReclaimPolicy")
        if policy != "Retain":
            problems.append(
                f"PersistentVolume/{name} has persistentVolumeReclaimPolicy={policy!r}, not Retain — "
                "releasing the claim deletes the backing data"
            )
        if not annotated_keep(doc.get("metadata")):
            problems.append(
                f"PersistentVolume/{name} has no helm.sh/resource-policy: keep annotation"
            )

    walk(doc, "", kind, name)

if problems:
    for p in problems:
        print("        " + p)
    raise SystemExit(1)
print(checked)
PY
)" || rc=$?

  if [ "$rc" -eq 0 ]; then
    if [ "${out:-0}" = "0" ]; then
      # Not a pass. A case that renders no storage at all proves nothing, and
      # silently counting it as green is how a check stops checking.
      ci_skip "$case_name renders no PVC, PV or volumeClaimTemplate — nothing to assert"
    else
      ci_pass "$case_name ($out storage objects, all retained)"
    fi
  else
    ci_fail "$case_name has auto-deletable data volumes"
    printf '%s\n' "$out"
  fi
done

ci_summary "pvc-retention"
