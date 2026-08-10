#!/usr/bin/env bash
# =============================================================================
# CI stage: no two objects may share (kind, namespace, name).
# =============================================================================
# Helm renders a single stream, and `kubectl apply` takes the LAST definition
# of a duplicated object silently. So two templates that both produce
# Role/foo in namespace bar do not error — one just quietly wins, and whatever
# the loser granted is missing at runtime.
#
# The realistic way to introduce this is a per-edge loop whose object name does
# not include the edge, which is easy to write and invisible in review: with
# one edge in the values file everything looks correct.
#
# (Same name in DIFFERENT namespaces is fine and is used deliberately — each
# edge's cert-sync Role lives in that edge's own namespace.)
# =============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "$HERE/lib.sh"

ci_heading "duplicate object names"

for f in "$CI_RENDER_DIR"/*.yaml; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .yaml)
    out=$(python3 - "$f" <<'PYEOF'
import sys, yaml, collections
seen = collections.defaultdict(int)
try:
    docs = list(yaml.safe_load_all(open(sys.argv[1])))
except Exception as e:
    print("PARSE %s" % e); sys.exit(0)
for d in docs:
    if not isinstance(d, dict) or "kind" not in d:
        continue
    m = d.get("metadata") or {}
    seen[(d["kind"], m.get("namespace", "<cluster-scoped>"), m.get("name"))] += 1
for (kind, ns, nm), n in sorted(seen.items()):
    if n > 1:
        print("%s %s/%s x%d" % (kind, ns, nm, n))
PYEOF
)
    if [ -n "$out" ]; then
        while IFS= read -r line; do
            ci_fail "$name duplicate object: $line — the last one silently wins on apply"
        done <<< "$out"
    else
        ci_pass "$name no duplicate (kind, namespace, name)"
    fi
done

ci_summary "duplicate-names"
