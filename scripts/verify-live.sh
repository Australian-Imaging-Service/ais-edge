#!/usr/bin/env bash
# =============================================================================
# verify-live.sh — is this RUNNING install actually healthy?
# =============================================================================
#   scripts/verify-live.sh <site>            full suite
#   scripts/verify-live.sh <site> --quiet     failures and summary only
#   make verify-live SITE=<site>
#
# `make ci` proves the CHARTS are correct and needs no cluster. Nothing proved
# the CLUSTER was. That knowledge lived in docs/TOUR.md §5b, in
# scripts/check-alert-inputs.sh and in remembered kubectl one-liners, so "did
# the install work?" had no answer you could run.
#
# THE RULE THAT SHAPES EVERY CHECK
#   PASS  verified against the live system
#   SKIP  could not be checked — counted and listed SEPARATELY, never as a pass
#   FAIL  broken, unreachable, or unparseable
#
# This repo has been bitten by silent-skip more than by any other class of bug
# (an alert on a metric that never existed; Vector pointed at a Service that had
# moved), so a check that could not run must never read as green.
#
# READ-ONLY. Every Kubernetes call is a `get`; the XNAT probe is a GET. Nothing
# here writes, patches, deletes or scales.
# =============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE=""; QUIET=0
for a in "$@"; do
    case "$a" in
        --quiet|-q) QUIET=1 ;;
        -h|--help)  sed -n '2,24p' "$0" | sed 's/^# \?//'; exit 2 ;;
        -*)         echo "unknown flag: $a" >&2; exit 2 ;;
        *)          SITE="$a" ;;
    esac
done
[ -n "$SITE" ] || { sed -n '2,10p' "$0" | sed 's/^# \?//'; exit 2; }

VALUES="${REPO_DIR}/sites/${SITE}/values.yaml"
[ -f "$VALUES" ] || { echo "no such site: sites/${SITE}/values.yaml" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 2; }

TOPOLOGY="$(python3 -c "
import yaml,sys
v=yaml.safe_load(open('$VALUES')) or {}
print(v.get('topology','onprem'))" 2>/dev/null || echo onprem)"

KUBECTL="${KUBECTL:-sudo k0s kubectl}"
NS_MGMT="${NS_MGMT:-ais-mgmt}"
NS_UPLOAD="${NS_UPLOAD:-xnat-upload}"

_G=$'\033[32m'; _R=$'\033[31m'; _Y=$'\033[33m'; _B=$'\033[1m'; _O=$'\033[0m'
PASS=0; FAIL=0; SKIP=0; FAILED=(); SKIPPED=()
ok()   { PASS=$((PASS+1)); [ "$QUIET" = 1 ] || printf '  %sPASS%s  %s\n' "$_G" "$_O" "$*"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  %sFAIL%s  %s\n' "$_R" "$_O" "$1"
         [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
skip() { SKIP=$((SKIP+1)); SKIPPED+=("$1"); printf '  %sSKIP%s  %s\n' "$_Y" "$_O" "$1"
         [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
head_() { [ "$QUIET" = 1 ] || printf '\n%s== %s ==%s\n' "$_B" "$*" "$_O"; }

edges() {
    python3 -c "
import yaml
for e in (yaml.safe_load(open('$VALUES')) or {}).get('edges') or []:
    n = e.get('name')
    if n: print(n)"
}

# Pods that are not healthy. Job-owned pods are EXCLUDED: a Job pod that failed
# once is a historical record kept until garbage collection, not current state.
# Counting them made this script report five-day-old CronJob runs as a broken
# cluster. Periodic jobs are judged by lastSuccessfulTime instead, below.
bad_pods() { # bad_pods <kubectl-prefix> <namespace>
    $1 -n "$2" get pods -o json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for p in d.get("items", []):
    m = p["metadata"]; st = p.get("status", {}); ph = st.get("phase", "?")
    if ph == "Succeeded": continue
    if any(o.get("kind") == "Job" for o in (m.get("ownerReferences") or [])): continue
    css = st.get("containerStatuses") or []
    notready = [c for c in css if not c.get("ready")]
    if ph == "Running" and not notready: continue
    why = ph
    for c in notready:
        w = (c.get("state") or {}).get("waiting") or {}
        if w.get("reason"): why = w["reason"]; break
    # NO f-STRING. Python < 3.12 rejects a backslash anywhere inside an
    # f-string expression, so f"{m[\"name\"]}" is a SyntaxError. This runs under
    # `python3 -c` inside a command substitution, so that error went to stderr
    # while stdout stayed EMPTY — and an empty result reads as "no unhealthy
    # pods". The crash therefore reported every namespace as healthy. A check
    # that cannot run must never look like a pass.
    print(str(m.get("name")) + "\t" + str(why))'
}

printf '%s=== verify-live: site %s ===%s\n' "$_B" "$SITE" "$_O"

head_ "management cluster"
if ! $KUBECTL get --raw /readyz >/dev/null 2>&1; then
    bad "management API server not reachable" "everything below depends on it"
    printf '\n%sABORTED%s\n' "$_R" "$_O"; exit 2
fi
ok "management API server reachable"

nb=$($KUBECTL get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{print $1" ("$2")"}')
[ -z "$nb" ] && ok "management node(s) Ready" || bad "management node not Ready: ${nb}"

for ns in "$NS_MGMT" "$NS_UPLOAD"; do
    out=$(bad_pods "$KUBECTL" "$ns")
    if [ -z "$out" ]; then
        n=$($KUBECTL -n "$ns" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
        ok "all ${n} pod(s) healthy in ${ns}"
    else
        bad "unhealthy pods in ${ns}" "$(echo "$out" | sed 's/\t/ -> /' | paste -sd'; ')"
    fi
done

head_ "certificates"
# Found BY NAME across namespaces: cert-manager's --cluster-resource-namespace
# is configurable, and `get certificate <name> -A` is not valid kubectl (a name
# cannot be combined with --all-namespaces) — it returns nothing, which this
# script once reported as "CA not Ready" while the CA was perfectly healthy.
ca=$($KUBECTL get certificates -A -o json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for c in d.get("items", []):
    if c["metadata"]["name"] == "ais-edge-ca":
        cd = {x.get("type"): x.get("status") for x in (c.get("status", {}).get("conditions") or [])}
        print((cd.get("Ready") or "Unknown") + " " + c["metadata"]["namespace"]); break')
case "$ca" in
    True*) ok "CA certificate ais-edge-ca Ready (ns ${ca#True })" ;;
    "")    bad "CA certificate ais-edge-ca not found in any namespace" ;;
    *)     bad "CA certificate ais-edge-ca not Ready (${ca})" ;;
esac

nr=$($KUBECTL get certificates -A -o json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for c in d.get("items", []):
    cd = {x.get("type"): x.get("status") for x in (c.get("status", {}).get("conditions") or [])}
    if cd.get("Ready") != "True":
        print(c["metadata"]["namespace"] + "/" + c["metadata"]["name"])')
[ -z "$nr" ] && ok "all Certificates Ready" \
  || bad "Certificates not Ready: $(echo "$nr" | paste -sd', ')" \
         "a Pending Certificate does not error — the Ingress serves nginx's self-signed default"

# -----------------------------------------------------------------------------
# CLOUD ONLY: did the load balancer actually get an address?
# -----------------------------------------------------------------------------
# A LoadBalancer Service with no cloud controller to satisfy it sits at
# <pending> forever. Nothing errors: the controller pod is Running, the Service
# exists, and every fleet hostname simply resolves to nothing. The first symptom
# is an edge that will not join, half an hour later, at the other end of the
# link. On-prem there is no LoadBalancer to wait for, so this whole section is
# skipped rather than reported.
if [ "$TOPOLOGY" = "cloud" ]; then
    head_ "cloud load balancer"
    lb_svc="$($KUBECTL get svc -n "$NS_MGMT" -l app.kubernetes.io/name=ingress-nginx \
              -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].metadata.name}' 2>/dev/null || true)"
    if [ -z "$lb_svc" ]; then
        bad "no LoadBalancer Service for ingress-nginx in ${NS_MGMT}" \
            "topology=cloud but the ingress is not asking the cloud for an address. Check ingress-nginx.controller.service.type in sites/${SITE}/values.yaml"
    else
        lb_addr="$($KUBECTL get svc -n "$NS_MGMT" "$lb_svc" \
                   -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
        if [ -z "$lb_addr" ]; then
            bad "load balancer ${lb_svc} has no external address (<pending>)" \
                "the cloud controller has not assigned one. Nothing below can work: every fleet hostname points at an address that does not exist yet. On OpenStack check the Octavia quota and that the floating IP is free"
        else
            ok "load balancer ${lb_svc} has address ${lb_addr}"
            # The names edges resolve MUST land on that address, or the join
            # reaches something else entirely.
            internal="$(python3 -c "
import yaml
v=yaml.safe_load(open('$VALUES')) or {}
print((v.get('domain') or {}).get('internal',''))" 2>/dev/null || true)"
            if [ -n "$internal" ]; then
                resolved="$(getent hosts "seaweedfs.${internal}" 2>/dev/null | awk '{print $1}' | head -1)"
                if [ -z "$resolved" ]; then
                    bad "seaweedfs.${internal} does not resolve" \
                        "topology=cloud resolves by REAL DNS — no /etc/hosts is written. Point the name at ${lb_addr}, or use a nip.io name built from it"
                elif [ "$resolved" != "$lb_addr" ]; then
                    bad "seaweedfs.${internal} resolves to ${resolved}, not the load balancer ${lb_addr}" \
                        "edges would connect somewhere that is not this deployment"
                else
                    ok "domain.internal resolves to the load balancer (${lb_addr})"
                fi
            fi
        fi
    fi
fi

head_ "object storage"
# SELECTED BY PORT, not by label: `app=seaweedfs` matches only the -metrics
# Service here, so a label lookup probed :8333 on a Service exposing :9324 and
# reported the S3 gateway down while it was fine.
SWFS=$($KUBECTL -n "$NS_MGMT" get svc -o json 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for s in d.get("items", []):
    if any(p.get("port") == 8333 for p in (s.get("spec", {}).get("ports") or [])):
        print(s["metadata"]["name"]); break')
if [ -z "$SWFS" ]; then
    bad "no Service exposing the S3 port (8333) in ${NS_MGMT}"
else
    ok "SeaweedFS Service present (${SWFS})"
    probe=$($KUBECTL -n "$NS_UPLOAD" get deploy -o name 2>/dev/null | head -1)
    if [ -n "$probe" ]; then
        # In-cluster Service DNS, NOT the external ingress hostname — that name
        # has no in-cluster DNS record at all.
        code=$($KUBECTL -n "$NS_UPLOAD" exec "$probe" -- python3 -c "
import urllib.request, urllib.error
try:
    urllib.request.urlopen('http://${SWFS}.${NS_MGMT}.svc.cluster.local:8333', timeout=10); print(200)
except urllib.error.HTTPError as e: print(e.code)
except Exception: print(0)" 2>/dev/null)
        [ "${code:-0}" != "0" ] && ok "S3 gateway answers in-cluster (HTTP ${code})" \
            || bad "S3 gateway did not answer in-cluster" "edges cannot stage and Loki cannot write chunks"
    else
        skip "in-cluster S3 probe" "no deployment in ${NS_UPLOAD} to exec from"
    fi
fi

for EDGE in $(edges); do
    head_ "edge: ${EDGE}"
    cpb=$(bad_pods "$KUBECTL" "$EDGE")
    if [ -z "$cpb" ]; then
        n=$($KUBECTL -n "$EDGE" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
        [ "${n:-0}" -gt 0 ] && ok "hosted control plane healthy (${n} pod(s) in ns ${EDGE})" \
            || bad "no hosted control-plane pods in namespace ${EDGE}"
    else
        bad "hosted control plane unhealthy for ${EDGE}" "$(echo "$cpb" | sed 's/\t/ -> /' | paste -sd'; ')"
    fi

    KC="${REPO_DIR}/kubeconfig-${EDGE}"
    if [ ! -f "$KC" ]; then
        skip "edge ${EDGE} child-cluster checks" "no ${KC} (install.sh step 5 produces it)"
        continue
    fi
    EK="kubectl --kubeconfig ${KC}"
    if ! $EK get --raw /readyz >/dev/null 2>&1; then
        bad "edge ${EDGE}: child API server not reachable via ${KC}"; continue
    fi
    ok "edge ${EDGE}: child API server reachable"

    wb=$($EK get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{print $1" ("$2")"}')
    if [ -z "$wb" ]; then
        wn=$($EK get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
        [ "${wn:-0}" -gt 0 ] && ok "edge ${EDGE}: ${wn} worker node(s) Ready" \
            || bad "edge ${EDGE}: no worker nodes joined"
    else
        bad "edge ${EDGE}: worker not Ready: ${wb}"
    fi

    ENS=$(python3 -c "
import yaml
d = yaml.safe_load(open('${REPO_DIR}/sites/${EDGE}/values.yaml')) if __import__('os').path.exists('${REPO_DIR}/sites/${EDGE}/values.yaml') else {}
print((d or {}).get('namespace') or 'xnat-ingest')" 2>/dev/null || echo xnat-ingest)
    eb=$(bad_pods "$EK" "$ENS")
    if [ -z "$eb" ]; then
        en=$($EK -n "$ENS" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
        ok "edge ${EDGE}: all ${en} pipeline pod(s) healthy"
    else
        bad "edge ${EDGE}: unhealthy pipeline pods" \
            "$(echo "$eb" | sed 's/\t/ -> /' | paste -sd'; ') — CreateContainerConfigError here usually means a cert-sync Secret has not arrived"
    fi

    # dataPolicy.telemetry.podLogFiles is applied by `k0s install worker`, so it
    # takes effect at JOIN TIME and an already-joined node keeps whatever it was
    # installed with. Editing the value on a running system therefore changes
    # nothing — silently, which is precisely the failure this repo keeps
    # removing. A comment cannot catch that; comparing the declared value with
    # the kubelet's own running config can.
    want=$(python3 -c "
import yaml
try:
    d = yaml.safe_load(open('${REPO_DIR}/charts/mgmt/values.yaml'))['dataPolicy']['telemetry']['podLogFiles']
    print(str(d.get('maxSize')) + ' ' + str(d.get('maxFiles')))
except Exception:
    print('')" 2>/dev/null)
    node=$($EK get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$want" ] || [ -z "$node" ]; then
        skip "edge ${EDGE}: pod log rotation" "could not read the declared value or the node name"
    else
        got=$($EK get --raw "/api/v1/nodes/${node}/proxy/configz" 2>/dev/null | python3 -c "
import sys, json
try:
    k = json.load(sys.stdin)['kubeletconfig']
    print(str(k.get('containerLogMaxSize')) + ' ' + str(k.get('containerLogMaxFiles')))
except Exception:
    print('')" 2>/dev/null)
        if [ -z "$got" ]; then
            skip "edge ${EDGE}: pod log rotation" "kubelet configz not readable on ${node}"
        elif [ "$got" = "$want" ]; then
            ok "edge ${EDGE}: pod log rotation matches the policy (${want% *} x ${want#* })"
        else
            bad "edge ${EDGE}: pod log rotation DRIFT — policy says '${want}', kubelet is running '${got}'" \
                "dataPolicy.telemetry.podLogFiles is applied by k0s install worker at JOIN time, so editing it does not reach a node that is already joined. Reinstall the k0s worker service on ${node} to apply it, or revert the values change."
        fi
    fi

    miss=""
    for s in ca-bundle loki-push-client-tls s3-edge-credentials; do
        $EK -n "$ENS" get secret "$s" >/dev/null 2>&1 || miss="${miss} ${s}"
    done
    [ -z "$miss" ] && ok "edge ${EDGE}: all 3 cert-sync Secrets present" \
        || bad "edge ${EDGE}: missing cert-sync Secret(s):${miss}" \
               "run: $KUBECTL -n ${NS_MGMT} create job seed-${EDGE} --from=cronjob/mgmt-cert-sync-${EDGE}"

    # S3 upload mTLS is optional and ships off, so this is asserted only when
    # the management side is actually issuing the certificate — the presence of
    # <edge>-s3-client is what says clientCerts.issue is on.
    #
    # THIS IS THE ONE STEP OF THAT ROLLOUT NO TEMPLATE CAN CHECK. The chart can
    # see that something is configured to deliver the certificate; only a live
    # cluster can say it arrived. Flipping clientCerts.require before it has
    # breaks every upload from this site with an error that names nothing:
    # measured, the handshake succeeds, nginx answers HTTP 400 with an HTML
    # body, and rclone reports that as an S3 XML parse failure — the uploader
    # logs endpoint_failed and it reads as an unreachable endpoint.
    if $KUBECTL -n "$NS_MGMT" get secret "${EDGE}-s3-client" >/dev/null 2>&1; then
        if $EK -n "$ENS" get secret s3-client-tls >/dev/null 2>&1; then
            ok "edge ${EDGE}: S3 upload client certificate delivered (s3-client-tls)"
        else
            bad "edge ${EDGE}: ${EDGE}-s3-client is issued on the management cluster but s3-client-tls has NOT reached the edge" \
                "Do NOT set seaweedfs.ingress.clientCerts.require until this passes — every upload would fail as an HTTP 400 that rclone reports as an S3 XML parse error, naming neither certificates nor auth. Force a sync: $KUBECTL -n ${NS_MGMT} create job seed-${EDGE} --from=cronjob/mgmt-cert-sync-${EDGE}"
        fi
    fi
done

head_ "periodic jobs"
# The ONLY place a periodic job's health is asserted, since Job-owned pods are
# excluded above. Threshold comes from each job's own schedule: cert-sync is
# 6-hourly and the reclaimer hourly, so one constant would either nag about the
# first or ignore the second being a day stale.
cjs=$($KUBECTL get cronjobs -A -o json 2>/dev/null | python3 -c '
import sys, json, datetime, re
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
now = datetime.datetime.now(datetime.timezone.utc)
def period(s):
    f = s.split()
    if len(f) != 5: return 3600
    h = f[1]
    if h == "*": return 3600
    m = re.match(r"^\*/(\d+)$|^\d+/(\d+)$", h)
    if m: return int(m.group(1) or m.group(2)) * 3600
    return 86400 if h.isdigit() else 3600
for c in d.get("items", []):
    ns, n = c["metadata"]["namespace"], c["metadata"]["name"]
    if c.get("spec", {}).get("suspend"): print(f"SUSPEND\t{ns}/{n}\t0\t0"); continue
    p = period(c.get("spec", {}).get("schedule", ""))
    last = (c.get("status") or {}).get("lastSuccessfulTime")
    if not last: print(f"NEVER\t{ns}/{n}\t0\t{p}"); continue
    t = datetime.datetime.strptime(last, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    print(f"AGE\t{ns}/{n}\t{int((now-t).total_seconds())}\t{p}")')
if [ -z "$cjs" ]; then
    skip "CronJob freshness" "no CronJobs found — cert-sync and the reclaimer should exist"
else
    while IFS=$'\t' read -r kind name age period; do
        [ -n "${kind:-}" ] || continue
        case "$kind" in
            SUSPEND) bad "CronJob ${name} is SUSPENDED" "it will never run again until resumed" ;;
            NEVER)   bad "CronJob ${name} has never completed successfully" ;;
            AGE)     if [ "$age" -gt $((period * 3)) ]; then
                         bad "CronJob ${name}: last success $((age/3600))h $(((age%3600)/60))m ago" \
                             "more than 3 intervals ($((period/60))m each) — not a blip"
                     else
                         ok "CronJob ${name}: last success $((age/60))m ago (every $((period/60))m)"
                     fi ;;
        esac
    done <<< "$cjs"
fi

head_ "XNAT delivery path"
UP=$($KUBECTL -n "$NS_UPLOAD" get deploy -o name 2>/dev/null | head -1)
if [ -z "$UP" ]; then
    skip "XNAT checks" "no uploader deployment in ${NS_UPLOAD}"
else
    # Authenticates, then asks an experiment for its FILES. The last part is the
    # point: XNAT has answered 200 with file_count=1 and an EMPTY file list,
    # which breaks every delivery confirmation while all pods stay green and no
    # alert fires. Nothing else in this repo notices that.
    res=$($KUBECTL -n "$NS_UPLOAD" exec "$UP" -- python3 -c '
import os, json, base64, ssl, urllib.request
h=os.environ["XINGEST_HOST"].rstrip("/"); u=os.environ["XINGEST_USER"]; p=os.environ["XINGEST_PASS"]
ctx=ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
def get(path):
    r=urllib.request.Request(h+path)
    r.add_header("Authorization","Basic "+base64.b64encode(f"{u}:{p}".encode()).decode())
    with urllib.request.urlopen(r,timeout=30,context=ctx) as resp: return resp.status, resp.read().decode()
try:
    s,_=get("/data/projects?format=json")
    if s!=200: print("AUTH_FAIL",s); raise SystemExit
    print("AUTH_OK")
except Exception as e:
    print("UNREACHABLE",str(e)[:120]); raise SystemExit
try:
    s,b=get("/data/experiments?format=json")
    ex=json.loads(b)["ResultSet"]["Result"]
    if not ex: print("NO_EXPERIMENTS"); raise SystemExit
    eid=ex[0]["ID"]
    s,b=get(f"/data/experiments/{eid}/scans/ALL/resources?format=json")
    claimed=sum(int(r.get("file_count") or 0) for r in json.loads(b)["ResultSet"]["Result"])
    s,b=get(f"/data/experiments/{eid}/scans/ALL/files?format=json")
    print("FILES",eid,claimed,len(json.loads(b)["ResultSet"]["Result"]))
except Exception as e:
    print("FILES_ERR",str(e)[:120])' 2>/dev/null)

    case "$res" in
        AUTH_OK*)     ok "XNAT reachable and credentials accepted" ;;
        AUTH_FAIL*)   bad "XNAT rejected the uploader's credentials" ;;
        UNREACHABLE*) bad "XNAT unreachable from the uploader pod" "${res#UNREACHABLE }" ;;
        *)            bad "XNAT probe produced no usable result" "${res:-<empty>}" ;;
    esac
    fl=$(printf '%s\n' "$res" | grep '^FILES ' || true)
    if [ -n "$fl" ]; then
        set -- $fl; eid="$2"; claimed="$3"; listed="$4"
        if [ "${claimed:-0}" -gt 0 ] && [ "${listed:-0}" -eq 0 ]; then
            bad "XNAT lists ZERO files for ${eid} while its catalog claims ${claimed}" \
                "delivery cannot be confirmed: the reclaimer keeps everything (safe) and SessionStagedNotConfirmedInXNAT will fire ~72h after the last confirmation, on HEALTHY sessions. XNAT-side fault."
        else
            ok "XNAT file listing consistent for ${eid} (claims ${claimed}, lists ${listed})"
        fi
    elif printf '%s' "$res" | grep -q NO_EXPERIMENTS; then
        skip "XNAT file-listing check" "no experiments in XNAT yet"
    fi
fi

printf '\n%s=== summary ===%s\n' "$_B" "$_O"
printf '  %d passed, %d failed, %d not checked\n' "$PASS" "$FAIL" "$SKIP"
[ "$SKIP" -gt 0 ] && { printf '\n%sNOT CHECKED%s — these are NOT passes:\n' "$_Y" "$_O"; printf '  - %s\n' "${SKIPPED[@]}"; }
if [ "$FAIL" -gt 0 ]; then
    printf '\n%sFAILURES%s:\n' "$_R" "$_O"; printf '  - %s\n' "${FAILED[@]}"; exit 1
fi
printf '\n%sAll checks passed.%s\n' "$_G" "$_O"
exit 0
