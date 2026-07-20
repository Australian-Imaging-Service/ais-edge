#!/usr/bin/env bash
# Pipeline A: Orthanc -> /data/grouped-orthanc -> /data/assigned

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [orthanc-pipeline] $*"; }

GROUPED_DIR=/data/grouped-orthanc
ASSIGNED_DIR=/data/assigned
INTERVAL=${PIPELINE_INTERVAL_SECONDS:-300}

mkdir -p "$GROUPED_DIR" "$ASSIGNED_DIR" /data/LOGS
log "Started (interval=${INTERVAL}s)"

while true; do
  if xnat-ingest group-orthanc \
      "$ORTHANC_URL" \
      "$ORTHANC_STORE_DIR" \
      "$GROUPED_DIR" \
      "$ORTHANC_USER" \
      "$ORTHANC_PASSWORD" \
      --processed-label "$PROCESSED_LABEL" \
      --copy-mode "$COPY_MODE"; then
    # only assign once group-orthanc has fully finished writing
    xnat-ingest assign "$GROUPED_DIR" "$ASSIGNED_DIR" \
      --project "$PROJECT_FIELD" \
      --subject "$SUBJECT_FIELD" \
      --session "$SESSION_FIELD" \
      --scan "$SCAN_FIELD" \
      --copy-mode "$COPY_MODE" \
      --unlink-source all \
      || log "assign failed — will retry next cycle"
  else
    log "group-orthanc failed — skipping assign this cycle"
  fi

  sleep "$INTERVAL"
done
