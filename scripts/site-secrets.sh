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
    # WHICH TIER IS THIS CHECKOUT? Same test CI uses: only tier-2 ships a
    # management chart. Branching on it here keeps the usage text describing
    # the roles that actually work in the tree the operator is standing in.
    if [ -d "${REPO_DIR}/charts/mgmt" ]; then
        ROLE_USAGE="usage: $0 new <name> <mgmt|edge>

  mgmt   the management node — SeaweedFS, observability, control planes,
         the XNAT uploader, the reclaimer, and the fleet-wide data policy.
         ONE per deployment.
  edge   one facility node — Orthanc, de-identification, the AE-title to
         XNAT-project map, the S3 uploader. ONE per site.

  A new edge also needs an entry under \`edges:\` in the management site's
  values.yaml. That entry is the whole registration: the S3 identity, the
  hosted control plane and the Loki push client certificate are all derived
  from it. There is no per-edge credential to mint by hand."
        VALID_ROLES="mgmt edge"
    else
        ROLE_USAGE="usage: $0 new <name> single

  single   this machine — Orthanc, de-identification, the AE-title to
           XNAT-project map, and the uploader that PUTs straight to XNAT.
           Tier-1 is one box, so this is the only role and one file is the
           whole configuration.

  'mgmt' and 'edge' are TIER-2 roles and are refused here. sites/example-edge
  is kept for reference only: it sets upload.mode: s3, which needs a SeaweedFS
  and a management-side reclaimer that do not exist on this tier — install.sh
  rejects it. Scaffolding from it would hand you a site that cannot install."
        VALID_ROLES="single"
    fi
    if [ -z "$SITE" ] || [ -z "$ROLE" ]; then
        die "$ROLE_USAGE"
    fi
    # mgmt / edge are the TIER-2 pair: one management site plus one file per
    # edge. `single` is TIER-1 — one machine, so one file is the whole
    # configuration and there is no management site to register it with.
    # Validated against the roles THIS TIER supports, not against the union of
    # both. `new <name> edge` on tier-1 used to succeed and copy a template
    # with upload.mode: s3 — a site that scaffolds cleanly, renders cleanly,
    # and is then rejected by install.sh, which reads as an installer bug.
    case " ${VALID_ROLES} " in
        *" ${ROLE} "*) ;;
        *) die "role '${ROLE}' is not available in this checkout.

${ROLE_USAGE}" ;;
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
        echo
        echo "  Steps 1 and 3-5 in one command, with the S3 key pair GENERATED"
        echo "  rather than typed twice by hand:"
        echo "    $0 add-edge <management-site> ${SITE}"
    fi
    if [ "$ROLE" = "single" ]; then
        echo "  4. ./install.sh ${SITE}"
        echo
        echo "  Two things nothing generates for you, both in the secrets file:"
        echo "    * AIS_DEID_HMAC_SALT — openssl rand -hex 32, then keep it forever."
        echo "      Rotating it re-pseudonymises every patient and silently breaks"
        echo "      linkage to everything already in XNAT."
        echo "    * the XNAT account. Tier-1 uploads to XNAT from this machine, so"
        echo "      scope that account to the projects in this site's aetMap only."
        echo
        echo "  And one in values.yaml: orthanc.deid.policyReviewed must be set to"
        echo "  true, deliberately, once you have read the profile and the AET map."
    fi
    ;;

add-edge)
    # TIER-2 ONLY. Everything below writes into a MANAGEMENT site's values.yaml
    # and secrets — an `edges:` entry, an `<edge>-s3` Secret, a Loki push client
    # certificate. None of those files exist on tier-1, so without this guard
    # the command fails partway through with a path error after having already
    # touched the site directory.
    if [ ! -d "${REPO_DIR}/charts/mgmt" ]; then
        die "add-edge is a tier-2 command and this is a tier-1 checkout.

  It registers an edge with a MANAGEMENT site: an entry under \`edges:\`, an
  S3 key pair, and a Loki push client certificate. Tier-1 is one machine with
  no management plane, so there is nothing to register with.

  You want:  $0 new <name> single"
    fi
    # ONE credential still has to exist twice: this edge's S3 key pair, once
    # as the `<edge>-s3` Secret on the management site (which SeaweedFS scopes
    # to that edge's bucket) and once as `s3-edge-credentials` in the edge's
    # own file (which the edge's uploader authenticates with). Nobody cares
    # what the string is, only that both copies match, so generating it once
    # here and writing it to both places removes the one place a human could
    # still introduce a mismatch by hand.
    #
    # Everything else an edge needs -- the hosted control plane, the S3
    # bucket, the Loki push client certificate -- is DERIVED from the
    # `edges:` entry in the management values.yaml at render time. There is
    # no second credential to mint for any of that.
    #
    # WHAT THIS DOES NOT TOUCH, ON PURPOSE: the management site's
    # values.yaml. That file is the most heavily hand-annotated file in the
    # repo -- every comment is load-bearing documentation, and a
    # yaml.safe_load + yaml.dump round-trip destroys all of it. A generated
    # values.yaml that renders correctly but has silently lost every caution
    # comment is a worse outcome than asking a human to paste six lines. The
    # exact block to paste is printed at the end instead.
    MGMT="${2:-}"; EDGE="${3:-}"
    if [ -z "$MGMT" ] || [ -z "$EDGE" ]; then
        die "usage: $0 add-edge <management-site> <edge-name>

  e.g.  $0 add-edge stream-2-ab-dev hospital-a

  Scaffolds sites/<edge-name>/ from sites/example-edge, generates this
  edge's S3 key pair, writes it into the edge's own secrets file AND appends
  a matching Secret to the management site's secrets file, then prints the
  'edges:' block to paste into the management site's values.yaml."
    fi
    MGMT_DIR="${REPO_DIR}/sites/${MGMT}"
    MGMT_SECRETS="$(secrets_file "$MGMT")"
    EDGE_DIR="${REPO_DIR}/sites/${EDGE}"
    TEMPLATE="${REPO_DIR}/sites/example-edge"

    [ -d "$MGMT_DIR" ] || die "no such management site: sites/${MGMT} (create it with: $0 new ${MGMT} mgmt)"
    [ -f "$MGMT_SECRETS" ] || die "sites/${MGMT}/secrets.enc.yaml not found"
    [ -d "$EDGE_DIR" ] && die "sites/${EDGE} already exists — add-edge never overwrites a site"
    [ -d "$TEMPLATE" ] || die "template ${TEMPLATE} not found"
    command -v openssl >/dev/null || die "openssl is required to generate the S3 key pair"

    # DOES THIS SECRET ALREADY EXIST? Append-only is safe across DIFFERENT
    # names, but not against the same one twice, and two paths reach it:
    #
    #   1. sites/example-mgmt ships a concrete `edge-dev-s3` block (CI requires
    #      it — scripts/ci/secret-namespaces.sh resolves every secretKeyRef
    #      against that file), and example-mgmt/values.yaml names its first
    #      edge `edge-dev`. So the FIRST edge an operator adds, following the
    #      templates verbatim, collides by default.
    #   2. Re-running add-edge for an existing edge.
    #
    # Appending regardless produced two Secrets of one name in one file. The
    # later one wins on `kubectl apply`, so it usually looked fine — until the
    # order changed and the edge got the literal string REPLACE_EDGE_S3_ACCESS_KEY
    # as its S3 key, which fails as a 403 at upload with nothing naming the cause.
    #
    # metadata.name stays readable even once encrypted (.sops.yaml encrypts only
    # ^(data|stringData)$), so this check needs no decryption.
    if grep -q "^[[:space:]]*name:[[:space:]]*${EDGE}-s3[[:space:]]*$" "$MGMT_SECRETS"; then
        if ! grep -q '^sops:' "$MGMT_SECRETS" && grep -q 'REPLACE_EDGE_S3_ACCESS_KEY' "$MGMT_SECRETS"; then
            # Case 1: the shipped template placeholder. Fill it rather than
            # duplicate it — that is what the operator meant by add-edge.
            REPLACED_PLACEHOLDER=true
        else
            # Case 2: a real key pair. Never silently rotate a live edge's
            # identity; every object it already staged was written with it.
            die "sites/${MGMT}/secrets.enc.yaml already defines ${EDGE}-s3 with a real key pair.
  add-edge would append a SECOND Secret of the same name and rotate this edge's
  S3 identity, breaking its uploads. To rotate deliberately, edit it:
      $0 edit ${MGMT}
  To add a different edge, pick another name."
        fi
    fi

    ACCESS_KEY="$(openssl rand -hex 10)"
    SECRET_KEY="$(openssl rand -hex 20)"

    # Scaffold the edge directory first. If anything below fails, the
    # half-created directory is visible and `sites/${EDGE} already exists`
    # stops a second attempt from silently double-writing — re-run after
    # removing it by hand, the same recovery as a failed `new`.
    #
    # A PLAIN COPY, both files — the edge template has no
    # s3-edge-credentials placeholder to fill in the first place.
    # cert-sync delivers that Secret from the management side's
    # `<edge>-s3` (appended below) the same way it delivers ca-bundle and
    # the Loki client cert; writing it here would only be overwritten on
    # the next sync. See sites/example-edge/secrets.example.yaml.
    mkdir -p "$EDGE_DIR"
    cp "${TEMPLATE}/values.yaml" "${EDGE_DIR}/values.yaml"
    cp "${TEMPLATE}/secrets.example.yaml" "${EDGE_DIR}/secrets.enc.yaml"
    info "created sites/${EDGE}/ from sites/example-edge/"

    # Append-only. Decrypting an ALREADY-encrypted management secrets file to
    # append one document, rather than editing its existing content, is safe
    # for the same reason `new` is safe to run repeatedly for different
    # sites: nothing already there is read, parsed or rewritten, only added
    # to. If the file is still plaintext (a fresh site, not yet encrypted),
    # append directly and skip the decrypt/re-encrypt round trip.
    NEW_DOC="$(cat <<EOF2
---
# This edge's S3 identity, generated by 'site-secrets.sh add-edge'. It is held
# ONLY here, on the management side; cert-sync copies it into the edge cluster
# as s3-edge-credentials, alongside ca-bundle and the Loki client certificate.
# Do NOT also write it into sites/${EDGE}/secrets.enc.yaml — two hand-kept
# copies of one credential is the drift this command exists to remove.
apiVersion: v1
kind: Secret
metadata:
  name: ${EDGE}-s3
  namespace: ais-mgmt
type: Opaque
stringData:
  access-key: ${ACCESS_KEY}
  secret-key: ${SECRET_KEY}
EOF2
)"
    if [ "${REPLACED_PLACEHOLDER:-false}" = true ]; then
        # The template's own block is already in the right place, with the
        # right name and namespace and its explanatory comments — fill its two
        # values rather than appending a second copy of the same Secret. Only
        # reachable while the file is still plaintext (guard above), so there
        # is no decrypt/re-encrypt round trip here.
        sed -i "s|REPLACE_EDGE_S3_ACCESS_KEY|${ACCESS_KEY}|; s|REPLACE_EDGE_S3_SECRET_KEY|${SECRET_KEY}|" \
            "$MGMT_SECRETS"
        info "filled the template's ${EDGE}-s3 key pair in sites/${MGMT}/secrets.enc.yaml (still PLAINTEXT)"
    elif grep -q '^sops:' "$MGMT_SECRETS"; then
        # `sops -e` chooses recipients by matching the FILE PATH against
        # .sops.yaml's path_regex (sites/[^/]+/secrets\.enc\.ya?ml$) — an
        # arbitrary `mktemp` path fails with "no matching creation rules
        # found", not a permissions or content error. The regex is
        # unanchored at the front, so any parent directory works as long as
        # the path ENDS in sites/<name>/secrets.enc.yaml; a scratch
        # directory shaped the same way satisfies it without touching the
        # real file until the encrypted result is ready to swap in.
        TMPDIR="$(mktemp -d)"
        TMP="${TMPDIR}/sites/${MGMT}/secrets.enc.yaml"
        mkdir -p "$(dirname "$TMP")"
        trap 'shred -u "$TMP" 2>/dev/null; rm -rf "$TMPDIR"' EXIT
        sops --config "$SOPS_CONFIG" -d "$MGMT_SECRETS" > "$TMP"
        printf '\n%s\n' "$NEW_DOC" >> "$TMP"
        sops --config "$SOPS_CONFIG" -e "$TMP" > "${MGMT_SECRETS}.new"
        mv "${MGMT_SECRETS}.new" "$MGMT_SECRETS"
        shred -u "$TMP" 2>/dev/null; rm -rf "$TMPDIR"
        trap - EXIT
        info "appended ${EDGE}-s3 to sites/${MGMT}/secrets.enc.yaml (re-encrypted)"
    else
        printf '\n%s\n' "$NEW_DOC" >> "$MGMT_SECRETS"
        info "appended ${EDGE}-s3 to sites/${MGMT}/secrets.enc.yaml (still PLAINTEXT)"
    fi

    cat <<EOF3

  Generated and wired automatically:
    - sites/${MGMT}/secrets.enc.yaml   ${EDGE}-s3 Secret, new S3 key pair
    - cert-sync will deliver it into the edge as s3-edge-credentials once
      step 3 below is in place and install.sh has run — nothing to write
      on the edge side for this credential

  Still needed by hand:

  1. Fill in sites/${EDGE}/values.yaml — the AE-title map, de-identification
     profile and disk paths are facts only you have; nothing generates them.
  2. Fill in sites/${EDGE}/secrets.enc.yaml — orthanc-deid-salt still needs
     'openssl rand -hex 32' (deliberately NOT auto-generated: this salt must
     survive reinstalls, and a command that silently regenerates it on a
     second run would quietly re-pseudonymise every existing patient).
  3. Paste this into sites/${MGMT}/values.yaml, under 'edges:':

       - name: ${EDGE}
         nodeIP: "<this edge's IP>"
         join: ssh                      # ssh | bundle
         sshUser: ubuntu                # join: ssh only — drop both for bundle
         sshKey: ~/.ssh/id_ed25519
         s3SecretRef: ${EDGE}-s3
         exposure: sni

     If this management node cannot reach the edge inbound (whitelisted IPs,
     VPN, GlobalProtect), use 'join: bundle' and omit sshUser/sshKey. The
     installer then writes ${EDGE}-join.sh for you to carry to the site.

  4. $0 encrypt ${EDGE}
     $([ -f "${MGMT_SECRETS}" ] && grep -q '^sops:' "$MGMT_SECRETS" 2>/dev/null || echo "$0 encrypt ${MGMT}")
  5. ./install.sh ${MGMT}
EOF3
    ;;

encrypt)
    require_site "${2:-}" encrypt
    F=$(secrets_file "$2")
    [ -f "$F" ] || die "$F not found"
    if grep -q '^sops:' "$F" 2>/dev/null; then
        info "already encrypted — use '$0 edit $2' to change it"
        exit 0
    fi
    # Only UNFILLED VALUES count. A bare `grep REPLACE_` also matched the
    # templates' own comments — including one that reads "fill in every
    # REPLACE_" — so this warned on every site, correct ones included, and an
    # operator who learned to answer `y` would answer `y` to a real one too.
    # Match `<key>: REPLACE_...` on a line that is not commented out, and name
    # the offending keys so the warning is actionable.
    UNFILLED=$(grep -nE '^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*REPLACE_' "$F" || true)
    [ -n "$UNFILLED" ] && {
        echo "WARNING: $F has unfilled placeholder VALUES:" >&2
        echo "$UNFILLED" | sed 's/^/    /' >&2
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
