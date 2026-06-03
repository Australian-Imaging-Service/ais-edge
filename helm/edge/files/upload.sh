#!/usr/bin/env bash
# Watches /data/sorted for sessions produced by the sort pod.
# Once data has settled (no new files for UPLOAD_SETTLE_SECONDS), runs xnat-ingest upload.
# Credentials injected via XINGEST_SERVER / XINGEST_USER / XINGEST_PASSWORD env vars.

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [upload] $*"; }

WATCH_DIR=/data/sorted
SETTLE_SECS=${UPLOAD_SETTLE_SECONDS:-1800}  # wait this long after last new file before uploading
POLL_SECS=${UPLOAD_POLL_SECONDS:-300}       # check interval
LAST_RUN=0                                  # timestamp of last upload, prevents re-uploading same data

mkdir -p /data/sorted /data/tmp /data/LOGS
log "Started (settle=${SETTLE_SECS}s, poll=${POLL_SECS}s)"

while true; do
  # Find the newest file in sorted sessions; skip xnat-ingest work dirs (__build__, __invalid__, etc.)
  newest_ts=$(find "$WATCH_DIR" -mindepth 2 -type f -not -path '*/__*/*' -printf '%T@\n' 2>/dev/null \
    | sort -n | tail -1 | cut -d. -f1)

  if [[ -n "$newest_ts" ]]; then
    age=$(( $(date +%s) - newest_ts ))
    if [[ $age -ge $SETTLE_SECS && $newest_ts -gt $LAST_RUN ]]; then
      log "Sorted data settled (age=${age}s). Running upload..."
      if xnat-ingest upload /data/sorted "$XINGEST_SERVER" \
        --user "$XINGEST_USER" \
        --password "$XINGEST_PASSWORD" \
        --dont-require-manifest \
        --dont-check-checksums \
        --always-include "medimage/dicom-series" \
        --raise-errors; then
        LAST_RUN=$(date +%s)
        log "Upload complete."
      else
        log "Upload failed — will retry next poll."
      fi
    elif [[ $newest_ts -gt $LAST_RUN ]]; then
      log "Waiting for sorted data to settle (age=${age}s / ${SETTLE_SECS}s)"
    fi
  fi

  log "Watching... (next check in ${POLL_SECS}s)"
  sleep "$POLL_SECS"
done
