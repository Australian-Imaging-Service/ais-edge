#!/usr/bin/env bash
# Syncs assigned sessions to an S3 staging bucket.

log() { echo "[$(date '+%F %T')] [s3sync] $*" | tee -a /data/LOGS/s3sync.log; }

ASSIGNED_DIR=/data/assigned
STATE_DIR=/data/LOGS/s3sync-state
INTERVAL=${SYNC_INTERVAL_SECONDS:-300}
SETTLE_MINUTES=${SETTLE_MINUTES:-5}
: "${S3_DEST:?S3_DEST env var required}"

mkdir -p "$STATE_DIR" /data/LOGS
log "Started (dest=$S3_DEST, interval=${INTERVAL}s)"

while true; do
  for d in "$ASSIGNED_DIR"/*/; do
    [[ -d "$d" ]] || continue
    session=$(basename "$d")
    [[ "$session" == __* ]] && continue   # skip __invalid__ etc.

    # settle guard: assign may still be writing this session
    if find -L "$d" -mmin -"$SETTLE_MINUTES" -print -quit 2>/dev/null | grep -q .; then
      continue
    fi

    # fingerprint of content, resolved through symlinks
    fp=$(find -L "$d" -type f -printf '%P %s %T@\n' 2>/dev/null | sort | md5sum | cut -d' ' -f1)
    [[ -f "$STATE_DIR/$session" && "$(cat "$STATE_DIR/$session")" == "$fp" ]] && continue

    # never upload a session whose symlink targets are gone
    # (fs sessions symlink to the export share — source archived too early?)
    if find "$d" -xtype l -print -quit | grep -q .; then
      log "FAIL $session — dangling symlinks (source removed before sync?)"
      continue
    fi

    log "SYNC $session"
    if aws s3 sync "$d" "$S3_DEST/$session" --only-show-errors >>/data/LOGS/s3sync.log 2>&1; then
      echo "$fp" > "$STATE_DIR/$session"
      log "DONE $session"
    else
      log "FAIL $session — sync exited nonzero, will retry next cycle"
    fi
  done
  sleep "$INTERVAL"
done
