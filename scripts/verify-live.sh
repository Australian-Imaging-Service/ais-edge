#!/usr/bin/env bash
# =============================================================================
# verify-live — is this tier-1 install actually working, right now?
# =============================================================================
#   scripts/verify-live.sh <site>
#   make verify-live SITE=<site>
#
# `make ci` proves the CHARTS are correct. Nothing proved the CLUSTER was. This
# is the other kind of check: it reads the live system and asks whether each hop
# of the pipeline is actually in place.
#
# WHAT IT DELIBERATELY DOES NOT DO: send a DICOM. That would put data through a
# live site. This checks that every component, credential, volume and endpoint a
# study needs is present and healthy — the things whose absence makes a study
# vanish quietly rather than fail loudly.
#
# TIER-1 SHAPE: one node, one namespace, one Helm release, and NO management
# plane — so there is no edge loop, no SSH, no child kubeconfig and no cert-sync
# to check. If you are looking for those, you are on the wrong tier.
#
# Exit code is the number of failures, capped at 250, so CI and a human get the
# same answer.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE="${1:-}"
[ -n "$SITE" ] || { echo "usage: $0 <site>    (a directory under sites/)" >&2; exit 2; }

VALUES="${SCRIPT_DIR}/sites/${SITE}/values.yaml"
SECRETS="${SCRIPT_DIR}/sites/${SITE}/secrets.enc.yaml"
[ -f "$VALUES" ] || { echo "no such site: sites/${SITE}" >&2; exit 2; }

if [ -t 1 ]; then _G=$'\033[32m'; _R=$'\033[31m'; _Y=$'\033[33m'; _B=$'\033[1m'; _O=$'\033[0m'
else _G=; _R=; _Y=; _B=; _O=; fi

PASS=0; FAIL=0; SKIP=0; FAILED=(); SKIPPED=()
ok()      { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$_G" "$_O" "$*"; }
bad()     { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  %sFAIL%s  %s\n' "$_R" "$_O" "$1"
            [ $# -gt 1 ] && printf '        %s\n' "$2"; }
skip()    { SKIP=$((SKIP+1)); SKIPPED+=("$1"); printf '  %sSKIP%s  %s\n' "$_Y" "$_O" "$1"; }
section() { printf '\n%s== %s ==%s\n' "$_B" "$*" "$_O"; }

cfg() {
    python3 - "$VALUES" "$1" "${2:-}" <<'PY'
import sys, yaml
try: cur = yaml.safe_load(open(sys.argv[1])) or {}
except Exception: print(sys.argv[3] if len(sys.argv) > 3 else ""); raise SystemExit
for p in sys.argv[2].split('.'):
    cur = cur.get(p) if isinstance(cur, dict) else None
    if cur is None: break
print(cur if cur not in (None, '') else (sys.argv[3] if len(sys.argv) > 3 else ''))
PY
}

NS="$(cfg namespace xnat-ingest)"
NODE_IP="$(cfg nodeIP)"
AET="$(cfg orthanc.aet AISEDGE)"
STACK="$(cfg observability.stack.enabled false)"
RELEASE="${AIS_RELEASE:-$SITE}"

# k0s ships its own kubectl; a plain `kubectl` may not be on PATH for root.
if command -v kubectl >/dev/null 2>&1; then K="kubectl"
elif command -v k0s >/dev/null 2>&1; then K="k0s kubectl"
else echo "neither kubectl nor k0s found" >&2; exit 2; fi

printf '%s=== verify-live: tier-1 site %s ===%s\n' "$_B" "$SITE" "$_O"

# -----------------------------------------------------------------------------
section "cluster"
# -----------------------------------------------------------------------------
if $K version >/dev/null 2>&1; then ok "API server reachable"
else bad "API server unreachable" "is k0s running?  sudo k0s status"; fi

nodes_ready=$($K get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
nodes_all=$($K get nodes --no-headers 2>/dev/null | wc -l)
if [ "$nodes_ready" -ge 1 ] && [ "$nodes_ready" = "$nodes_all" ]; then
    ok "node Ready ($nodes_ready/$nodes_all)"
else
    bad "node(s) not Ready ($nodes_ready/$nodes_all)"
fi

# -----------------------------------------------------------------------------
section "workloads"
# -----------------------------------------------------------------------------
# A pod can be Running and still be broken, so check READINESS, not phase.
unhealthy=$($K get pods -n "$NS" -o json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for p in d.get("items", []):
    st = p.get("status", {}); phase = st.get("phase")
    if phase == "Succeeded": continue
    cs = st.get("containerStatuses") or []
    ready = bool(cs) and all(c.get("ready") for c in cs)
    if phase == "Running" and ready: continue
    why = []
    for c in cs:
        w = (c.get("state") or {}).get("waiting")
        if w: why.append("%s: %s" % (c.get("name"), w.get("reason")))
    # NO f-STRING: python < 3.12 rejects a backslash inside an f-string
    # expression, and a SyntaxError here would print nothing on stdout — which
    # reads as "no unhealthy pods". That exact bug once reported a broken
    # cluster as healthy.
    print(str(p["metadata"]["name"]) + "\t" + (phase or "?") + "\t" + ("; ".join(why) or "not ready"))
' 2>/dev/null)
total=$($K get pods -n "$NS" --no-headers 2>/dev/null | wc -l)
if [ -z "$unhealthy" ] && [ "$total" -gt 0 ]; then
    ok "all $total pod(s) healthy in $NS"
elif [ "$total" -eq 0 ]; then
    bad "no pods in namespace $NS" "has the chart been installed?  helm list -n $NS"
else
    while IFS=$'\t' read -r n ph w; do [ -n "$n" ] && bad "$NS/$n ($ph)" "$w"; done <<< "$unhealthy"
fi

# Every pipeline stage must exist, by its component label. A missing stage is
# invisible in a pod list that otherwise looks fine.
for comp in dicom-receiver group assign upload; do
    n=$($K get pods -n "$NS" -l "component=$comp" --no-headers 2>/dev/null | wc -l)
    [ "$n" -ge 1 ] && ok "pipeline stage present: $comp" || bad "pipeline stage MISSING: $comp"
done

# -----------------------------------------------------------------------------
section "credentials"
# -----------------------------------------------------------------------------
for s in xnat-credentials orthanc-deid-salt; do
    if $K get secret "$s" -n "$NS" >/dev/null 2>&1; then ok "Secret present: $s"
    else bad "Secret MISSING: $s" "scripts/site-secrets.sh apply ${SITE}"; fi
done

# THE SALT IS NOT VALIDATED BY ANYTHING ELSE. The chart checks only that the
# Secret is NAMED, so a site installed with the shipped placeholder starts
# cleanly and derives every pseudonym from a string published in this repo.
salt=$($K get secret orthanc-deid-salt -n "$NS" -o jsonpath='{.data.AIS_DEID_HMAC_SALT}' 2>/dev/null | base64 -d 2>/dev/null)
if [ -z "$salt" ]; then
    skip "de-id salt not readable (Secret missing?)"
elif [ "$salt" = "REPLACE_64_HEX_CHARS" ]; then
    bad "de-id salt is STILL THE PLACEHOLDER" \
        "every SubjectHash on this site derives from a public string. openssl rand -hex 32"
elif printf '%s' "$salt" | grep -qE '^[0-9a-fA-F]{64}$'; then
    ok "de-id salt is set (64 hex chars)"
else
    bad "de-id salt is not 64 hex characters" "openssl rand -hex 32"
fi

if [ -f "$SECRETS" ]; then
    grep -q '^sops:' "$SECRETS" && ok "sites/${SITE}/secrets.enc.yaml is encrypted" \
        || bad "sites/${SITE}/secrets.enc.yaml is NOT encrypted" "scripts/site-secrets.sh encrypt ${SITE}"
fi

# -----------------------------------------------------------------------------
section "storage"
# -----------------------------------------------------------------------------
for pvc in $($K get pvc -n "$NS" --no-headers 2>/dev/null | awk '{print $1"="$2}'); do
    name="${pvc%%=*}"; ph="${pvc##*=}"
    [ "$ph" = "Bound" ] && ok "PVC Bound: $name" || bad "PVC $name is $ph" "kubectl describe pvc $name -n $NS"
done

# The pipeline hardlinks between stages, so they must share one filesystem —
# a hardlink cannot cross a mount point, and the failure is a copy-mode error
# deep in group-orthanc rather than anything about disks.
pipe_path="$(cfg storage.pipeline.hostPath /data/xnat-ingest)"
fb_path="$(cfg storage.facilityBackup.hostPath /data/facility-backup)"
if [ -d "$pipe_path" ]; then
    ok "pipeline directory exists: $pipe_path"
    if [ -d "$fb_path" ]; then
        d1=$(stat -c %d "$pipe_path" 2>/dev/null); d2=$(stat -c %d "$fb_path" 2>/dev/null)
        [ -n "$d1" ] && [ "$d1" = "$d2" ] && ok "facility backup shares the pipeline filesystem" \
            || skip "facility backup is on a different filesystem than the pipeline (hardlinks only matter WITHIN the pipeline, so this is usually fine)"
    else
        bad "facility backup directory missing: $fb_path" "the archive of record has nowhere to land"
    fi
else
    skip "pipeline directory $pipe_path not visible from here (run on the node)"
fi

# -----------------------------------------------------------------------------
section "DICOM entry point"
# -----------------------------------------------------------------------------
# Modalities C-STORE to this node's port 4242. It is a hostPort, so it is only
# listening if the Orthanc pod is actually scheduled and started.
if command -v ss >/dev/null 2>&1 && ss -tln 2>/dev/null | grep -q ':4242 '; then
    ok "DICOM port 4242 is listening (AET=$AET on ${NODE_IP:-this node})"
elif $K get pods -n "$NS" -l component=dicom-receiver --no-headers 2>/dev/null | grep -q Running; then
    skip "port 4242 not visible from here, but the receiver pod is Running (check on the node)"
else
    bad "nothing is listening on 4242" "no modality can send to this site"
fi

# -----------------------------------------------------------------------------
section "XNAT delivery path"
# -----------------------------------------------------------------------------
# The uploader is the ONLY component that talks to XNAT, so test from inside it.
up=$($K get pods -n "$NS" -l component=upload -o name 2>/dev/null | head -1)
if [ -z "$up" ]; then
    bad "no upload pod to test XNAT from"
else
    code=$($K exec -n "$NS" "$up" -- sh -c '
        python3 - <<'"'"'PY'"'"' 2>/dev/null
import os, ssl, urllib.request, base64
host=os.environ.get("XINGEST_HOST",""); u=os.environ.get("XINGEST_USER",""); p=os.environ.get("XINGEST_PASS","")
if not host: print("000"); raise SystemExit
ctx=ssl.create_default_context()
if os.environ.get("XINGEST_VERIFY_SSL","true").lower()=="false":
    ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
r=urllib.request.Request(host.rstrip("/")+"/data/JSESSION")
r.add_header("Authorization","Basic "+base64.b64encode(("%s:%s"%(u,p)).encode()).decode())
try:
    with urllib.request.urlopen(r, timeout=15, context=ctx) as resp: print(resp.status)
except Exception as e: print(getattr(e,"code","000"))
PY' 2>/dev/null | tr -d '[:space:]')
    case "$code" in
        200) ok "XNAT reachable and credentials accepted" ;;
        401|403) bad "XNAT rejected the credentials (HTTP $code)" "check xnat-credentials for ${SITE}" ;;
        000|"") bad "XNAT unreachable from the uploader" "no session can be delivered; check egress and XINGEST_HOST" ;;
        *) bad "XNAT returned HTTP $code" ;;
    esac
fi

# -----------------------------------------------------------------------------
section "observability"
# -----------------------------------------------------------------------------
if [ "$STACK" != "true" ] && [ "$STACK" != "True" ]; then
    skip "local stack disabled (observability.stack.enabled=false) — the pipeline is unaffected"
else
    # CHECK EACH BY ITS OWN KIND AND NAME, and require non-empty output.
    # This was `get statefulset X || get prometheus` — an `||` that let ANY
    # Prometheus CRD in the cluster satisfy both checks, so it reported
    # "ais-loki present" against a cluster where the namespace did not exist.
    # `kubectl get <kind> -n <ns>` with no matches still exits 0 in some
    # versions, so presence has to be decided on OUTPUT, not exit status.
    if [ -n "$($K get statefulset ais-loki -n "$NS" --no-headers 2>/dev/null)" ]; then
        ok "Loki present (StatefulSet ais-loki)"
    else
        bad "Loki missing (StatefulSet ais-loki)" "logs are being collected nowhere"
    fi
    if [ -n "$($K get prometheus ais-kps-prometheus -n "$NS" --no-headers 2>/dev/null)" ]; then
        ok "Prometheus present (Prometheus/ais-kps-prometheus)"
    else
        bad "Prometheus missing (Prometheus/ais-kps-prometheus)"
    fi
    if [ -n "$($K get alertmanager ais-kps-alertmanager -n "$NS" --no-headers 2>/dev/null)" ]; then
        ok "Alertmanager present (Alertmanager/ais-kps-alertmanager)"
    else
        bad "Alertmanager missing (Alertmanager/ais-kps-alertmanager)" "nothing can deliver an alert"
    fi
    # Grafana is only useful if the NodePort actually answers.
    gport=$($K get svc -n "$NS" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].spec.ports[0].nodePort}' 2>/dev/null)
    if [ -n "$gport" ]; then
        if command -v curl >/dev/null 2>&1 && curl -s -o /dev/null -m 8 "http://127.0.0.1:${gport}/login" 2>/dev/null; then
            ok "Grafana answering on NodePort ${gport}  (http://${NODE_IP:-<node>}:${gport})"
        else
            skip "Grafana NodePort ${gport} not answering from here"
        fi
    else
        bad "Grafana has no NodePort" "there is no ingress on tier-1, so this is the only way in"
    fi
    # ALERT RULES ARE THE THING MOST LIKELY TO BE SILENTLY ABSENT: the stack can
    # be perfectly healthy and evaluating nothing.
    nrules=$($K get prometheusrule -n "$NS" --no-headers 2>/dev/null | grep -c 'ais-edge' || true)
    [ "${nrules:-0}" -gt 0 ] && ok "AIS PrometheusRule group(s) loaded: $nrules" \
        || bad "NO ais-edge PrometheusRules are loaded" "Prometheus is running and evaluating none of this pipeline's alerts"
fi

# -----------------------------------------------------------------------------
printf '\n%s=== summary ===%s\n' "$_B" "$_O"
printf '  %d passed, %d failed, %d not checked\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
    printf '\n%sFAILURES%s:\n' "$_R" "$_O"
    for f in "${FAILED[@]}"; do printf '  - %s\n' "$f"; done
fi
[ "$FAIL" -gt 250 ] && exit 250
exit "$FAIL"
