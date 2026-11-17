#!/usr/bin/env bash
# =============================================================================
# tests/site-secrets/run-tests.sh: `scripts/site-secrets.sh add-edge` on a copy
# of the shipped templates, with a stub sops. Each case asserts the exit status
# AND the per-edge Secrets that the management file holds afterwards. A run
# that leaves the template's placeholders, makes two Secrets of one name, or
# changes a Secret of another owner fails here.
#
# install.sh is NOT run here. It refuses a file that has a placeholder, and
# this test asserts that no placeholder stays.
#
# It also checks the shipped .sops.yaml: each rule has the placeholder
# recipient, and no rule has a real key (shipped_recipients below).
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/site-secrets-tests"
_R=$'\033[31m'; _G=$'\033[32m'; _B=$'\033[1m'; _O=$'\033[0m'
PASS=0; FAIL=0; FAILED=()
TEMPLATE="$REPO/sites/example-mgmt/secrets.example.yaml"
HEX_PAIR='^[0-9a-f]{20} [0-9a-f]{40}$'

# --- the sandbox ---------------------------------------------------------------
# A repo that has only what add-edge reads. It has no sites/edge-dev/, so a case
# can also use the template's own edge name.
sandbox() {
    C="$WORK/$1"; rm -rf "$C"; mkdir -p "$C/scripts" "$C/sites" "$C/tmp"
    cp "$REPO/scripts/site-secrets.sh" "$C/scripts/"
    cp "$REPO/.sops.yaml" "$C/"
    cp -r "$REPO/sites/example-mgmt" "$REPO/sites/example-edge" "$C/sites/"
    F="$C/sites/my-site/secrets.enc.yaml"
    ss new my-site mgmt >/dev/null 2>&1 || WHY+=" [new my-site mgmt failed]"
}
ss() { (cd "$C" && env PATH="$HERE:$PATH" TMPDIR="$C/tmp" bash scripts/site-secrets.sh "$@"); }
add_edge() { OUT=$(ss add-edge my-site "$1" 2>&1); RC=$?; }
seal()     { "$HERE/sops" -e "$F" > "$F.sealed" && mv "$F.sealed" "$F"; }   # the operator ran `encrypt` first

# --- what the management file holds ---------------------------------------------
plain()    { if grep -q '^sops:' "$F"; then "$HERE/sops" -d "$F"; else cat "$F"; fi; }
norm()     { sed -E 's/^[[:space:]]+/ /'; }       # sops prints four spaces where the template has two
names()    { plain | grep -E '^[[:space:]]+name:[[:space:]]*[^[:space:]]+-s3[[:space:]]*$' | awk '{print $2}' | sort | tr '\n' ' ' | sed 's/ $//'; }
unfilled() { plain | grep -cE '^[[:space:]]+[a-z-]+:[[:space:]]*REPLACE_EDGE_S3_'; }
# Template lines that the file does not have any more. 0 = nothing of the template changed.
changed()  { diff <(norm < "$TEMPLATE") <(plain | norm) | grep -c '^<'; }
keys() {   # <Secret name>: "<access-key> <secret-key>" of that Secret
    plain | awk -v want="$1" '
        /^---/ { name = "" }
        name == "" && /^[[:space:]]+name:/ { name = $2 }
        name == want && /^[[:space:]]+access-key:/ { a = $2 }
        name == want && /^[[:space:]]+secret-key:/ { s = $2 }
        END { print a, s }'
}

# --- assertions: each one adds its reason to WHY ---------------------------------
want_rc()      { local got=fail; [ "$RC" -eq 0 ] && got=0; [ "$got" = "$1" ] || WHY+=" [exit=$got, want $1]"; }
want_names()   { local got; got=$(names); [ "$got" = "$1" ] || WHY+=" [-s3 Secrets: '$got', want '$1']"; }
want_changed() { local got; got=$(changed); [ "$got" = "$1" ] || WHY+=" [template lines changed: $got, want $1]"; }
want_phrase()  { grep -qF -- "$1" <<<"$OUT" || WHY+=" [output has no '$1']"; }
want_new_keys(){ local got; got=$(keys "$1"); [[ "$got" =~ $HEX_PAIR ]] || WHY+=" [$1 has no generated key pair]"; }
want_keys()    { local got; got=$(keys "$1"); [ "$got" = "$2" ] || WHY+=" [the key pair of $1 changed]"; }
want_site()    { [ -f "$C/sites/$1/values.yaml" ] && [ -f "$C/sites/$1/secrets.enc.yaml" ] || WHY+=" [sites/$1 was not scaffolded]"; }
want_no_site() { [ ! -e "$C/sites/$1" ] || WHY+=" [sites/$1 exists after a refusal]"; }
want_sealed()  { grep -q '^sops:' "$F" || WHY+=" [the file is not encrypted any more]"; grep -q 'REPLACE_EDGE_S3_\|[0-9a-f]\{40\}$' "$F" && WHY+=" [a value is readable in the encrypted file]"; }
want_same()    { cmp -s "$F" "$1" || WHY+=" [a refusal changed the file]"; }
# For every case: no placeholder, no scratch file, and the management values.yaml as the template has it.
always() {
    [ "$(unfilled)" = 0 ] || WHY+=" [$(unfilled) placeholder value(s) stay; install.sh refuses this file]"
    [ -z "$(ls -A "$C/tmp")" ] || WHY+=" [a scratch file stayed in TMPDIR]"
    cmp -s "$C/sites/my-site/values.yaml" "$REPO/sites/example-mgmt/values.yaml" || WHY+=" [add-edge changed the management values.yaml]"
}

run_case() {
    local name="$1"; WHY=""; OUT=""; RC=0
    "case_$name"; always
    if [ -z "$WHY" ]; then
        printf '  %sPASS%s  %-34s %s\n' "$_G" "$_O" "$name" "$(names)"; PASS=$((PASS+1))
    else
        printf '  %sFAIL%s  %-34s%s\n' "$_R" "$_O" "$name" "$WHY"
        printf '%s\n' "$OUT" | grep -E '^\[site-secrets\]|^ERROR' | sed 's/^/          /' | head -4
        FAIL=$((FAIL+1)); FAILED+=("$name")
    fi
}

# --- the first edge --------------------------------------------------------------
# THE REPORTED CASE: the first edge has a name that is not the template's.
case_first_edge_other_name() {
    sandbox "$FUNCNAME"; add_edge my-edge
    want_rc 0; want_names "my-edge-s3"; want_changed 3; want_new_keys my-edge-s3; want_site my-edge
    want_phrase "renamed the template's edge-dev-s3 to my-edge-s3"; want_phrase "(still PLAINTEXT)"
    want_phrase "Change THAT entry into this edge"
}
case_first_edge_template_name() {
    sandbox "$FUNCNAME"; add_edge edge-dev
    want_rc 0; want_names "edge-dev-s3"; want_changed 2; want_new_keys edge-dev-s3; want_site edge-dev
    want_phrase "filled the template's edge-dev-s3 key pair"; want_phrase "Change THAT entry into this edge"
}
# The operator typed a key pair into the template's Secret. It has an owner: leave it.
case_hand_filled_template_stays() {
    sandbox "$FUNCNAME"
    sed -i 's|REPLACE_EDGE_S3_ACCESS_KEY|typedaccess|; s|REPLACE_EDGE_S3_SECRET_KEY|typedsecret|' "$F"
    add_edge my-edge
    want_rc 0; want_names "edge-dev-s3 my-edge-s3"; want_changed 2; want_keys edge-dev-s3 "typedaccess typedsecret"
    want_new_keys my-edge-s3; want_phrase "appended my-edge-s3"; want_phrase "Paste this into"
}

# --- more edges ------------------------------------------------------------------
case_second_edge_appends() {
    sandbox "$FUNCNAME"; add_edge my-edge; local first; first=$(keys my-edge-s3)
    add_edge edge-b
    want_rc 0; want_names "edge-b-s3 my-edge-s3"; want_changed 3; want_keys my-edge-s3 "$first"
    want_new_keys edge-b-s3; want_site edge-b; want_phrase "appended edge-b-s3"; want_phrase "Paste this into"
}
# The same name again is a new S3 identity for an edge that has data. Refuse.
case_same_edge_again_refused() {
    sandbox "$FUNCNAME"; add_edge my-edge; rm -rf "$C/sites/my-edge"; cp "$F" "$C/before"
    add_edge my-edge
    want_rc fail; want_phrase "already defines my-edge-s3 with a real key pair"; want_same "$C/before"; want_no_site my-edge
}

# --- the same cases on an ENCRYPTED file -----------------------------------------
# docs/TOUR.md encrypts the management file before it adds an edge.
case_sealed_first_edge_other_name() {
    sandbox "$FUNCNAME"; seal; add_edge my-edge
    want_rc 0; want_names "my-edge-s3"; want_changed 3; want_new_keys my-edge-s3; want_site my-edge; want_sealed
    want_phrase "renamed the template's edge-dev-s3 to my-edge-s3"; want_phrase "(re-encrypted)"
}
case_sealed_first_edge_template_name() {
    sandbox "$FUNCNAME"; seal; add_edge edge-dev
    want_rc 0; want_names "edge-dev-s3"; want_changed 2; want_new_keys edge-dev-s3; want_site edge-dev; want_sealed
    want_phrase "filled the template's edge-dev-s3 key pair"
}
case_sealed_second_edge_appends() {
    sandbox "$FUNCNAME"; seal; add_edge my-edge; local first; first=$(keys my-edge-s3)
    add_edge edge-b
    want_rc 0; want_names "edge-b-s3 my-edge-s3"; want_changed 3; want_keys my-edge-s3 "$first"
    want_new_keys edge-b-s3; want_sealed; want_phrase "appended edge-b-s3"; want_phrase "(re-encrypted)"
}
case_sealed_same_edge_again_refused() {
    sandbox "$FUNCNAME"; seal; add_edge my-edge; rm -rf "$C/sites/my-edge"; cp "$F" "$C/before"
    add_edge my-edge
    want_rc fail; want_phrase "already defines my-edge-s3 with a real key pair"; want_same "$C/before"; want_no_site my-edge
}

# --- the shipped .sops.yaml: the placeholder, never a real key ----------------------
# CAUTION: a real key in the shared repository goes into every copy of it. Each
# site that is set up from a copy is then encrypted to that key too, and the
# holder of that key can read the secrets of each such site. The repository
# shipped a real key from 2026-08-06 to 2026-11-17.
# The first add-recipient of an operator puts their key in place of the
# placeholder, in their own copy. encrypt refuses while the placeholder is there.
shipped_recipients() {
    local cfg="$REPO/.sops.yaml" real holders rules why=""
    real=$(grep -vE '^[[:space:]]*#' "$cfg" | grep -cE 'age1[a-z0-9]{20,}' || true)
    holders=$(grep -vE '^[[:space:]]*#' "$cfg" | grep -c 'REPLACE_WITH_TEAM_AGE_PUBLIC_KEY' || true)
    rules=$(grep -cE '^[[:space:]]*-[[:space:]]*path_regex:' "$cfg" || true)
    [ "$real" -eq 0 ] || why+=" [.sops.yaml lists $real real age key(s); ship REPLACE_WITH_TEAM_AGE_PUBLIC_KEY]"
    [ "$rules" -gt 0 ] && [ "$holders" -eq "$rules" ] || why+=" [$rules rule(s), $holders placeholder recipient(s); each rule needs one]"
    if [ -z "$why" ]; then
        printf '  %sPASS%s  %-34s %s\n' "$_G" "$_O" shipped_recipients "placeholder in $rules rule(s), no real key"; PASS=$((PASS+1))
    else
        printf '  %sFAIL%s  %-34s%s\n' "$_R" "$_O" shipped_recipients "$why"; FAIL=$((FAIL+1)); FAILED+=(shipped_recipients)
    fi
}
printf '\n%s== site-secrets: the shipped .sops.yaml ==%s\n' "$_B" "$_O"
shipped_recipients

printf '\n%s== site-secrets add-edge: the first edge ==%s\n' "$_B" "$_O"
run_case first_edge_other_name
run_case first_edge_template_name
run_case hand_filled_template_stays
printf '\n%s== site-secrets add-edge: more edges ==%s\n' "$_B" "$_O"
run_case second_edge_appends
run_case same_edge_again_refused
printf '\n%s== site-secrets add-edge: an encrypted management file ==%s\n' "$_B" "$_O"
run_case sealed_first_edge_other_name
run_case sealed_first_edge_template_name
run_case sealed_second_edge_appends
run_case sealed_same_edge_again_refused

printf '\n%ssite-secrets: %d passed, %d failed%s\n' "$_B" "$PASS" "$FAIL" "$_O"
for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
[ "$FAIL" -eq 0 ]
