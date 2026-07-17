#!/usr/bin/env bash
# Uploads assigned sessions to XNAT.
# xnat-ingest loops internally (XINGEST_LOOP / XINGEST_WAIT_PERIOD); the bash
# loop only restarts it if it crashes.

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [upload] $*"; }

mkdir -p /data/assigned /data/tmp /data/LOGS
log "Started (server=${XINGEST_SERVER})"

while true; do
  xnat-ingest upload /data/assigned "$XINGEST_SERVER" \
    --user "$XINGEST_USER" \
    --password "$XINGEST_PASSWORD" \
    || log "upload exited with error — restarting in 60s"
  sleep 60
done
