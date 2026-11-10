#!/usr/bin/env bash
# =============================================================================
# requeue-invalid.sh: requeue a session that the label stage saved in
# /data/assigned/__invalid__, after a person found the missing label value.
# =============================================================================
#   scripts/requeue-invalid.sh [--kubeconfig FILE] [--namespace NS] list
#   scripts/requeue-invalid.sh [...] show <folder>
#   scripts/requeue-invalid.sh [...] requeue <folder> --session <value>
#                                   [--subject <value>] [--project <value>]
#                                   [--allow-existing]
#
# Tier-2: run it on the management node with the edge's kubeconfig
# (--kubeconfig kubeconfig-<edge>). Tier-1: run it on the node.
#
# The steps (docs/components/accessionflow.md, "Recovering an invalid
# session"):
#   1. InvalidSessionAssigned fires.
#   2. `list` shows what waits in __invalid__ and which label is missing.
#      `show <folder>` prints the study details to look the value up with.
#   3. A PERSON finds the correct value in the hospital's records. The script
#      never guesses it.
#   4. `requeue <folder> --session <value>` checks the value and the
#      folders, moves the session back under the label stage's lock, and
#      writes an audit line (LOGS/requeue-audit.jsonl on the edge).
#   5. Watch the uploader log for the session, then check it in XNAT.
#
# It runs the tool that the chart ships into the label (assign) pod
# (/opt/ais-edge/requeue-invalid.py, from charts/edge/files), where the
# pipeline is mounted at /data. Without this repository, run the same tool
# with kubectl only:
#   kubectl -n <ns> exec deploy/<release>-assign -c assign -- \
#     python3 /opt/ais-edge/requeue-invalid.py --operator <you> list
# Nothing is edited: not the metadata, not the DICOM headers. The labels come
# from the folder name.
set -uo pipefail
KUBECTL=(kubectl)
NS=xnat-ingest
while [ $# -gt 0 ]; do
    case "$1" in
        --kubeconfig) KUBECTL+=(--kubeconfig "$2"); shift 2 ;;
        --namespace|-n) NS="$2"; shift 2 ;;
        -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
        *) break ;;
    esac
done
[ $# -ge 1 ] || { sed -n '5,10p' "$0" >&2; exit 2; }

pod=$("${KUBECTL[@]}" -n "$NS" get pods -l component=assign \
      --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$pod" ]; then
    echo "requeue-invalid: no running label (assign) pod in namespace $NS. Check the kubeconfig and the namespace." >&2
    exit 2
fi
if ! "${KUBECTL[@]}" -n "$NS" exec "$pod" -c assign -- test -f /opt/ais-edge/requeue-invalid.py 2>/dev/null; then
    echo "requeue-invalid: $pod has no /opt/ais-edge/requeue-invalid.py. The edge chart is older than the tool: upgrade the edge release." >&2
    exit 2
fi
operator="${USER:-unknown}@$(hostname 2>/dev/null || echo unknown)"
exec "${KUBECTL[@]}" -n "$NS" exec "$pod" -c assign -- \
    python3 /opt/ais-edge/requeue-invalid.py --root /data --operator "$operator" "$@"
