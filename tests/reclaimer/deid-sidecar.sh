#!/usr/bin/env bash
# =============================================================================
# The reclaimers read what the deidentify stage writes
# =============================================================================
# reclaim-files.py finds the XNAT resource label of a DICOM series from the
# SOPClassUID key in the resource's __METADATA__.json. It reads no DICOM
# header, so it KEEPS a series without that key (reclaim_kept,
# unmapped_resource).
#
# accessionflow 0.18.0 (#247) writes only __uid__ into the de-identified
# sidecars by default. Without --metadata-allowlist on the deidentify stage,
# every reclaimer keeps every series that stage writes, and the disk fills.
# There is no error and no alert, only reclaim_kept lines.
#
# WHAT IT DOES. In the pinned image: write a small labelled session (an MR
# series and a secondary capture), run the real `accessionflow deidentify`
# with the --metadata-allowlist value that the chart renders, then ask each
# copy of reclaim-files.py for the label of each output resource:
# MR -> DICOM, secondary capture -> secondary.
#
# THE CONTROL. The same run without the option must give unmapped_resource.
# If it does not, the probe no longer tells the two cases apart.
#
# Needs $CI_RENDER_DIR (make render) and docker. Without docker it skips;
# CI_REQUIRE_RECLAIMER_IMAGE=1 makes that a failure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "$HERE/../../scripts/ci/lib.sh"

ci_heading "reclaimers read the deidentify stage's output"

COPIES=()
for f in "$REPO_ROOT"/charts/*/files/reclaim-files.py; do COPIES+=("$f"); done
IMAGE="$(python3 -c "import yaml, sys; i = yaml.safe_load(open(sys.argv[1]))['ingest']['image']; print(i['repository'] + ':' + i['tag'])" "$REPO_ROOT/charts/edge/values.yaml")"

if [ ! -d "$CI_RENDER_DIR" ] || [ -z "$(ls -A "$CI_RENDER_DIR" 2>/dev/null)" ]; then
  ci_fail "$CI_RENDER_DIR is empty: run 'make render' first"
  ci_summary "deid-sidecar"; exit 1
fi

# The --metadata-allowlist value of every rendered deidentify container
# ("-" when a container does not pass the option).
ALLOW="$(python3 - "$CI_RENDER_DIR" <<'PY'
import glob, sys, yaml
found = set()
for f in sorted(glob.glob(sys.argv[1] + "/*.yaml")):
    try:
        docs = list(yaml.safe_load_all(open(f)))
    except yaml.YAMLError:
        continue
    for d in docs:
        if not isinstance(d, dict) or d.get("kind") != "Deployment":
            continue
        for c in d["spec"]["template"]["spec"].get("containers") or []:
            cmd = [str(x) for x in c.get("command") or []]
            if c.get("name") != "deidentify" or "accessionflow" not in cmd:
                continue
            args = [str(a) for a in c.get("args") or []]
            found.add(args[args.index("--metadata-allowlist") + 1] if "--metadata-allowlist" in args else "-")
print("\n".join(sorted(found)))
PY
)"
if [ -z "$ALLOW" ]; then
  ci_fail "no rendered deidentify container runs accessionflow: the extraction looks for the wrong shape"
  ci_summary "deid-sidecar"; exit 1
fi
if [ "$(printf '%s\n' "$ALLOW" | wc -l)" -ne 1 ]; then
  ci_fail "the renders pass different --metadata-allowlist values: $(printf '%s' "$ALLOW" | tr '\n' ' ')"
  ci_summary "deid-sidecar"; exit 1
fi
[ "$ALLOW" != "-" ] || ci_fail "a rendered deidentify container passes no --metadata-allowlist (default __uid__ only)"

skip() {
  if [ "${CI_REQUIRE_RECLAIMER_IMAGE:-0}" = "1" ]; then ci_fail "$1"; else ci_skip "$1"; fi
  ci_summary "deid-sidecar"; exit $?
}
command -v docker >/dev/null 2>&1 || skip "docker unavailable: cannot run deidentify from $IMAGE"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  anon="$(mktemp -d)"
  DOCKER_CONFIG="$anon" docker pull -q "$IMAGE" >/dev/null 2>&1
  rm -rf "$anon"
  docker image inspect "$IMAGE" >/dev/null 2>&1 || skip "$IMAGE unavailable"
fi

mounts=(-v "$HERE/deid-sidecar-probe.py:/probe/probe.py:ro")
targets=()
for f in "${COPIES[@]}"; do
  chart="$(basename "$(dirname "$(dirname "$f")")")"
  mounts+=(-v "$f:/probe/$chart/reclaim-files.py:ro")
  targets+=("/probe/$chart/reclaim-files.py")
done
OUT="$(timeout 300 docker run --rm --network none --memory 1g --pids-limit 256 \
  "${mounts[@]}" --entrypoint python3 "$IMAGE" /probe/probe.py "$ALLOW" "${targets[@]}" 2>&1)"
rc=$?
if [ $rc -ne 0 ] && ! printf '%s' "$OUT" | grep -q $'^\(OK\|BAD\)\t'; then
  ci_fail "the probe did not run in $IMAGE (exit $rc): $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
  ci_summary "deid-sidecar"; exit 1
fi
n=0
while IFS=$'\t' read -r verdict text; do
  case "$verdict" in
    OK)  ci_pass "$text"; n=$((n+1)) ;;
    BAD) ci_fail "$text"; n=$((n+1)) ;;
  esac
done <<<"$OUT"
# Two checks per copy: the chart's run and the control.
[ "$n" -eq $(( ${#COPIES[@]} * 2 )) ] || ci_fail "expected $(( ${#COPIES[@]} * 2 )) probe results, got $n: $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
ci_summary "deid-sidecar ($IMAGE)"
