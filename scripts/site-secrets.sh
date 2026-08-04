#!/usr/bin/env bash
# =============================================================================
# Site secret management with SOPS + age.
# =============================================================================
#   site-secrets.sh init-key                 create this operator's age key
#   site-secrets.sh add-recipient <agekey>   add a public key to .sops.yaml
#   site-secrets.sh new <site>               scaffold sites/<site>/
#   site-secrets.sh encrypt <site>           encrypt sites/<site>/secrets.enc.yaml
#   site-secrets.sh edit <site>              decrypt to $EDITOR, re-encrypt on save
#   site-secrets.sh view <site>              print decrypted (careful: terminal)
#   site-secrets.sh apply <site>             decrypt straight into the cluster
#   site-secrets.sh check                    verify no plaintext secret is staged
#
# The charts never contain credentials — they reference Secrets by name. So
# `apply` is the whole integration: create the Secrets, then `helm upgrade`.
# No helm-secrets plugin, no decrypt-to-tempfile, no plaintext on disk.
# =============================================================================
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOPS_CONFIG="${REPO_DIR}/.sops.yaml"
KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[site-secrets] $*"; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required. Install with: $2"; }
need sops "https://github.com/getsops/sops/releases  (or apt install ./sops_*.deb)"
need age  "apt install age"

secrets_file() { echo "${REPO_DIR}/sites/$1/secrets.enc.yaml"; }

require_site() {
    [ -n "${1:-}" ] || die "usage: $0 $2 <site>"
    [ -d "${REPO_DIR}/sites/$1" ] || die "no such site: sites/$1 (create it with: $0 new $1)"
}

case "${1:-}" in

init-key)
    if [ -f "$KEY_FILE" ]; then
        info "key already exists at $KEY_FILE"
        echo
        echo "  Your PUBLIC key (safe to share — this is what others add as a recipient):"
        grep -oE 'age1[a-z0-9]+' "$KEY_FILE" | head -1 | sed 's/^/    /'
        exit 0
    fi
    mkdir -p "$(dirname "$KEY_FILE")"
    age-keygen -o "$KEY_FILE" 2>/dev/null
    chmod 600 "$KEY_FILE"
    info "created $KEY_FILE (mode 600)"
    echo
    echo "  PUBLIC key — share this, add it as a recipient:"
    grep -oE 'age1[a-z0-9]+' "$KEY_FILE" | head -1 | sed 's/^/    /'
    echo
    echo "  BACK UP $KEY_FILE NOW, to a password manager."
    echo "  It is not recoverable. Losing every recipient key for a file means"
    echo "  that file is gone — SOPS has no escrow and no reset."
    ;;

add-recipient)
    PUB="${2:-}"
    [ -n "$PUB" ] || die "usage: $0 add-recipient age1..."
    [[ "$PUB" =~ ^age1[a-z0-9]+$ ]] || die "that does not look like an age public key"
    grep -q "$PUB" "$SOPS_CONFIG" && { info "already a recipient"; exit 0; }
    if grep -q REPLACE_WITH_TEAM_AGE_PUBLIC_KEY "$SOPS_CONFIG"; then
        sed -i "s|REPLACE_WITH_TEAM_AGE_PUBLIC_KEY|${PUB}|g" "$SOPS_CONFIG"
        info "set $PUB as the team recipient in .sops.yaml"
    else
        # Append to every existing age: line as a comma-separated recipient.
        sed -i "s|^\(\s*\)\(age1[a-z0-9,]*\)$|\1\2,${PUB}|" "$SOPS_CONFIG"
        info "added $PUB as an additional recipient"
    fi
    echo
    echo "  Existing encrypted files are NOT re-encrypted automatically — the new"
    echo "  key cannot read them yet. Rotate each one with:"
    echo "    sops updatekeys sites/<site>/secrets.enc.yaml"
    ;;

new)
    SITE="${2:-}"; [ -n "$SITE" ] || die "usage: $0 new <site>"
    DIR="${REPO_DIR}/sites/${SITE}"
    [ -d "$DIR" ] && die "sites/${SITE} already exists"
    mkdir -p "$DIR"
    cp "${REPO_DIR}/sites/example-site/secrets.example.yaml" "${DIR}/secrets.enc.yaml"
    [ -f "${REPO_DIR}/sites/example-site/values.yaml" ] && \
        cp "${REPO_DIR}/sites/example-site/values.yaml" "${DIR}/values.yaml"
    info "created sites/${SITE}/"
    echo "  1. edit sites/${SITE}/values.yaml       (non-secret site config)"
    echo "  2. edit sites/${SITE}/secrets.enc.yaml  (still PLAINTEXT at this point)"
    echo "  3. $0 encrypt ${SITE}                   <-- do not commit before this"
    ;;

encrypt)
    require_site "${2:-}" encrypt
    F=$(secrets_file "$2")
    [ -f "$F" ] || die "$F not found"
    if grep -q '^sops:' "$F" 2>/dev/null; then
        info "already encrypted — use '$0 edit $2' to change it"
        exit 0
    fi
    grep -q 'REPLACE_' "$F" && {
        echo "WARNING: $F still contains REPLACE_ placeholders." >&2
        read -rp "  Encrypt anyway? [y/N]: " r
        [[ "$r" =~ ^[Yy]$ ]] || die "aborted"
    }
    grep -q REPLACE_WITH_TEAM_AGE_PUBLIC_KEY "$SOPS_CONFIG" && \
        die ".sops.yaml still has the placeholder recipient. Run: $0 add-recipient \$(your age1... key)
       Encrypting to a placeholder produces a file NOBODY can decrypt."
    sops --config "$SOPS_CONFIG" -e -i "$F"
    info "encrypted $F — safe to commit"
    ;;

edit)
    require_site "${2:-}" edit
    exec sops --config "$SOPS_CONFIG" "$(secrets_file "$2")"
    ;;

view)
    require_site "${2:-}" view
    sops --config "$SOPS_CONFIG" -d "$(secrets_file "$2")"
    ;;

apply)
    require_site "${2:-}" apply
    F=$(secrets_file "$2")
    grep -q '^sops:' "$F" || die "$F is not encrypted. Run: $0 encrypt $2"
    CTX=$(kubectl config current-context 2>/dev/null) || die "kubectl has no current context"
    echo "  context : $CTX"
    echo "  site    : $2"
    read -rp "  Create these Secrets in that cluster? [y/N]: " r
    [[ "$r" =~ ^[Yy]$ ]] || die "aborted"
    # Straight into a pipe. Plaintext never touches the disk.
    sops --config "$SOPS_CONFIG" -d "$F" | kubectl apply -f -
    info "secrets applied. Now: helm upgrade --install ... -f sites/$2/values.yaml"
    ;;

check)
    # Belt and braces for the one mistake that matters: committing plaintext.
    RC=0
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        case "$f" in
            *.example.yaml) continue ;;
        esac
        if ! grep -q '^sops:' "${REPO_DIR}/${f}" 2>/dev/null; then
            echo "UNENCRYPTED: $f" >&2; RC=1
        fi
    done < <(cd "$REPO_DIR" && git ls-files 'sites/*/secrets*.yaml' 2>/dev/null)
    [ "$RC" -eq 0 ] && info "all committed site secrets are encrypted" || \
        echo "Run: $0 encrypt <site>" >&2
    exit $RC
    ;;

*)
    sed -n '2,20p' "$0" | sed 's/^# \?//'
    exit 1
    ;;
esac
