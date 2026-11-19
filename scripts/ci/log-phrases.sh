#!/usr/bin/env bash
# =============================================================================
# Alert log phrases vs the code that writes them
# =============================================================================
# A Loki rule matches log TEXT. The tool writes that text, the image is pinned
# by tag, and nothing compared the two. When upstream rewords a message, the
# rule still parses and its fixture tests still pass, because the fixtures
# hold the OLD text. The alert then never fires again, and nothing says so.
#
# MEASURED, upgrading 0.16.2.post1 -> accessionflow 0.19.0: assign's
#     Could not resolve project/subject/session IDs for '<name>'
# became
#     Could not resolve the labels of '<name>'
# so InvalidSessionAssigned would have gone quiet with sessions in __invalid__.
#
# WHAT IT CHECKS. Every literal part of each rule's line filters, `message` and
# `event` filters and `regexp` patterns must exist in the source that writes
# it: the Python package inside the pinned image for the tool's stages, this
# repo for our own components (data-policy, reclaimers, orthanc). The rules
# file itself and the test fixtures are never counted as a source.
#
# WHAT IT DOES NOT CATCH. A phrase that still exists in the source but is no
# longer logged on that path. It proves the words exist, not that they fire.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "$HERE/lib.sh"

ci_heading "alert log phrases exist in the code that logs them"

# Every pin of the tool, in every chart. They must be one image: on tier-2 the
# edge stages, the management uploader and the S3 reclaimer each pin it, and
# their logs reach the same rules.
PINS="$(python3 -c "
import glob, sys, yaml
pins = set()
def walk(node):
    if isinstance(node, dict):
        repo = str(node.get('repository', ''))
        if 'tag' in node and ('xnat-ingest' in repo or 'accessionflow' in repo):
            pins.add('%s:%s' % (repo, node['tag']))
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)
for path in sorted(glob.glob(sys.argv[1] + '/charts/*/values.yaml')):
    walk(yaml.safe_load(open(path)))
print('\\n'.join(sorted(pins)))
" "$REPO_ROOT" 2>/dev/null)"
if [ -z "$PINS" ]; then
  ci_fail "no xnat-ingest or accessionflow image pin found in charts/*/values.yaml"
  ci_summary "log-phrases"; exit 1
fi
if [ "$(printf '%s\n' "$PINS" | wc -l)" -gt 1 ]; then
  ci_fail "the charts pin different images: $(printf '%s ' $PINS)"
  ci_summary "log-phrases"; exit 1
fi
IMAGE="$PINS"

RULES=()
for f in "$REPO_ROOT"/charts/*/files/loki-ruler-rules.yaml; do
  [ -f "$f" ] && RULES+=("$f")
done
if [ "${#RULES[@]}" -eq 0 ]; then
  ci_fail "no charts/*/files/loki-ruler-rules.yaml found"
  ci_summary "log-phrases"; exit 1
fi

# Same as the other docker stages: skip loudly, or fail when required.
_skip_or_fail() {
  if [ "${CI_REQUIRE_LOG_PHRASES:-0}" = "1" ]; then ci_fail "$1"; else ci_skip "$1"; fi
  ci_summary "log-phrases"; exit $?
}
command -v docker >/dev/null 2>&1 || _skip_or_fail "docker unavailable: cannot read the source in $IMAGE"

# Pull anonymously when the image is missing. A stored registry login that the
# registry refuses would otherwise fail the pull of a PUBLIC image.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  anon="$(mktemp -d)"
  DOCKER_CONFIG="$anon" docker pull -q "$IMAGE" >/dev/null 2>&1
  rm -rf "$anon"
  docker image inspect "$IMAGE" >/dev/null 2>&1 || _skip_or_fail "$IMAGE unavailable: cannot read its source"
fi

SRC="$(mktemp -d)"
trap 'rm -rf "$SRC"' EXIT
# Find the package WITHOUT importing it. accessionflow is a namespace package
# (store plugins add portions to it), so it has no __file__, and it may have
# more than one directory.
PKGS="$(docker run --rm --network none --entrypoint python3 "$IMAGE" -c '
import importlib.util as u
for name in ("accessionflow", "xnat_ingest"):
    spec = u.find_spec(name)
    if spec and spec.submodule_search_locations:
        print("\n".join(spec.submodule_search_locations)); break' 2>/dev/null)"
if [ -z "$PKGS" ]; then
  ci_fail "$IMAGE: no accessionflow or xnat_ingest package found"
  ci_summary "log-phrases"; exit 1
fi
n=0
while IFS= read -r pkg; do
  [ -n "$pkg" ] || continue
  n=$((n + 1)); mkdir -p "$SRC/$n"
  docker run --rm --network none --entrypoint tar "$IMAGE" -C "$pkg" -cf - . 2>/dev/null | tar -xf - -C "$SRC/$n"
done <<< "$PKGS"

# Capture first, then read: a process substitution drops the exit status, so a
# crash (a rule file that does not parse) gave "0 passed, 0 failed" and exit 0.
OUT="$(python3 "$HERE/log-phrases.py" "$SRC" "$REPO_ROOT" "${RULES[@]}" 2>&1)"
rc=$?
lines=0
while IFS=$'\t' read -r verdict alert detail; do
  case "$verdict" in
    PASS) ci_pass "$alert: $detail"; lines=$((lines + 1)) ;;
    FAIL) ci_fail "$alert: $detail"; lines=$((lines + 1)) ;;
    SKIP) ci_skip "$alert: $detail"; lines=$((lines + 1)) ;;
  esac
done <<< "$OUT"
if [ "$rc" -ne 0 ] && ! printf '%s\n' "$OUT" | grep -q $'^FAIL\t'; then
  ci_fail "log-phrases.py stopped with exit $rc and no verdict: $(printf '%s' "$OUT" | tail -3 | tr '\n' ' ')"
fi
[ "$lines" -gt 0 ] || ci_fail "log-phrases.py gave no verdict at all"

ci_summary "log-phrases ($IMAGE)"
