#!/usr/bin/env bash
# =============================================================================
# Chart argv and env vs the pinned image's actual CLI
# =============================================================================
# The charts invoke accessionflow (called xnat-ingest before 0.18.0) with
# positional arguments, options and environment variables. The image is pinned
# by tag, so upstream can change that contract under us and nothing in this
# repo would notice: helm still renders, the manifest is still valid, and the
# failure is a CrashLoopBackOff on a live box, or worse, nothing at all.
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
# MEASURED, upgrading 0.16.2.post1 -> accessionflow 0.19.0: every command and
# every XINGEST_* variable was renamed (group-orthanc -> collate-orthanc,
# assign -> label xnat, upload -> store xnat, XINGEST_* -> ACFLOW_*). A missed
# env rename is SILENT: an unset ACFLOW_REID_ENCRYPT_KEY writes the
# re-identification maps in plain text with no error.
#
# WHAT IT ASKS ABOUT. Every container in $CI_RENDER_DIR that runs the tool,
# directly or under the stage lock wrapper (/bin/sh -c <loop> accessionflow
# <command...>), across every values combination the render stage covers,
# taken from the rendered manifest rather than transcribed here.
#   1. The argv parses: click's make_context() does the full parse and
#      validation and then STOPS, without running the command (a correct
#      `--loop 60` would otherwise run for ever and hang CI).
#   2. No container sets an XINGEST_* variable: the tool never reads them.
#   3. Every ACFLOW_* variable a container sets is one the image's CLI declares,
#      so a misspelt name fails here instead of being ignored on a live box.
#
# THE CONTROLS ARE NOT DECORATION. Two argv forms known to be broken must be
# REJECTED. If they are ever accepted, the probe has stopped discriminating.
#
# WHAT IT DOES NOT CATCH. Anything that only shows up once the command body
# runs, such as group-orthanc's copy_mode raise (a render guard covers that).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "$HERE/lib.sh"

ci_heading "chart argv and env parse against the pinned image"

# Every pin of the tool in every chart must be one image (see log-phrases.sh).
IMAGE="$(python3 -c "
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
print(' '.join(sorted(pins)))
" "$REPO_ROOT" 2>/dev/null)"
case "$IMAGE" in
  "") ci_fail "no xnat-ingest or accessionflow image pin found in charts/*/values.yaml"
      ci_summary "cli-contract"; exit 1 ;;
  *" "*) ci_fail "the charts pin different images: $IMAGE"
      ci_summary "cli-contract"; exit 1 ;;
esac

if [ ! -d "$CI_RENDER_DIR" ] || [ -z "$(ls -A "$CI_RENDER_DIR" 2>/dev/null)" ]; then
  ci_fail "$CI_RENDER_DIR is empty — run 'make render' first"
  ci_summary "cli-contract"; exit 1
fi

# Every distinct (command path, argv) the charts render, the env names they
# set, plus the two controls (the exact forms that broke on 0.15.0).
EXTRACT="$(python3 -c "
import glob, sys, yaml, collections
seen = collections.OrderedDict()
envs = collections.OrderedDict()

def walk(o):
    if isinstance(o, dict):
        for key in ('containers', 'initContainers'):
            for c in (o.get(key) or []):
                cmd = [str(x) for x in (c.get('command') or [])]
                if cmd[:2] == ['/bin/sh', '-c'] and cmd[3:4] and cmd[3] in ('accessionflow', 'xnat-ingest'):
                    cmd = cmd[3:]
                if cmd[:1] and cmd[0] in ('accessionflow', 'xnat-ingest'):
                    path = ' '.join(cmd[1:])
                    argv = ' '.join(str(a) for a in (c.get('args') or []))
                    seen.setdefault((path, argv), None)
                    for e in c.get('env') or []:
                        envs.setdefault(e['name'], path)
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

for path, argv in seen:
    print('accept|%s|%s' % (path, argv))
for name, path in envs.items():
    if name.startswith(('ACFLOW_', 'XINGEST_')):
        print('env|%s|%s' % (path, name))
" "$CI_RENDER_DIR")"
CASES="$EXTRACT
reject|deidentify|/w/in /w/out /w/specs /w/reid
reject|collate-orthanc|http://orthanc:8042 /w/store /w/grouped user pass --on-resource-clash avoid all"

if [ "$(printf '%s\n' "$CASES" | grep -c '^accept|')" -eq 0 ]; then
  ci_fail "no accessionflow container found in $CI_RENDER_DIR — the extraction is looking for the wrong shape"
  ci_summary "cli-contract"; exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  ci_skip "docker unavailable — cannot check argv against $IMAGE"
  ci_summary "cli-contract"; exit 0
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  # Anonymous pull: a stored registry login that the registry refuses would
  # otherwise fail the pull of a PUBLIC image.
  anon="$(mktemp -d)"
  DOCKER_CONFIG="$anon" docker pull -q "$IMAGE" >/dev/null 2>&1
  rm -rf "$anon"
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    ci_skip "$IMAGE unavailable — cannot check argv"
    ci_summary "cli-contract"; exit 0
  fi
fi

# One container for every case. A hard timeout as a backstop: make_context does
# not run the command, so this returns in seconds.
OUT="$(printf '%s\n' "$CASES" | timeout 300 docker run --rm -i --network none --entrypoint python3 "$IMAGE" -c '
import os, sys, click
try:
    from accessionflow.cli import cli
except ImportError:
    from xnat_ingest.cli import cli

# click validates path arguments, so a missing directory would be reported as an
# argument error and read as a signature break. Create what the charts name.
for d in ("/w/in", "/w/out", "/w/specs", "/w/reid", "/w/store", "/w/grouped",
          "/data/incoming", "/data/grouped", "/data/assigned", "/data/deidentified",
          "/data/packaged", "/data/reid", "/data/orthanc-storage", "/etc/xnat-ingest/deid-specs"):
    os.makedirs(d, exist_ok=True)

def declared(cmd, ctx, out):
    """Every envvar that the CLI declares, through every group."""
    for p in getattr(cmd, "params", []):
        for name in ([p.envvar] if isinstance(p.envvar, str) else (p.envvar or [])):
            out.add(name)
    if isinstance(cmd, click.Group):
        for n in cmd.list_commands(ctx):
            sub = cmd.get_command(ctx, n)
            if sub is not None:
                declared(sub, click.Context(sub, parent=ctx, info_name=n), out)
    return out

root = click.Context(cli, info_name="accessionflow")
envvars = declared(cli, root, set())
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    want, path, rest = line.split("|", 2)
    if want == "env":
        if rest.startswith("XINGEST_"):
            print("BAD\t%s\tsets %s, which this image never reads (it reads ACFLOW_*)" % (path, rest))
        elif rest not in envvars:
            print("BAD\t%s\tsets %s, which this image does not declare" % (path, rest))
        else:
            print("OK\t%s\tsets %s (declared)" % (path, rest))
        continue
    names, cmd, ctx = path.split(), cli, root
    for i, n in enumerate(names):
        sub = cmd.get_command(ctx, n) if isinstance(cmd, click.Group) else None
        if sub is None:
            cmd = None
            break
        if i < len(names) - 1:
            ctx = click.Context(sub, parent=ctx, info_name=n)
        cmd = sub
    if cmd is None:
        print("MISSING\t%s\tthe image has no command %r" % (path, path))
        continue
    try:
        with cmd.make_context(names[-1], rest.split(), parent=ctx):
            pass
        got, why = "accept", ""
    except click.exceptions.Exit:
        got, why = "accept", ""
    except Exception as e:
        got, why = "reject", str(e).splitlines()[0]
    if got == want:
        print("OK\t%s\t%s" % (path, "rejected as expected" if want == "reject" else ""))
    elif want == "accept":
        print("BAD\t%s\t%s" % (path, why))
    else:
        print("BAD\t%s\tACCEPTED an argv known to be broken — this probe is no longer discriminating" % path)
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
    BAD)     ci_fail "$name: $IMAGE disagrees with what this chart renders${why:+ — $why}" ;;
    MISSING) ci_fail "$why" ;;
    *)       ci_fail "unparseable probe output: $verdict $name $why" ;;
  esac
done <<<"$OUT"

ci_summary "cli-contract ($IMAGE)"
