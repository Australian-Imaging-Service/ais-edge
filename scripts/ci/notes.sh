#!/usr/bin/env bash
# =============================================================================
# NOTES.txt claims
# =============================================================================
# `helm template` never renders NOTES.txt, so no other stage reads the text an
# operator sees after an install. Defects there lasted for months: Loki secret
# lines with an empty name, a dry-run text that did not say that stages still
# remove their own input, and an uninstall list without the StorageClass.
#
# This stage renders NOTES.txt offline (wrapped in a named template, shown with
# --show-only) for a few value sets, and checks one claim per line. A check
# that says "absent" guards against text that must not print in that case.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/ci/lib.sh
. "$HERE/lib.sh"

# shellcheck source=scripts/ci/values.sh
. "$HERE/values.sh" >/dev/null
HELM="$(ci_helm)"
ci_heading "NOTES.txt (edge chart)"

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
cp -r "$REPO_ROOT/charts/edge" "$W/edge"
{
  echo '{{- define "ci.notes" -}}'
  cat "$W/edge/templates/NOTES.txt"
  echo '{{- end -}}'
  printf '%s\n' 'apiVersion: v1' 'kind: ConfigMap' 'metadata: {name: ci-notes}' \
    'data:' '  notes: |' '{{ include "ci.notes" . | indent 4 }}'
} >"$W/edge/templates/ci-notes.yaml"

BASE=(-f "$CI_VALUES_DIR/edge-base.yaml")

# render <case> [helm args...]
render() {
  local c="$1"
  shift
  if ! "$HELM" template edge "$W/edge" -n xnat-ingest "${BASE[@]}" "$@" \
    --show-only templates/ci-notes.yaml 2>"$W/$c.err" |
    python3 -c 'import sys, yaml; print(yaml.safe_load(sys.stdin)["data"]["notes"])' \
      >"$W/$c"; then
    ci_fail "$c: NOTES.txt did not render: $(head -c 300 "$W/$c.err")"
    return 1
  fi
}

# expect <case> present|absent <regex> <claim>
expect() {
  local got=absent
  if grep -qE "$3" "$W/$1"; then got=present; fi
  if [ "$got" = "$2" ]; then
    ci_pass "$1: $4"
  else
    ci_fail "$1: $4 (expected $2, found $got)"
  fi
}

if render default; then
  expect default present 'StorageClass hostpath-pipeline is kept' "the kept StorageClass is named"
  expect default absent 'FACILITY BACKUP IS OFF' "no backup warning while the backup is on"
  expect default present 'assign still removes /data/grouped' "the grouped hand-off is named, whatever the policy says"
fi
# A site without Loki mTLS clears both names, as tier-1's example site does.
if render observability --set observability.enabled=true \
  --set observability.loki.clientCertSecret= --set observability.loki.caBundleSecret=; then
  expect observability absent '^ +keys: tls\.crt' "no Loki client line with an empty secret name"
  expect observability absent '^ +key: (ca\.crt|$)' "no CA line with an empty secret name"
fi
if render dry-run --set dataPolicy.enabled=true --set dataPolicy.dryRun=true; then
  expect dry-run present 'govern the data policy and the reclaimers' \
    "dry run says what it does not govern"
fi
if render grouped-never --set dataPolicy.derived.grouped.reclaim=never; then
  expect grouped-never absent 'assign still removes /data/grouped' "no hand-off note when assign keeps its input"
fi
if render backup-off --set deid.engine=none --set storage.facilityBackup.enabled=false \
  --set dataPolicy.enabled=true; then
  expect backup-off present 'FACILITY BACKUP IS OFF' "a site without the backup is warned"
  expect backup-off present 'orthancStorage.reclaim is onGrouped' "the Orthanc deletion is named when it is configured"
fi
if render loki-secrets --set observability.enabled=true \
  --set observability.loki.clientCertSecret=loki-client \
  --set observability.loki.caBundleSecret=loki-ca; then
  expect loki-secrets present '^ +loki-client +keys: tls\.crt, tls\.key' "the Loki client secret is named"
  expect loki-secrets present '^ +loki-ca +key: ca\.crt' "the Loki CA secret is named"
fi
if render no-storageclass --set storage.storageClass.create=false; then
  expect no-storageclass absent 'StorageClass .* is kept' "no StorageClass line when the chart does not create it"
fi

ci_summary "notes"
