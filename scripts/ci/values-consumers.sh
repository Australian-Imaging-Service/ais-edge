#!/usr/bin/env bash
# =============================================================================
# CI stage: a values key that declares a behaviour must have something reading it
# =============================================================================
# HELM NEVER COMPLAINS ABOUT A VALUE NOBODY READS. There is no "unused value"
# error, so a key that does nothing renders exactly like a key that works: green
# install, no warning, no runtime error. The operator writes a policy, the chart
# ignores it, and the only symptom is that the thing they asked for never
# happens.
#
# That is not hypothetical here. An audit of `dataPolicy` found 14 of its 26
# leaf keys had no reader at all, including:
#
#   originals.facilityBackup.enabled   a DUPLICATE of storage.facilityBackup
#                                      .enabled. Setting the dataPolicy one to
#                                      false does not disable the backup.
#   originals.quarantine.subPath       never read; __unmapped_aet__ is hardcoded
#                                      in files/deidentify-and-forward.lua, so
#                                      changing it moves nothing and would point
#                                      the quarantine alert at the wrong path.
#   derived.orthancStorage.reclaim     declares that Orthanc storage is reclaimed
#                                      after grouping. Nothing reclaims it.
#
# This stage makes that class of defect a build failure instead of a discovery.
#
# WHY A BASELINE RATHER THAN A CLEAN FAIL. Those 14 keys are real debt with a
# decision attached to each (wire it / delete it / constrain the schema), and
# those decisions are the operator's, not CI's. Failing the build today would
# only mean disabling the stage. So the known-dead set is listed explicitly
# below: existing debt stays visible and countable, and NEW debt is blocked.
#
# THE BASELINE CANNOT ROT: a key listed here that GAINS a reader is also a
# failure, with instructions to delete the line. Otherwise the list silently
# becomes a permanent exemption for keys that were fixed years ago.
#
#   scripts/ci/values-consumers.sh
# =============================================================================
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "$HERE/lib.sh"

ci_heading "values keys with no consumer"

python3 - "$REPO_ROOT" <<'PYEOF'
import sys, os, re, subprocess, yaml

repo = sys.argv[1]

# Prefixes audited. Deliberately NOT every value in the file: a key like
# `image.tag` is consumed by being interpolated in a dozen ways, and a
# whole-file rule would be all false positives. These are the blocks that
# express OPERATOR POLICY, where a silently-ignored key is the failure.
AUDITED = ("dataPolicy",)

# Keys the engine is GIVEN but does not yet ACT on. They are rendered into
# stages.tsv, so they have a reader and the check below is satisfied — but the
# engine is report-only, so nothing expires or reclaims because of them yet.
#
# Tracked and printed separately on every run, because "something reads it" and
# "it controls the deployment" are different claims. Quietly conflating the two
# is how this block came to have 14 dead keys while every install printed them
# as settled policy. Each line leaves when the engine enforces it.
DECLARED_NOT_ENFORCED = {
    # fileDrop is the last one. Its reclaim is blocked by a render guard because
    # that path never writes an original to the facility backup, so the drop
    # directory is the only copy. Deferred until the Prefect ingest path lands,
    # which is when it becomes worth building the archive-write.
    "dataPolicy.originals.fileDrop.minAge",
}

# Keys with NO reader at all. Real debt, not an exemption on principle.
# Shrinking this list is the point; adding to it needs a reason in the commit
# message.
KNOWN_DEAD = {
    # Real config lives in the subchart values behind "MUST MATCH" comments.
    # Helm cannot template a subchart's values, so making these live needs an
    # equality check rather than a reference.
    "dataPolicy.telemetry.podLogFiles.retain",
}

def leaves(d, pre=""):
    out = []
    for k, v in (d or {}).items():
        p = f"{pre}.{k}" if pre else k
        if isinstance(v, dict):
            out += leaves(v, p)
        else:
            out.append(p)
    return out

keys = {}
for chart in ("mgmt", "edge"):
    path = os.path.join(repo, "charts", chart, "values.yaml")
    if not os.path.exists(path):
        continue
    vals = yaml.safe_load(open(path)) or {}
    for top in AUDITED:
        for k in leaves(vals.get(top), top):
            keys.setdefault(k, []).append(chart)

def _grep(key):
    # Only a real Helm reference counts: (.|$x.)Values.<path> followed by a
    # non-identifier char, so `.minAge` does not match `.minAgeSeconds`.
    pat = r"Values\." + re.escape(key) + r"($|[^A-Za-z0-9_])"
    r = subprocess.run(
        ["grep", "-rE", "-l", pat, os.path.join(repo, "charts")],
        capture_output=True, text=True)
    return [f for f in r.stdout.split() if not f.endswith("values.yaml")]

# PRINTING A VALUE IS NOT IMPLEMENTING IT, and conflating the two is how this
# check would have certified the exact bug it exists to catch. NOTES.txt is the
# message Helm prints after every install; it renders the whole dataPolicy block
# as a statement of what the deployment will do. Four keys with no implementation
# anywhere are "read" only there — so the install has been telling operators that
# `orthanc onGrouped (min age 7d)` is in force while nothing reclaims Orthanc
# storage at all. A display template counts as advertising, never as a consumer.
DISPLAY_ONLY = ("NOTES.txt",)

# Blocks handed to Kubernetes WHOLE, via toYaml. Their leaves are consumed by
# the parent reference and never appear individually, so they are audited at the
# block level instead of leaf by leaf.
#
# An earlier version walked from each leaf up to the block root and accepted any
# referenced ancestor. That was too loose: a validation guard doing
# `hasKey .Values.dataPolicy.telemetry "loki"` created a reference to
# `dataPolicy.telemetry`, which then made podLogFiles.retain — a key nothing
# implements — look alive. Checking whether a key is USED must not be satisfied
# by a check that the key is ABSENT.
OPAQUE_BLOCKS = (".image.", ".resources.", ".podSecurityContext.")

def has_reader(key):
    return [f for f in _grep(key)
            if os.path.basename(f) not in DISPLAY_ONLY]

def is_advertised(key):
    return [f for f in _grep(key)
            if os.path.basename(f) in DISPLAY_ONLY]

new_dead, revived, ok = [], [], 0
for key in sorted(keys):
    if any(b in key for b in OPAQUE_BLOCKS):
        continue
    readers = has_reader(key)
    if readers:
        ok += 1
        if key in KNOWN_DEAD:
            revived.append((key, readers))
    else:
        if key not in KNOWN_DEAD:
            new_dead.append(key)

for key in new_dead:
    print(f"  FAIL  {key}")
    print("        declares a behaviour and NOTHING reads it. Helm will not")
    print("        warn: it renders green and silently does nothing.")
    print("        Wire it, delete it, or add it to KNOWN_DEAD with a reason.")

for key, readers in revived:
    rels = ", ".join(os.path.relpath(f, repo) for f in readers[:3])
    print(f"  FAIL  {key}")
    print(f"        is in KNOWN_DEAD but now HAS a reader ({rels}).")
    print("        Delete its line from KNOWN_DEAD in scripts/ci/values-consumers.sh")
    print("        so the baseline keeps meaning what it says.")

# Tracked debt with a sharper edge: a key nothing implements, which the install
# nonetheless prints to the operator as settled policy. Reported every run rather
# than buried, because "the notes say it is on" is exactly how an unimplemented
# retention rule gets believed. Not a failure on its own — these are all in
# KNOWN_DEAD and carry the same wire/delete/constrain decision — but it is the
# subset to fix first.
declared = sorted(k for k in DECLARED_NOT_ENFORCED if k in keys)
if declared:
    print()
    print("  DECLARED BUT NOT YET ENFORCED — the engine is given these and does")
    print("  not act on them (report-only). They have a reader, not an effect:")
    for k in declared:
        print(f"    {k}")

advertised_dead = sorted(k for k in KNOWN_DEAD if is_advertised(k))
if advertised_dead:
    print()
    print("  ADVERTISED BUT NOT IMPLEMENTED — printed to the operator by NOTES.txt")
    print("  after every install, while nothing acts on them:")
    for k in advertised_dead:
        print(f"    {k}")

print()
print(f"  {ok} key(s) with a reader, {len(KNOWN_DEAD)} known-dead (tracked debt), "
      f"{len(advertised_dead)} of those advertised in NOTES.txt, "
      f"{len(new_dead)} NEW dead, {len(revived)} revived-but-still-listed.")

sys.exit(1 if (new_dead or revived) else 0)
PYEOF
rc=$?

if [ "$rc" -eq 0 ]; then
    ci_pass "no values key declares a behaviour without a consumer"
else
    ci_fail "values keys with no consumer" "see above"
fi

ci_summary "values-consumers"
