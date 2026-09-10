#!/usr/bin/env bash
# =============================================================================
# Chart argv vs the binary's actual CLI signature
# =============================================================================
# The charts invoke xnat-ingest with positional arguments and options. The image
# is pinned by tag, so upstream can change that signature under us and nothing in
# this repo would notice: helm still renders, the manifest is still valid, and
# the failure is a CrashLoopBackOff on a live box.
#
# MEASURED, upgrading 0.13.1 -> 0.15.0, two independent breaks:
#
#     deidentify   reid_dir stopped being the fourth positional and became a
#                  --reid-dir OPTION:
#                    Error: Got unexpected extra argument (/data/reid)
#     group        --on-resource-clash changed from a single choice to a
#                  <policy> <scope> pair, and group-orthanc never had the
#                  option at all:
#                    Error: No such option: --on-resource-clash
#
# Neither was catchable before this stage, because the chart's args and the
# binary's signature were two sources of truth with nothing comparing them.
#
# WHAT IT ASKS ABOUT. Every container in $CI_RENDER_DIR whose command is
# `xnat-ingest`, across every values combination the render stage covers, taken
# from the rendered manifest rather than transcribed here. A transcription is a
# third source of truth that drifts from the chart silently, which defeats the
# purpose. Env references like $(ORTHANC_USER) are left as they are: they are
# literal strings to the parser, and substituting them would test something the
# cluster never runs.
#
# HOW IT ASKS. Through click's make_context(), which does the full parse and
# validation and then STOPS, without invoking the command body. That distinction
# is the whole design:
#
#   * `xnat-ingest deidentify ... --loop 60` parses fine and then RUNS FOREVER.
#     An earlier version of this stage did exactly that and hung CI. Worse, it
#     hung only when the argv was CORRECT, so the stage could only ever report
#     failure — a check that cannot pass is not a check.
#   * Nothing here opens a socket, reads a study or writes to a store, so it
#     needs no fixtures and cannot flake on the network.
#
# WHAT IT DOES NOT CATCH. Anything that only shows up once the command body
# runs. group-orthanc's copy_mode raise is the example: the argv is accepted
# here and the pod dies later, which is why that one needs a render guard in
# _helpers.tpl instead. Parse errors here, runtime contracts there.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "$HERE/lib.sh"

ci_heading "chart argv parses against the pinned image"

# The INGEST image specifically. An earlier version of this line grepped for the
# first '  image:' block in values.yaml and picked up samba's, so a check meant
# to protect the pipeline was testing a file server instead. Parse the YAML and
# name the key rather than matching on shape.
IMAGE="$(python3 -c "
import yaml, sys
v = yaml.safe_load(open(sys.argv[1]))
img = v['ingest']['image']
print('%s:%s' % (img['repository'], img['tag']))
" "$REPO_ROOT/charts/edge/values.yaml" 2>/dev/null)"
if [ -z "${IMAGE:-}" ] || [ "${IMAGE#:}" != "$IMAGE" ]; then
  ci_fail "could not determine ingest.image from charts/edge/values.yaml"
  ci_summary "cli-contract"; exit 1
fi

if [ ! -d "$CI_RENDER_DIR" ] || [ -z "$(ls -A "$CI_RENDER_DIR" 2>/dev/null)" ]; then
  ci_fail "$CI_RENDER_DIR is empty — run 'make render' first"
  ci_summary "cli-contract"; exit 1
fi
if ! command -v docker >/dev/null 2>&1; then
  ci_skip "docker unavailable — cannot check argv against $IMAGE"
  ci_summary "cli-contract"; exit 0
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1 && ! docker pull -q "$IMAGE" >/dev/null 2>&1; then
  ci_skip "$IMAGE unavailable — cannot check argv"
  ci_summary "cli-contract"; exit 0
fi

# Every distinct (subcommand, argv) the charts render, plus two controls.
#
# THE CONTROLS ARE NOT DECORATION. They are the exact forms that broke on
# 0.15.0, and they must be REJECTED. If they ever start being accepted, the
# probe has stopped discriminating and every pass above them is meaningless —
# which is the failure mode of a checker that can only ever say yes.
CASES="$(python3 -c "
import glob, sys, yaml, collections
seen = collections.OrderedDict()

def walk(o):
    if isinstance(o, dict):
        for key in ('containers', 'initContainers'):
            for c in (o.get(key) or []):
                cmd = c.get('command') or []
                if cmd[:1] == ['xnat-ingest']:
                    sub = cmd[1] if len(cmd) > 1 else ''
                    argv = ' '.join(str(a) for a in (c.get('args') or []))
                    seen.setdefault((sub, argv), None)
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)

for f in sorted(glob.glob(sys.argv[1] + '/*.yaml')):
    try:
        docs = list(yaml.safe_load_all(open(f)))
    except yaml.YAMLError:
        continue
    for d in docs:
        walk(d)

for sub, argv in seen:
    print('accept|%s|%s' % (sub, argv))
" "$CI_RENDER_DIR")
reject|deidentify|/w/in /w/out /w/specs /w/reid
reject|group-orthanc|http://orthanc:8042 /w/store /w/grouped user pass --on-resource-clash avoid all"

if [ "$(printf '%s\n' "$CASES" | grep -c '^accept|')" -eq 0 ]; then
  ci_fail "no xnat-ingest container found in $CI_RENDER_DIR — the extraction is looking for the wrong shape"
  ci_summary "cli-contract"; exit 1
fi

# One container for every case. A hard timeout as a backstop: make_context does
# not run the command, so this returns in seconds, and if it ever does not the
# stage must fail loudly rather than hang a CI run.
OUT="$(printf '%s\n' "$CASES" | timeout 300 docker run --rm -i --entrypoint python3 "$IMAGE" -c '
import os, sys, click
from xnat_ingest.cli import cli

# click validates path arguments, so a missing directory would be reported as an
# argument error and read as a signature break. Create what the charts name.
for d in ("/w/in", "/w/out", "/w/specs", "/w/reid", "/w/store", "/w/grouped",
          "/data/incoming", "/data/grouped", "/data/assigned", "/data/deidentified",
          "/data/reid", "/data/orthanc-storage", "/etc/xnat-ingest/deid-specs"):
    os.makedirs(d, exist_ok=True)

root = click.Context(cli)
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    want, name, argv = line.split("|", 2)
    cmd = cli.get_command(root, name)
    if cmd is None:
        print("MISSING\t%s\tthe image has no subcommand %r" % (name, name))
        continue
    try:
        with cmd.make_context(name, argv.split(), parent=root):
            pass
        got, why = "accept", ""
    except click.exceptions.Exit:
        got, why = "accept", ""
    except Exception as e:
        got, why = "reject", str(e).splitlines()[0]
    if got == want:
        print("OK\t%s\t%s" % (name, "rejected as expected" if want == "reject" else ""))
    elif want == "accept":
        print("BAD\t%s\t%s" % (name, why))
    else:
        print("BAD\t%s\tACCEPTED an argv known to be broken — this probe is no longer discriminating" % name)
' 2>&1)"

rc=$?
if [ $rc -ne 0 ] && ! printf '%s' "$OUT" | grep -q $'\t'; then
  ci_fail "could not run the argv probe against $IMAGE (exit $rc): $(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"
  ci_summary "cli-contract"; exit 1
fi

while IFS=$'\t' read -r verdict name why; do
  [ -n "${verdict:-}" ] || continue
  case "$verdict" in
    OK)      ci_pass "$name${why:+ $why}" ;;
    BAD)     ci_fail "$name: $IMAGE disagrees with the argv this chart renders${why:+ — $why}" ;;
    MISSING) ci_fail "$why" ;;
    *)       ci_fail "unparseable probe output: $verdict $name $why" ;;
  esac
done <<<"$OUT"

ci_summary "cli-contract"
