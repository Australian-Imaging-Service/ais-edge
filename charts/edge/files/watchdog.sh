#!/bin/sh
# Pipeline watchdog: evaluates end-to-end health from signals that already
# exist on disk and in Orthanc, and posts to a Discord webhook ON STATE
# CHANGE only
#
# Checks:
#   disk       pipeline volume usage over DISK_PERCENT
#   orthanc    Orthanc REST reachable
#   pending    assigned sessions quiet > PENDING_HOURS with no upload marker
#              (uploader failing/stalled — covers S3, creds, proxy, settle)
#   grouped    trees stuck in grouped dirs > GROUPED_STUCK_HOURS
#              (assign failing/stalled)
#
# State lives in $WATCHDOG_STATE_DIR (pipeline volume, survives restarts):
#   last/<check>      the previous state+detail of each check
#   announced-synced  sessions whose S3 arrival has been posted
#   announced-invalid __invalid__ entries already posted
#   heartbeat         date of the last daily summary, when HEARTBEAT_HOUR is set

set -u

ASSIGNED_DIR="${ASSIGNED_DIR:-/data/assigned}"
GROUPED_DIRS="${GROUPED_DIRS:-/data/grouped /data/grouped-fs}"
UPLOAD_STATE_DIR="${UPLOAD_STATE_DIR:-/data/LOGS/s3-uploader-state}"
UPLOAD_EVENT_DIR="${UPLOAD_EVENT_DIR:-${UPLOAD_STATE_DIR}/events}"
WATCHDOG_STATE_DIR="${WATCHDOG_STATE_DIR:-/data/LOGS/watchdog-state}"
DISK_PERCENT="${DISK_PERCENT:-85}"
PENDING_HOURS="${PENDING_HOURS:-6}"
GROUPED_STUCK_HOURS="${GROUPED_STUCK_HOURS:-6}"
HEARTBEAT_HOUR="${HEARTBEAT_HOUR:-}"
EDGE_NAME="${EDGE_NAME:-edge}"
: "${WEBHOOK_URL:?WEBHOOK_URL must be set}"

# Without a writable state dir the transition-only logic has no memory and
# every run re-alerts — spam, not monitoring. Fail loudly instead.
if ! mkdir -p "$WATCHDOG_STATE_DIR/last" || ! touch "$WATCHDOG_STATE_DIR/.rw-probe" 2>/dev/null; then
    echo "[watchdog] FATAL: state dir $WATCHDOG_STATE_DIR is not writable (check volume permissions / runAsUser)" >&2
    exit 1
fi
rm -f "$WATCHDOG_STATE_DIR/.rw-probe"

log() { echo "[watchdog] $*"; }

# ---------------------------------------------------------------------------
# Discord. content is plain text; escape the two characters JSON cares about.
# ---------------------------------------------------------------------------
notify() {
    _msg=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}')
    if ! curl -fsS -m 30 -H 'Content-Type: application/json' \
         -d "{\"content\":\"${_msg}\"}" "$WEBHOOK_URL" -o /dev/null; then
        log "ERROR: webhook POST failed"
        WEBHOOK_FAILED=1
    fi
}
WEBHOOK_FAILED=0

# ---------------------------------------------------------------------------
# Checks. Each sets: state (OK|ALERT) and detail (one line).
# ---------------------------------------------------------------------------

check_disk() {
    pct=$(df -P /data 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')
    if [ -z "$pct" ]; then
        state=ALERT; detail="df failed on /data"
    elif [ "$pct" -ge "$DISK_PERCENT" ]; then
        state=ALERT; detail="pipeline volume at ${pct}% (threshold ${DISK_PERCENT}%)"
    else
        state=OK; detail="pipeline volume at ${pct}%"
    fi
}

check_orthanc() {
    if [ -z "${ORTHANC_URL:-}" ]; then
        state=OK; detail="no ORTHANC_URL configured — skipped"
    elif curl -fsS -m 15 ${ORTHANC_USER:+-u "$ORTHANC_USER:$ORTHANC_PASSWORD"} \
             "$ORTHANC_URL/system" >/dev/null 2>&1; then
        state=OK; detail="Orthanc REST reachable"
    else
        state=ALERT; detail="Orthanc REST unreachable at $ORTHANC_URL"
    fi
}

check_pending() {
    stuck=""
    n=0
    for d in "$ASSIGNED_DIR"/*/; do
        [ -d "$d" ] || continue
        s=$(basename "$d")
        case "$s" in __*|'*') continue ;; esac
        # Has an upload marker -> synced (awaiting reclaim or kept). Fine.
        [ -f "$UPLOAD_STATE_DIR/$s" ] && continue
        # Quiet for longer than the window with no marker -> the uploader is
        # not getting it out (S3/creds/proxy down, or dangling symlinks).
        if ! find "$d" -mmin -"$((PENDING_HOURS * 60))" -print -quit 2>/dev/null | grep -q .; then
            n=$((n + 1))
            stuck="${stuck} ${s}"
        fi
    done
    if [ "$n" -gt 0 ]; then
        state=ALERT; detail="${n} session(s) unsynced for >${PENDING_HOURS}h:${stuck}"
    else
        state=OK; detail="no sessions stuck awaiting upload"
    fi
}

check_grouped() {
    n=0
    for base in $GROUPED_DIRS; do
        [ -d "$base" ] || continue
        c=$(find "$base" -mindepth 1 -maxdepth 1 -type d \
            ! -name '__*' -mmin +"$((GROUPED_STUCK_HOURS * 60))" \
            2>/dev/null | wc -l | tr -d ' ')
        n=$((n + c))
    done
    if [ "$n" -gt 0 ]; then
        state=ALERT; detail="${n} tree(s) stuck in grouped dirs >${GROUPED_STUCK_HOURS}h (assign stalled?)"
    else
        state=OK; detail="grouped dirs draining normally"
    fi
}

# ---------------------------------------------------------------------------
# Per-session lifecycle events, announced once each.
# ------------------------------
announce_new() {
    ledger="$WATCHDOG_STATE_DIR/$1"
    current="$2"
    if [ ! -f "$ledger" ]; then
        printf '%s\n' "$current" | grep -v '^$' > "$ledger"
        return
    fi
    printf '%s\n' "$current" | grep -v '^$' | while IFS= read -r item; do
        if ! grep -Fxq "$item" "$ledger"; then
            echo "$item"
            echo "$item" >> "$ledger"
        fi
    done
}

session_events() {
    # End-to-end success: consume durable events written once per successful
    # upload attempt. Unlike session-name markers, this intentionally reports
    # a reprocessed session again when another source adds content.
    upload_event_files=$(find "$UPLOAD_EVENT_DIR" -maxdepth 1 -type f 2>/dev/null | sort)
    new_synced=$(printf '%s\n' "$upload_event_files" | grep -v '^$' \
        | while IFS= read -r f; do cat "$f"; done)

    # Assign failure: the session landed in __invalid__.
    invalid_now=$(find "$ASSIGNED_DIR/__invalid__" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | while IFS= read -r d; do basename "$d"; done)
    new_invalid=$(announce_new announced-invalid "$invalid_now")

    events=""
    if [ -n "$new_synced" ]; then
        events="${events}$(printf '%s\n' "$new_synced" | sed 's/^/✅ `/; s/$/` most recent snapshot synced to S3/')
"
    fi
    if [ -n "$new_invalid" ]; then
        events="${events}$(printf '%s\n' "$new_invalid" | sed 's/^/🚨 `/; s/$/` FAILED assign — in __invalid__ (unresolvable project\/subject\/session)/')
"
    fi
}

# ---------------------------------------------------------------------------
# Run all checks; alert on transitions; optional daily heartbeat.
# ---------------------------------------------------------------------------
alerts=""
recoveries=""
summary=""

for check in disk orthanc pending grouped; do
    state=OK detail=""
    "check_${check}"
    summary="${summary}$( [ "$state" = OK ] && echo "✅" || echo "🚨" ) ${check}: ${detail}
"
    prev_state=$(cut -d'|' -f1 "$WATCHDOG_STATE_DIR/last/$check" 2>/dev/null || echo "")
    if [ "$state" = ALERT ] && [ "$prev_state" != ALERT ]; then
        alerts="${alerts}🚨 **${check}** — ${detail}
"
    elif [ "$state" = ALERT ] && [ "$prev_state" = ALERT ]; then
        # Still bad: log it, but do not re-post. The transition already did.
        log "still ALERT: ${check}: ${detail}"
    elif [ "$state" = OK ] && [ "$prev_state" = ALERT ]; then
        recoveries="${recoveries}✅ **${check}** recovered — ${detail}
"
    fi
    printf '%s|%s\n' "$state" "$detail" > "$WATCHDOG_STATE_DIR/last/$check"
done

# __invalid__ is summary-only: the per-session event below carries the alert
# (with the session named), so a check-level transition would double-post and
# then claim "recovered" while the entry still sits there awaiting a human.
invalid_count=$(find "$ASSIGNED_DIR/__invalid__" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
summary="${summary}$( [ "$invalid_count" -eq 0 ] && echo "✅" || echo "⚠️" ) invalid: ${invalid_count} session(s) awaiting a human in __invalid__
"

log "run complete:"
printf '%s' "$summary" | while IFS= read -r line; do log "  $line"; done

events=""
session_events
if [ -n "$events" ]; then
    printf '%s' "$events" | while IFS= read -r line; do log "  $line"; done
fi

if [ -n "$alerts$recoveries$events" ]; then
    notify "**[${EDGE_NAME}] pipeline watchdog**
${alerts}${recoveries}${events}"
    # Remove upload events only after Discord accepted the post. A webhook
    # outage therefore retries delivery on the next CronJob run.
    if [ "$WEBHOOK_FAILED" -eq 0 ] && [ -n "${upload_event_files:-}" ]; then
        printf '%s\n' "$upload_event_files" | while IFS= read -r f; do
            [ -n "$f" ] && rm -f "$f"
        done
    fi
fi

# Daily heartbeat: one summary post so silence can be told apart from a dead
# watchdog. Sent in the HEARTBEAT_HOUR window, at most once per day.
if [ -n "$HEARTBEAT_HOUR" ] && [ "$(date -u +%H)" = "$HEARTBEAT_HOUR" ]; then
    today=$(date -u +%Y-%m-%d)
    if [ "$(cat "$WATCHDOG_STATE_DIR/heartbeat" 2>/dev/null)" != "$today" ]; then
        notify "**[${EDGE_NAME}] daily pipeline summary**
${summary}"
        echo "$today" > "$WATCHDOG_STATE_DIR/heartbeat"
    fi
fi

exit "$WEBHOOK_FAILED"
