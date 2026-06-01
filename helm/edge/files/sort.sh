#!/usr/bin/env bash
# Watches /data/orthanc-storage for new DICOM files.
# Once data has settled (no new files for SORT_SETTLE_SECONDS), runs xnat-ingest sort.

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [sort] $*"; }

WATCH_DIR=/data/orthanc-storage
SETTLE_SECS=${SORT_SETTLE_SECONDS:-1800}  # wait this long after last new file before sorting
POLL_SECS=${SORT_POLL_SECONDS:-300}       # check interval
LAST_RUN=0                                # timestamp of last sort, prevents re-sorting same data

mkdir -p /data/sorted /data/LOGS
log "Started (settle=${SETTLE_SECS}s, poll=${POLL_SECS}s)"

while true; do
  # Find the newest file written by Orthanc (UUID-named files in 2-level hex dirs)
  newest_ts=$(find "$WATCH_DIR" -type f -printf '%T@\n' 2>/dev/null \
    | sort -n | tail -1 | cut -d. -f1)

  if [[ -n "$newest_ts" ]]; then
    age=$(( $(date +%s) - newest_ts ))
    if [[ $age -ge $SETTLE_SECS && $newest_ts -gt $LAST_RUN ]]; then
      log "Data settled (age=${age}s). Running sort..."
      xnat-ingest sort \
        /data/orthanc-storage \
        /data/sorted \
        --collate-resources "medimage/dicom-series" siblings \
        --recursive \
        --logger stream info stdout \
        || true  # don't exit loop on sort failure
      LAST_RUN=$(date +%s)
      log "Sort complete."
    elif [[ $newest_ts -gt $LAST_RUN ]]; then
      log "Waiting for data to settle (age=${age}s / ${SETTLE_SECS}s)"
    fi
  fi

  log "Watching... (next check in ${POLL_SECS}s)"
  sleep "$POLL_SECS"
done
