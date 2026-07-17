#!/usr/bin/env bash
# Pipeline B: filesystem drop dir -> /data/grouped-fs -> /data/assigned
# Walks the export dir one study subdirectory at a time so each group call only
# loads that study's files into memory (the whole-tree glob OOMs the node).

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [fs-pipeline] $*"; }

GROUPED_DIR=/data/grouped-fs
ASSIGNED_DIR=/data/assigned
INTERVAL=${PIPELINE_INTERVAL_SECONDS:-300}

DONE_LIST=/data/LOGS/fs-pipeline-done.list

mkdir -p "$GROUPED_DIR" "$ASSIGNED_DIR" /data/LOGS
touch "$DONE_LIST"
log "Started (interval=${INTERVAL}s)"

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
    grep -Fxq "$study" "$DONE_LIST" && continue

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

    xnat-ingest assign "$GROUPED_DIR" "$ASSIGNED_DIR" \
        --project "${PROJECT_FIELD:?}" \
        --subject "${SUBJECT_FIELD:?}" \
        --session "${SESSION_FIELD:?}" \
        --scan "${SCAN_FIELD:?}" \
        --copy-mode "$COPY_MODE"

    # Assigned files are symlinks into grouped-fs, which in turn symlink to
    # the NFS source. Flatten them to point directly at the real files while
    # the chain is still intact, so grouped-fs can be cleared without dangling
    # anything.
    find "$ASSIGNED_DIR" -lname "$GROUPED_DIR/*" | while IFS= read -r lnk; do
      tgt=$(readlink -f "$lnk")
      if [[ -n "$tgt" && -e "$tgt" ]]; then
        ln -sfn "$tgt" "$lnk"
      else
        log "WARNING: could not resolve $lnk — leaving untouched"
      fi
    done

    if find "$ASSIGNED_DIR" -lname "$GROUPED_DIR/*" | grep -q .; then
      log "Unresolved links still point into grouped — keeping grouped for $study"
    else
      rm -rf "$GROUPED_DIR"/*
      echo "$study" >> "$DONE_LIST"
      log "Done: $study"
    fi
  done

  [[ $found -eq 0 ]] && log "No study directories found under $SOURCE_BASE"
  sleep "$INTERVAL"
done
