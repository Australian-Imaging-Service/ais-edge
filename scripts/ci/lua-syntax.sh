#!/usr/bin/env bash
# =============================================================================
# lua -p over every Lua script in charts/*/files/
# =============================================================================
# THE SAME ARGUMENT AS shell-syntax.sh, ON THE FILE WITH THE MOST AT STAKE.
# deidentify-and-forward.lua is loaded into a ConfigMap and only ever executes
# inside Orthanc, so a syntax error does not surface as a failed command. It
# surfaces on a node nobody is watching, some time after the install reported
# success, on the one component whose failure is simultaneously a PHI exposure
# and an archive loss: that script de-identifies every instance, writes the
# archive of record, and quarantines unmapped AE titles.
#
# This was added after a restructure of that file silently dropped an `end`.
# Nothing in CI noticed, because nothing in CI had ever read it.
#
# `luac -p` parses without executing, exactly like `bash -n`. It catches
# unbalanced blocks, unclosed strings and broken if/end. It does NOT catch wrong
# logic, a nil dereference, or a renamed routing.json field.
#
# Files are discovered, never listed: a list goes stale, and a new script
# silently outside CI is the failure mode this is meant to prevent.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

mapfile -t files < <(find charts -path '*/files/*' -name '*.lua' | sort)
if [ ${#files[@]} -eq 0 ]; then
    echo "lua-syntax: no .lua files found under charts/*/files/ — did they move?" >&2
    exit 1
fi

# Prefer a local interpreter; fall back to a container, since the check must not
# be skipped just because the runner is thin. A skipped syntax gate is worse
# than no gate, because it reports success.
if command -v luac >/dev/null 2>&1;   then RUN=(luac -p)
elif command -v luac5.4 >/dev/null 2>&1; then RUN=(luac5.4 -p)
elif command -v lua >/dev/null 2>&1;  then RUN=(lua -e 'assert(loadfile(arg[1]))')
elif command -v docker >/dev/null 2>&1; then
    RUN=(docker run --rm -v "$PWD:/w:ro" -w /w nickblah/lua:5.4-alpine luac -p)
else
    echo "lua-syntax: no lua interpreter and no docker; cannot check ${#files[@]} file(s)" >&2
    exit 1
fi

rc=0
for f in "${files[@]}"; do
    if "${RUN[@]}" "$f"; then
        echo "  ok    $f"
    else
        echo "  FAIL  $f" >&2
        rc=1
    fi
done
exit $rc
