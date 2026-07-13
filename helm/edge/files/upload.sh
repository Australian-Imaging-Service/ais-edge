#!/usr/bin/env bash
# Uploads assigned sessions to XNAT.
# Loop interval and settle-time controlled by XINGEST_LOOP and XINGEST_WAIT_PERIOD

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [upload] $*"; }

mkdir -p /data/assigned /data/tmp /data/LOGS
log "Started"

while true; do
  # UPLOAD DISABLED FOR TESTING — uncomment the block below to enable
  log "[DISABLED] would run: xnat-ingest upload /data/assigned ${XINGEST_SERVER}"
  # xnat-ingest upload /data/assigned "$XINGEST_SERVER" \
  #   --user "$XINGEST_USER" \
  #   --password "$XINGEST_PASSWORD" \
  #   --always-include "medimage/dicom-series" || log "upload exited with error — restarting in 30s"
  sleep 300
done
