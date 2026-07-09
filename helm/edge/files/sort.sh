#!/usr/bin/env bash
# Watches SORT_WATCH_DIR for new files.
# Once data has settled (no new files for SORT_SETTLE_SECONDS), runs xnat-ingest sort.

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [sort:${SORT_POD_NAME:-sort}] $*"; }

WATCH_DIR=${SORT_WATCH_DIR:-/data/orthanc-storage}
SETTLE_SECS=${SORT_SETTLE_SECONDS:-1800}  # wait this long after last new file before sorting
POLL_SECS=${SORT_POLL_SECONDS:-300}       # check interval
LAST_RUN=0                                # timestamp of last sort, prevents re-sorting same data

mkdir -p /data/sorted /data/LOGS
log "Started. Watching ${WATCH_DIR} (settle=${SETTLE_SECS}s, poll=${POLL_SECS}s)"

while true; do
  newest_ts=$(find "$WATCH_DIR" -type f -printf '%T@\n' 2>/dev/null \
    | sort -n | tail -1 | cut -d. -f1)

  if [[ -n "$newest_ts" ]]; then
    age=$(( $(date +%s) - newest_ts ))
    if [[ $age -ge $SETTLE_SECS && $newest_ts -gt $LAST_RUN ]]; then
      log "Data settled (age=${age}s). Running sort..."
      collate_args=()
      if [[ -n "${SORT_COLLATE_RESOURCES:-}" ]]; then
        read -r collate_type collate_method <<< "$SORT_COLLATE_RESOURCES"
        collate_args=(--collate-resources "$collate_type" "$collate_method")
      fi
      # No --raise-errors: sessions that fail (e.g. a scan already staged from
      # another source) are logged and skipped so the rest still get sorted.
      # No --logger flag: logging comes from XINGEST_LOGGERS, which writes to
      # stdout AND a persistent file under /data/LOGS/.
      sort_output=$(mktemp)
      xnat-ingest sort \
        "$WATCH_DIR" \
        /data/sorted \
        "${collate_args[@]}" \
        --recursive \
        2>&1 | tee "$sort_output"
      sort_status=${PIPESTATUS[0]}
      skipped=$(grep -c "due to error in sorting" "$sort_output" || true)
      rm -f "$sort_output"
      if [[ $sort_status -eq 0 ]]; then
        LAST_RUN=$(date +%s)
        if [[ $skipped -gt 0 ]]; then
          log "WARNING: sort finished but $skipped session(s) were SKIPPED due to errors — details in /data/LOGS/"
        else
          log "Sort complete."
        fi
      else
        log "Sort failed — will retry next poll."
      fi
    elif [[ $newest_ts -gt $LAST_RUN ]]; then
      log "Waiting for data to settle (age=${age}s / ${SETTLE_SECS}s)"
    fi
  fi

  log "Watching... (next check in ${POLL_SECS}s)"
  sleep "$POLL_SECS"
done
