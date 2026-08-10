#!/usr/bin/env bash
# =============================================================================
# CI stage: every committed site secrets file is actually encrypted.
# =============================================================================
# The whole secret model of this repo is "commit them, encrypted": secrets live
# in git as sites/<site>/secrets.enc.yaml, SOPS-encrypted, so a site's
# configuration is reviewable and reproducible. That model has exactly one
# catastrophic failure — committing one before running `encrypt`.
#
# The file is called secrets.enc.yaml FROM THE MOMENT IT IS CREATED, which is a
# promise it has not kept yet: `site-secrets.sh new` copies a PLAINTEXT template
# to that name, and it stays plaintext until someone runs `encrypt`. So the
# filename cannot be trusted, and .gitignore deliberately does NOT ignore it —
# the encrypted form is meant to be committed.
#
# `scripts/site-secrets.sh check` has always been able to detect this. NOTHING
# EVER RAN IT. Before this stage existed, the string "site-secrets" appeared in
# the Makefile, the CI stages and the GitHub workflow exactly zero times outside
# comments — on both tiers. The one check standing between an operator and a
# committed XNAT password was manual, and manual means "run after you already
# committed", if at all.
#
# That is worse on tier-1 than tier-2. A tier-2 edge holds no XNAT credential at
# all; tier-1's single secrets file holds the XNAT account AND the de-identifi-
# cation salt, and leaking the salt is not recoverable by rotation — rotating it
# re-pseudonymises every patient and breaks linkage to everything already in
# XNAT.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "$HERE/lib.sh"
REPO="$(cd "$HERE/../.." && pwd)"

ci_heading "site secrets are encrypted"

# --- 1. every TRACKED secrets file must carry a sops block -------------------
# Tracked, not on-disk: an operator's un-encrypted working copy is their own
# business until they try to commit it. This is the thing git would publish.
tracked=$(cd "$REPO" && git ls-files 'sites/*/secrets.enc.yaml' 2>/dev/null)
if [ -z "$tracked" ]; then
    ci_skip "no committed sites/*/secrets.enc.yaml to check"
else
    bad=""
    n=0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        n=$((n + 1))
        # Read the COMMITTED blob, not the working tree. A file encrypted
        # locally but committed earlier in plaintext is still published.
        if ! (cd "$REPO" && git show "HEAD:$f" 2>/dev/null | grep -q '^sops:'); then
            bad="${bad}${f} "
        fi
    done <<< "$tracked"

    if [ -n "$bad" ]; then
        for f in $bad; do
            ci_fail "$f is committed WITHOUT encryption — run: scripts/site-secrets.sh encrypt $(basename "$(dirname "$f")")"
        done
    else
        ci_pass "all $n committed site secrets file(s) carry a sops block"
    fi
fi

# --- 2. the recipient must be real -------------------------------------------
# A file encrypted to the shipped placeholder recipient is unreadable by
# everyone, including the person who encrypted it, and the failure only shows up
# when somebody needs the secret back.
if grep -q 'REPLACE_WITH_TEAM_AGE_PUBLIC_KEY' "$REPO/.sops.yaml" 2>/dev/null; then
    ci_fail ".sops.yaml still lists the placeholder recipient — encrypting to it produces a file NOBODY can decrypt"
elif grep -qE '^\s*age1[a-z0-9]{20,}' "$REPO/.sops.yaml" 2>/dev/null; then
    ci_pass ".sops.yaml lists $(grep -cE '^\s*age1[a-z0-9]{20,}' "$REPO/.sops.yaml") real age recipient(s)"
else
    ci_fail ".sops.yaml lists no age recipient at all"
fi

# --- 3. no plaintext working form may be tracked ------------------------------
# .gitignore covers these, but .gitignore only protects files that were never
# added — `git add -f`, or a rule added after the fact, both slip through.
leaked=$(cd "$REPO" && git ls-files 'sites/*/secrets.yaml' 'sites/*/secrets.plain.yaml' 'sites/*/*.dec.yaml' 2>/dev/null)
if [ -n "$leaked" ]; then
    for f in $leaked; do ci_fail "plaintext working form is TRACKED: $f"; done
else
    ci_pass "no plaintext working form (secrets.yaml / *.dec.yaml) is tracked"
fi

ci_summary "secrets-encrypted"
