#!/usr/bin/env bash
# Pipeline B: filesystem drop dir -> /data/grouped-fs -> /data/assigned
# Walks the export dir one study subdirectory at a time so each group call only
# loads that study's files into memory (the whole-tree glob OOMs the node).

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [fs-pipeline] $*"; }

GROUPED_DIR=/data/grouped-fs
ASSIGNED_DIR=/data/assigned
INTERVAL=${PIPELINE_INTERVAL_SECONDS:-300}

mkdir -p "$GROUPED_DIR" "$ASSIGNED_DIR" /data/LOGS
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
    log "Grouping study: $study"
    if xnat-ingest group \
        "${study_dir}**/*" \
        "$GROUPED_DIR" \
        "${datatype_args[@]}" \
        --wait-period "$WAIT_PERIOD" \
        --copy-mode "$COPY_MODE"; then
      if xnat-ingest assign "$GROUPED_DIR" "$ASSIGNED_DIR" \
          --project "$PROJECT_FIELD" \
          --subject "$SUBJECT_FIELD" \
          --session "$SESSION_FIELD" \
          --scan "$SCAN_FIELD" \
          --copy-mode "$COPY_MODE"; then
        # Flatten: rewrite symlinks that point into grouped-fs to their final
        # resolved target (the real NFS file), while the chain is still intact.
        find "$ASSIGNED_DIR" -lname "$GROUPED_DIR/*" | while IFS= read -r lnk; do
          tgt=$(readlink -f "$lnk")
          if [[ -n "$tgt" && -e "$tgt" ]]; then
            ln -sfn "$tgt" "$lnk"
          else
            log "WARNING: could not resolve $lnk — leaving untouched"
          fi
        done
        rm -rf "$GROUPED_DIR"/* 2>/dev/null
      else
        log "assign failed for $study — will retry next cycle"
      fi
    else
      log "group failed for $study — skipping assign"
    fi
  done

  [[ $found -eq 0 ]] && log "No study directories found under $SOURCE_BASE"
  sleep "$INTERVAL"
done
