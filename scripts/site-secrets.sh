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
    # THE ROLE IS REQUIRED, and deliberately not guessed.
    #
    # A deployment has one MANAGEMENT site and one directory per EDGE, and the
    # two need entirely different files. The management side configures
    # SeaweedFS, the observability stack, the hosted control planes and the
    # fleet-wide data policy, and holds eight Secrets. An edge configures
    # Orthanc, the de-identification profile and its AE-title-to-XNAT-project
    # map, and holds two.
    #
    # Defaulting to either one would scaffold a file that renders — Helm ignores
    # values a chart does not declare — and then fails much later, in the least
    # obvious way: an edge scaffolded from the management template would carry a
    # dataPolicy block that silently overrides the fleet's, and a management
    # site scaffolded from the edge template would be missing every hostname the
    # edges derive their endpoints from.
    SITE="${2:-}"; ROLE="${3:-}"
    if [ -z "$SITE" ] || [ -z "$ROLE" ]; then
        die "usage: $0 new <name> <mgmt|edge>

  mgmt   the management node — SeaweedFS, observability, control planes,
         the XNAT uploader, the reclaimer, and the fleet-wide data policy.
         ONE per deployment.
  edge   one facility node — Orthanc, de-identification, the AE-title to
         XNAT-project map, the S3 uploader. ONE per site.

  A new edge also needs an entry under \`edges:\` in the management site's
  values.yaml. That entry is the whole registration: the S3 identity, the
  hosted control plane and the Loki push client certificate are all derived
  from it. There is no per-edge credential to mint by hand."
    fi
    case "$ROLE" in
        mgmt|edge) ;;
        *) die "unknown role '${ROLE}' — expected 'mgmt' or 'edge'" ;;
    esac

    TEMPLATE="${REPO_DIR}/sites/example-${ROLE}"
    [ -d "$TEMPLATE" ] || die "template ${TEMPLATE} not found"

    DIR="${REPO_DIR}/sites/${SITE}"
    [ -d "$DIR" ] && die "sites/${SITE} already exists"
    mkdir -p "$DIR"
    cp "${TEMPLATE}/secrets.example.yaml" "${DIR}/secrets.enc.yaml"
    cp "${TEMPLATE}/values.yaml" "${DIR}/values.yaml"
    info "created sites/${SITE}/ from sites/example-${ROLE}/"
    echo "  1. edit sites/${SITE}/values.yaml       (non-secret site config)"
    echo "  2. edit sites/${SITE}/secrets.enc.yaml  (still PLAINTEXT at this point)"
    echo "  3. $0 encrypt ${SITE}                   <-- do not commit before this"
    if [ "$ROLE" = "edge" ]; then
        echo "  4. add ${SITE} to 'edges:' in the management site's values.yaml"
        echo "     (that alone provisions its Loki push client certificate)"
        echo "  5. add a ${SITE}-s3 Secret to the management site's secrets, and"
        echo "     put the SAME key pair nowhere else — cert-sync delivers it"
    fi
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
    # The namespaces are readable WITHOUT decrypting: .sops.yaml encrypts only
    # `data` and `stringData`, so metadata stays in clear precisely so tooling
    # and code review can see structure without seeing content.
    NAMESPACES=$(grep -E '^[[:space:]]+namespace:' "$F" | awk '{print $2}' | tr -d "\"'" | sort -u)
    echo "  namespaces: $(echo "$NAMESPACES" | tr '\n' ' ')"
    # SITE_SECRETS_ASSUME_YES exists so callers do not have to pipe into the
    # prompt. `yes y | site-secrets.sh apply` looks equivalent and is not: when
    # this script exits, `yes` is killed by SIGPIPE (141), and under the callers'
    # `set -o pipefail` that becomes the pipeline's status and aborts THEM —
    # after the secrets were applied, so the run looks like it simply stopped
    # part-way with a success exit code. install.sh died exactly this way.
    if [ "${SITE_SECRETS_ASSUME_YES:-0}" = "1" ]; then
        r=y
        echo "  (non-interactive: SITE_SECRETS_ASSUME_YES=1)"
    else
        read -rp "  Create these Secrets in that cluster? [y/N]: " r
    fi
    [[ "$r" =~ ^[Yy]$ ]] || die "aborted"

    # Namespaces first. The charts deliberately do not create the namespaces
    # that hold operator-supplied credentials, so that Secrets can always exist
    # BEFORE the workloads that mount them — a pod that starts without its
    # Secret sits in CreateContainerConfigError, and a namespace pre-created by
    # hand would instead abort `helm install` with an ownership error. Creating
    # them here is what makes "secrets first, then helm" work on a bare cluster.
    for ns in $NAMESPACES; do
        [ -n "$ns" ] || continue
        if kubectl get namespace "$ns" >/dev/null 2>&1; then
            info "namespace $ns already exists"
        else
            kubectl create namespace "$ns" >/dev/null && info "created namespace $ns"
        fi
    done

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
