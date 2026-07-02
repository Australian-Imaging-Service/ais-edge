#!/usr/bin/env bash
# Watches /data/sorted for newly sorted sessions.
# Once data has settled (no new files for UPLOAD_SETTLE_SECONDS), runs xnat-ingest upload.

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [upload] $*"; }

SORTED_DIR=/data/sorted
SETTLE_SECS=${UPLOAD_SETTLE_SECONDS:-600}  # wait this long after last sorted file before uploading
POLL_SECS=${UPLOAD_POLL_SECONDS:-300}      # check interval
LAST_RUN=0                                 # timestamp of last upload, prevents re-uploading same data

mkdir -p /data/sorted /data/tmp /data/LOGS
log "Started. Watching ${SORTED_DIR} (settle=${SETTLE_SECS}s, poll=${POLL_SECS}s)"

while true; do
  newest_ts=$(find "$SORTED_DIR" -type f -printf '%T@\n' 2>/dev/null \
    | sort -n | tail -1 | cut -d. -f1)

  if [[ -n "$newest_ts" ]]; then
    age=$(( $(date +%s) - newest_ts ))
    if [[ $age -ge $SETTLE_SECS && $newest_ts -gt $LAST_RUN ]]; then
      log "Sorted data settled (age=${age}s). Running upload..."
      # UPLOAD DISABLED FOR TESTING — uncomment the block below to enable
      log "[DRY RUN] Upload disabled — would upload ${SORTED_DIR} to ${XINGEST_SERVER} now."
      LAST_RUN=$(date +%s)
      # if xnat-ingest upload \
      #   "$SORTED_DIR" \
      #   "$XINGEST_SERVER" \
      #   --user "$XINGEST_USER" \
      #   --password "$XINGEST_PASSWORD" \
      #   --dont-require-manifest \
      #   --dont-check-checksums \
      #   --logger stream info stdout; then
      #   LAST_RUN=$(date +%s)
      #   log "Upload complete."
      # else
      #   log "Upload failed — will retry next poll."
      # fi
    elif [[ $newest_ts -gt $LAST_RUN ]]; then
      log "Waiting for sorted data to settle (age=${age}s / ${SETTLE_SECS}s)"
    fi
  fi

  log "Watching... (next check in ${POLL_SECS}s)"
  sleep "$POLL_SECS"
done
