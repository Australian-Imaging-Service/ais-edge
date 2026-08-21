#!/usr/bin/env bash
# File-drop ingest, ONE STUDY SUBDIRECTORY AT A TIME.

set -u

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [fs-walker] $*"; }

GROUPED_DIR=${GROUPED_DIR:-/data/grouped-fs}
ASSIGNED_DIR=${ASSIGNED_DIR:-/data/assigned}
INTERVAL=${INTERVAL:-300}
DONE_LIST=${DONE_LIST:-/data/LOGS/fs-pipeline-done.list}

mkdir -p "$GROUPED_DIR" "$ASSIGNED_DIR" "$(dirname "$DONE_LIST")"
touch "$DONE_LIST"
log "Started (interval=${INTERVAL}s, glob=${INPUT_GLOB:?}, done-list=$DONE_LIST)"

datatype_args=()
IFS=';' read -ra _dts <<< "${DATATYPES:-}"
for dt in "${_dts[@]}"; do
  [[ -n "$dt" ]] && datatype_args+=(--datatype "$dt")
done

# Optional --scan override; empty means xnat-ingest's default.
scan_args=()
[[ -n "${SCAN_FIELD:-}" ]] && scan_args=(--scan "$SCAN_FIELD")

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

    if ! compgen -G "$GROUPED_DIR/*" >/dev/null; then
      log "Nothing staged for $study (still transferring?) — will retry"
      continue
    fi

    if xnat-ingest assign "$GROUPED_DIR" "$ASSIGNED_DIR" \
        --project "${PROJECT_FIELD:?}" \
        --subject "${SUBJECT_FIELD:?}" \
        --session "${SESSION_FIELD:?}" \
        "${scan_args[@]}" \
        --copy-mode "$COPY_MODE"; then

      # With copy-mode symlink_or_copy the assigned files are symlinks into
      # grouped staging, which in turn symlink to the export share. Flatten
      # them to point directly at the real files while the chain is still
      # intact, so grouped staging can be cleared without dangling anything.
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
    else
      log "assign failed for $study — clearing staged data, will retry next cycle"
      rm -rf "$GROUPED_DIR"/*
    fi
  done

  [[ $found -eq 0 ]] && log "No study directories found under $SOURCE_BASE"
  sleep "$INTERVAL"
done
