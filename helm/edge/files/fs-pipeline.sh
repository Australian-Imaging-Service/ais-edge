#!/usr/bin/env bash
# Pipeline B: filesystem drop dir -> /data/grouped-fs -> /data/assigned
# Walks the export dir one study subdirectory at a time so each group call only
# loads that study's files into memory (the whole-tree glob OOMs the node).

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [fs-pipeline] $*"; }

GROUPED_DIR=/data/grouped-fs
ASSIGNED_DIR=/data/assigned
INTERVAL=${PIPELINE_INTERVAL_SECONDS:-300}

STATE_DIR=/data/LOGS/fs-pipeline-state

mkdir -p "$GROUPED_DIR" "$ASSIGNED_DIR" "$STATE_DIR"
log "Started (interval=${INTERVAL}s)"

study_fingerprint() {
  find "$1" -type f -printf '%P\0%s\0%T@\0' \
    | LC_ALL=C sort -z \
    | sha256sum \
    | cut -d' ' -f1
}

# DATATYPES is a semicolon-separated list expanded to repeated --datatype args.
datatype_args=()
IFS=';' read -ra _dts <<< "$DATATYPES"
for dt in "${_dts[@]}"; do
  [[ -n "$dt" ]] && datatype_args+=(--datatype "$dt")
done

# Strip the trailing /**/* from INPUT_GLOB to get the export base directory.
SOURCE_BASE="${INPUT_GLOB%/\*\*/\*}"

while true; do
  found=0
  for study_dir in "$SOURCE_BASE"/*/; do
    [[ -d "$study_dir" ]] || continue
    found=1
    study=$(basename "$study_dir")
    fingerprint=$(study_fingerprint "$study_dir")
    state_file="$STATE_DIR/$study"

    if [[ -f "$state_file" ]]; then
      if [[ "$(cat "$state_file")" == "$fingerprint" ]]; then
        continue
      fi
      log "WARNING: $study changed after processing — remove $state_file after reviewing existing assigned data"
      continue
    fi

    log "Grouping study: $study"
    xnat-ingest group \
        "${study_dir}**/*" \
        "$GROUPED_DIR" \
        "${datatype_args[@]}" \
        --wait-period "${WAIT_PERIOD:?}" \
        --copy-mode "${COPY_MODE:?}"

    if ! compgen -G "$GROUPED_DIR/_.*" >/dev/null; then
      log "Nothing staged for $study (still transferring?) — will retry"
      continue
    fi

    # Assigned files are hardlinks (export dir and pipeline storage share a
    # disk), so grouped-fs can be cleared as soon as assign succeeds.
    if xnat-ingest assign "$GROUPED_DIR" "$ASSIGNED_DIR" \
        --project "${PROJECT_FIELD:?}" \
        --subject "${SUBJECT_FIELD:?}" \
        --session "${SESSION_FIELD:?}" \
        --scan "${SCAN_FIELD:?}" \
        --copy-mode "$COPY_MODE"; then
      rm -rf "$GROUPED_DIR"/*
      printf '%s\n' "$fingerprint" > "$state_file.tmp"
      mv "$state_file.tmp" "$state_file"
      log "Done: $study"
    else
      log "assign failed for $study — keeping grouped, will retry next cycle"
    fi
  done

  [[ $found -eq 0 ]] && log "No study directories found under $SOURCE_BASE"
  sleep "$INTERVAL"
done
