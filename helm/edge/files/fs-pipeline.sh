#!/usr/bin/env bash
# Pipeline B: filesystem drop dir -> /data/grouped-fs -> /data/assigned

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [fs-pipeline] $*"; }

GROUPED_DIR=/data/grouped-fs
ASSIGNED_DIR=/data/assigned
INTERVAL=${PIPELINE_INTERVAL_SECONDS:-300}

mkdir -p "$GROUPED_DIR" "$ASSIGNED_DIR" /data/LOGS
log "Started (interval=${INTERVAL}s, input=${INPUT_GLOB})"

# DATATYPES is a semicolon-separated list (DICOM plus the Siemens PET raw
# types) expanded to repeated --datatype args.
datatype_args=()
IFS=';' read -ra _dts <<< "$DATATYPES"
for dt in "${_dts[@]}"; do
  [[ -n "$dt" ]] && datatype_args+=(--datatype "$dt")
done

while true; do
  if xnat-ingest group \
      "$INPUT_GLOB" \
      "$GROUPED_DIR" \
      "${datatype_args[@]}" \
      --wait-period "$WAIT_PERIOD" \
      --copy-mode "$COPY_MODE"; then
    xnat-ingest assign "$GROUPED_DIR" "$ASSIGNED_DIR" \
      --project "$PROJECT_FIELD" \
      --subject "$SUBJECT_FIELD" \
      --session "$SESSION_FIELD" \
      --scan "$SCAN_FIELD" \
      --copy-mode "$COPY_MODE" \
      --unlink-source all \
      || log "assign failed — will retry next cycle"
  else
    log "group failed — skipping assign this cycle"
  fi

  sleep "$INTERVAL"
done
