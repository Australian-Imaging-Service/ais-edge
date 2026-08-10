#!/bin/sh
# =============================================================================
# cert-sync — push renewed Secrets from the management cluster into ONE edge.
# =============================================================================
# WHAT PROBLEM THIS SOLVES.
# cert-manager renews certificates on the MANAGEMENT cluster. Edge clusters
# hold copies that scripts/07b pushed ONCE, and nothing re-pushes them. A
# certificate that renews at two-thirds of its lifetime therefore leaves the
# edge holding an expired one, and whatever used it stops working silently on
# a date nobody has in a calendar. A shared password does not expire, so mTLS
# on the Loki push path was strictly WORSE than the password it replaces until
# this job existed. That is why this shipped before mTLS, not with it — and
# the per-site Loki push client certificate is now what it mainly carries.
#
# This REPLACES the manual distribution in scripts/07b — steps 2 and 3, the
# push credential and the ca-bundle. Same Secrets, pushed by a scheduled job
# instead of by a human running a script once per site, so this is a net
# reduction in moving parts rather than an addition.
#
# ONE EDGE PER INVOCATION. templates/cert-sync.yaml renders one CronJob per
# entry in `edges`, so a site that is unreachable cannot affect any other
# site's rotation — that isolation is structural here, not a property of the
# control flow below. See the header of that template for why.
#
# -----------------------------------------------------------------------------
# THE LOG SCHEMA IS THE SAME ONE-JSON-OBJECT-PER-LINE FORMAT AS
# charts/edge/files/s3-uploader.sh, so Vector -> Loki sees a familiar shape:
#
#   {"ts", "component":"cert-sync", "edge", "event", "secret", "message", ...}
#
# The `secret` field takes the place of the uploader's `session`: it is the
# thing being acted on, written "<namespace>/<name>" in the EDGE cluster.
#
# Event names, all four of which an operator or a rule may select on:
#   sync_skipped     the edge was not reachable; nothing was attempted
#   sync_unchanged   destination already byte-identical; nothing written
#   sync_updated     destination created or changed
#   sync_failed      a source key was missing, or the write failed
# plus `startup`, which carries the resolved API endpoint.
#
# -----------------------------------------------------------------------------
# EXIT CODE IS LOAD-BEARING. This exits non-zero when it did NOT complete a
# full sync of this edge, INCLUDING when the edge was merely unreachable.
# That is deliberate: kube_cronjob_status_last_successful_time is the input to
# the CertSyncStale alert, and a job that exits 0 after skipping everything
# would keep that timestamp fresh — which is precisely the silent failure this
# whole job exists to prevent. An unreachable site must look stale.
#
# -----------------------------------------------------------------------------
# CREDENTIAL HANDLING. Secret material is read into shell variables and
# decoded into $WORK_DIR, which the pod backs with a memory-medium emptyDir
# (tmpfs), so the decoded bytes are not written to the node's disk. Values are
# never logged: comparisons are on the base64 form and only ever produce
# "changed / unchanged". Decoded files are removed after each item.
# =============================================================================
set -u

: "${EDGE_NAME:?EDGE_NAME required}"
: "${EDGE_NAMESPACE:?EDGE_NAMESPACE required}"
: "${KUBECONFIG_SECRET:?KUBECONFIG_SECRET required}"

SPEC_FILE="${SPEC_FILE:-/spec/secrets.list}"
WORK_DIR="${WORK_DIR:-/work}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-30s}"
# inCluster  discover the child control-plane Service on the management
#            cluster and talk to it over ClusterIP.
# kubeconfig use the server address k0smotron published in the kubeconfig,
#            which is the external ingress hostname.
API_ENDPOINT_MODE="${API_ENDPOINT_MODE:-inCluster}"

umask 077
mkdir -p "$WORK_DIR" || exit 1
ERRF="$WORK_DIR/.stderr"
KC="$WORK_DIR/.kubeconfig"

# --- logging -----------------------------------------------------------------
# kubectl error text contains quotes and newlines. Unescaped, one of those
# turns a log line into something Vector's parse_json drops on the floor, and
# the event disappears from Loki without anything failing. Escape order is
# backslash, then quote, then whitespace.
esc() {
    printf '%s' "$*" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n\r\t' '   '
}

jlog() {
    # $1=event  $2=secret  $3=message  $4=extra JSON (leading comma)
    printf '{"ts":"%s","component":"cert-sync","edge":"%s","event":"%s","secret":"%s","message":"%s"%s}\n' \
        "$(date -Iseconds)" "$EDGE_NAME" "$1" "${2:-}" "$(esc "${3:-}")" "${4:-}"
}

errtext() {
    [ -s "$ERRF" ] || { printf ''; return; }
    # Bounded: a kubectl dump of a whole object would otherwise become the
    # log line.
    head -c 400 "$ERRF"
}

# Management-cluster kubectl. Uses the pod's own ServiceAccount.
#
# NO --request-timeout HERE, DELIBERATELY. Measured on alpine/kubectl:1.35.4
# inside this very pod:
#
#   kubectl -n edge-dev get secret edge-dev-kubeconfig -o name
#     -> secret/edge-dev-kubeconfig
#   kubectl --request-timeout=30s -n edge-dev get secret edge-dev-kubeconfig -o name
#     -> The connection to the server localhost:8080 was refused
#
# Passing the flag makes kubectl stop resolving IN-CLUSTER configuration and
# fall back to its compiled-in default server. `kubectl --v=6` without it logs
# "Using in-cluster configuration" and a 200 against https://10.96.0.1:443;
# with it, no in-cluster config is loaded at all.
#
# The failure is indistinguishable from "the ServiceAccount cannot read the
# Secret": every sync reports sync_failed on the FIRST call, so cert-sync has
# never delivered anything, and the ca-bundle each edge needs was only ever
# present because the old scripts/07b copied it by hand.
#
# The timeout still applies to the EDGE calls below, which pass an explicit
# --kubeconfig and therefore load their config from the file rather than from
# in-cluster discovery — the flag is harmless there. Management calls go to
# 10.96.0.1 inside the same cluster; a hung call there is bounded by the Job's
# own activeDeadlineSeconds instead.
kmgmt() { kubectl "$@"; }

# Edge-cluster kubectl. SERVER is a bare URL with no spaces, so the unquoted
# expansion below is intentional and safe: it must produce two words or none.
kedge() {
    # shellcheck disable=SC2086
    kubectl --kubeconfig "$KC" ${SERVER:+--server $SERVER} \
        --request-timeout="$REQUEST_TIMEOUT" "$@"
}

# jsonpath treats "." as a path separator, so a key like ca.crt has to be
# escaped or {.data.ca.crt} silently selects nothing — which would read as
# "source key absent" and be reported as a failure for a Secret that is fine.
jp() { printf '%s' "$1" | sed 's/\./\\./g'; }

# =============================================================================
# 1. The child-cluster kubeconfig
# =============================================================================
# k0smotron publishes it as Secret <cluster>-kubeconfig in the cluster's own
# namespace, type cluster.x-k8s.io/secret, with a SINGLE data key `value`.
# Verified against the live management cluster:
#   kubectl -n edge-dev get secret edge-dev-kubeconfig
#   -> type cluster.x-k8s.io/secret, data keys ['value'],
#      ownerReferences [Cluster/edge-dev]
kc_b64=$(kmgmt -n "$EDGE_NAMESPACE" get secret "$KUBECONFIG_SECRET" \
    -o jsonpath='{.data.value}' 2>"$ERRF")
if [ -z "$kc_b64" ]; then
    jlog sync_failed "" "cannot read ${EDGE_NAMESPACE}/${KUBECONFIG_SECRET} on mgmt: $(errtext)"
    exit 1
fi
printf '%s' "$kc_b64" | base64 -d > "$KC" 2>"$ERRF" || {
    jlog sync_failed "" "kubeconfig from ${EDGE_NAMESPACE}/${KUBECONFIG_SECRET} did not base64-decode: $(errtext)"
    exit 1
}
kc_b64=""
chmod 600 "$KC"

# =============================================================================
# 2. Where to reach the child API server
# =============================================================================
# The published kubeconfig points at the EXTERNAL ingress hostname (measured:
# server: https://k0s.aisedge.local:443). A pod on the management cluster
# cannot resolve that through cluster DNS, so using it as-is depends on the
# hostAliases the CronJob renders and on hairpinning back in through the
# ingress.
#
# inCluster avoids both. k0smotron's control-plane Service is discovered by
# label rather than by name, so this does not hardcode `kmc-<name>-nodeport`
# or the NodePort number, and it keeps working if a site is migrated from
# NodePort to ClusterIP+SNI. Measured on the live cluster:
#   svc kmc-edge-dev-nodeport labels app=k0smotron, cluster=edge-dev,
#       app.kubernetes.io/component=control-plane; port name "api" = 30443
#   the API server's serving certificate carries SANs including
#       kmc-edge-dev-nodeport.edge-dev.svc.cluster.local
#   so TLS verification against the kubeconfig's CA succeeds on this address.
#
# `kubectl --server` overrides only the address; the CA and client certificate
# still come from the kubeconfig. Measured: `kubectl --kubeconfig <published>
# --server https://<addr> get ns` succeeds with verification intact.
SERVER=""
if [ "$API_ENDPOINT_MODE" = "inCluster" ]; then
    svc=$(kmgmt -n "$EDGE_NAMESPACE" get svc \
        -l "app=k0smotron,cluster=${EDGE_NAME},app.kubernetes.io/component=control-plane" \
        -o jsonpath='{.items[0].metadata.name}' 2>"$ERRF")
    port=$(kmgmt -n "$EDGE_NAMESPACE" get svc \
        -l "app=k0smotron,cluster=${EDGE_NAME},app.kubernetes.io/component=control-plane" \
        -o 'jsonpath={.items[0].spec.ports[?(@.name=="api")].port}' 2>"$ERRF")
    if [ -n "$svc" ] && [ -n "$port" ]; then
        SERVER="https://${svc}.${EDGE_NAMESPACE}.svc.cluster.local:${port}"
    fi
fi

# NO APOSTROPHE IN THE DEFAULT BELOW. Inside "${var:-word}", dash and busybox
# treat a ' as a literal character but BASH starts a quote on it, so
# "the kubeconfig's own address" parses here and fails `bash -n`. The script is
# POSIX sh and runs under busybox, but a lint step that shells out to bash is
# a normal thing for CI to do, and this would fail it for no reason.
jlog startup "" "syncing ${EDGE_NAME} via ${SERVER:-the server address in the kubeconfig} spec=${SPEC_FILE}"

# =============================================================================
# 3. Reachability
# =============================================================================
# Probed once, before anything is written. A site that is down is logged and
# skipped; nothing here can affect another site, which has its own CronJob.
if ! kedge get --raw /readyz >/dev/null 2>"$ERRF"; then
    jlog sync_skipped "" "edge API not reachable at ${SERVER:-kubeconfig server}: $(errtext)"
    exit 1
fi

# =============================================================================
# 4. Sync each configured Secret
# =============================================================================
# Spec format, one item per line, written by templates/cert-sync.yaml:
#   srcNamespace|srcName|dstNamespace|dstName|type|srcKey=dstKey,srcKey=dstKey
# Pipe-delimited rather than JSON because this image has no jq, and adding one
# to parse six fixed fields is not worth an image we would have to maintain.
# The template refuses to render a name or key containing | , or = .
failures=0
synced=0

while IFS='|' read -r src_ns src_name dst_ns dst_name dst_type keymap <&3; do
    # A comment or blank line puts everything in the first field, so the skip
    # test has to be on the FIRST field, not on src_name.
    case "$src_ns" in ''|'#'*) continue ;; esac
    if [ -z "$src_name" ] || [ -z "$dst_ns" ] || [ -z "$dst_name" ] || [ -z "$keymap" ]; then
        jlog sync_failed "" "malformed spec line for ${EDGE_NAME}: expected srcNs|srcName|dstNs|dstName|type|keys"
        failures=$((failures + 1))
        continue
    fi
    ref="${dst_ns}/${dst_name}"

    # Destination namespace. scripts/07b did this too (`kubectl create
    # namespace logging`), and a first sync into a freshly built site is
    # exactly the case where it does not exist yet.
    if ! kedge get namespace "$dst_ns" >/dev/null 2>&1; then
        if ! kedge create namespace "$dst_ns" >/dev/null 2>"$ERRF"; then
            jlog sync_failed "$ref" "destination namespace ${dst_ns} does not exist and could not be created: $(errtext)"
            failures=$((failures + 1))
            continue
        fi
    fi

    changed=0
    broken=0
    fromfiles=""
    written=""

    # Compare BEFORE writing, key by key, on the base64 form. Comparing the
    # encoded form means no plaintext is ever held for the sake of a diff.
    for pair in $(printf '%s' "$keymap" | tr ',' ' '); do
        src_key=${pair%%=*}
        dst_key=${pair#*=}

        src_val=$(kmgmt -n "$src_ns" get secret "$src_name" \
            -o "jsonpath={.data.$(jp "$src_key")}" 2>"$ERRF")
        if [ -z "$src_val" ]; then
            jlog sync_failed "$ref" "source ${src_ns}/${src_name} key ${src_key} is absent or unreadable: $(errtext)"
            broken=1
            break
        fi

        # Missing destination Secret or key -> empty -> counts as changed.
        dst_val=$(kedge -n "$dst_ns" get secret "$dst_name" \
            -o "jsonpath={.data.$(jp "$dst_key")}" 2>/dev/null)
        [ "$src_val" = "$dst_val" ] || changed=1

        if ! printf '%s' "$src_val" | base64 -d > "${WORK_DIR}/${dst_key}" 2>"$ERRF"; then
            jlog sync_failed "$ref" "source ${src_ns}/${src_name} key ${src_key} did not base64-decode: $(errtext)"
            broken=1
            break
        fi
        src_val=""
        dst_val=""
        fromfiles="${fromfiles} --from-file=${dst_key}=${WORK_DIR}/${dst_key}"
        written="${written} ${WORK_DIR}/${dst_key}"
    done

    if [ "$broken" -eq 1 ]; then
        # shellcheck disable=SC2086
        [ -n "$written" ] && rm -f $written
        failures=$((failures + 1))
        continue
    fi

    if [ "$changed" -eq 0 ]; then
        # Idempotent path. Logged rather than silent: "nothing changed" is the
        # normal answer for this job and an operator needs to be able to tell
        # it apart from "did not run".
        jlog sync_unchanged "$ref" "already identical for keys ${keymap}"
        # shellcheck disable=SC2086
        [ -n "$written" ] && rm -f $written
        synced=$((synced + 1))
        continue
    fi

    # `kubectl label --local` adds the provenance labels without a second API
    # call and without hand-assembling YAML around base64 blobs. The whole
    # pipeline is local until `kedge apply`.
    #
    # NOTE ON OWNERSHIP: the destination Secret is owned by this job. Keys
    # added to it by hand are removed the next time any managed key changes,
    # because `apply` prunes to the last applied configuration.
    # shellcheck disable=SC2086
    if kubectl create secret generic "$dst_name" --namespace "$dst_ns" \
            --type "$dst_type" $fromfiles --dry-run=client -o yaml 2>"$ERRF" \
        | kubectl label --local -f - -o yaml \
            app.kubernetes.io/managed-by=cert-sync \
            ais-edge.org/synced-from=mgmt 2>>"$ERRF" \
        | kedge apply -f - >/dev/null 2>>"$ERRF"; then
        jlog sync_updated "$ref" "wrote keys ${keymap} from ${src_ns}/${src_name}"
        synced=$((synced + 1))
    else
        jlog sync_failed "$ref" "apply into edge failed: $(errtext)"
        failures=$((failures + 1))
    fi

    # shellcheck disable=SC2086
    [ -n "$written" ] && rm -f $written
done 3< "$SPEC_FILE"

rm -f "$KC" "$ERRF"

if [ "$failures" -gt 0 ]; then
    jlog sync_failed "" "${failures} of $((failures + synced)) secrets failed for ${EDGE_NAME}"
    exit 1
fi
exit 0
