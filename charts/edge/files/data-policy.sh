#!/bin/sh
# =============================================================================
# Edge data-policy engine — reports on every declared dataPolicy stage
# =============================================================================
# WHAT THIS IS FOR
#
# dataPolicy declares a data lifecycle, but its rules used to be implemented
# inside whichever component happened to be nearby: an `rm -rf` in the S3
# uploader, a `--unlink-source` flag on xnat-ingest, a CronJob on the management
# side. Three stages, three mechanisms, each welded to one tool. That is why
# most of the block was never implemented — adding a rule meant writing a new
# program — and why replacing a component silently deletes the policy with it.
#
# This walks STAGES instead. Each stage is a location plus rules, declared in
# values.yaml and rendered into /etc/data-policy/stages.tsv. Nothing here knows
# what Orthanc is, or xnat-ingest, or DICOM. Swap the de-identifier, or add
# Prefect handling non-DICOM drops, and the new store declares a stage and gets
# reporting and retention with no new code.
#
# TWO MODES, AND THE SAFE ONE IS THE DEFAULT.
#   report-only      dataPolicy.enabled=false  -> measures, deletes nothing
#   reclaim-dry-run  enabled=true, dryRun=true -> logs every decision, deletes nothing
#   reclaim-ARMED    enabled=true, dryRun=false-> removes derived stages
# The chart mounts the volumes READ-ONLY in the first two, so in those modes the
# process physically cannot delete even if this logic were wrong.
#
# ORIGINALS NEED A THIRD SWITCH. Expiring the facility backup or the quarantine
# destroys the only identifiable copy, so `dataPolicy.originals.allowExpiry`
# must ALSO be true — and the chart keeps that mount read-only until it is.
# Their rule is age alone: nothing downstream can vouch for an original,
# because it IS the source.
#
# STORES THAT ARE NOT DIRECTORIES GET A BACKEND. Orthanc names files by UUID, so
# a walk cannot map them to sessions; `backend: orthanc-rest` hands that stage to
# an adapter instead. That seam is what lets a different de-identifier ship its
# own adapter without the engine learning anything about it.
#
# IT ATTACHES TO VOLUMES, NOT TO WORKLOADS. It runs as its own DaemonSet rather
# than as a sidecar on Orthanc, because disk and retention are storage concerns:
# a sidecar would disappear the moment the de-identifier was replaced, and edge
# disk monitoring would vanish with it — silently, which is the failure mode
# this repo keeps hitting.
#
# THE LOG SCHEMA IS A PUBLIC INTERFACE. Two Loki alerts parse these fields:
#   stage_report.free_pct       -> EdgeDiskLow            (minFreeDiskPercent)
#   stage_report.oldest_age_s   -> QuarantinedDataUnresolved (alertAfter)
# Renaming an event or a numeric field disables its alert SILENTLY.
# =============================================================================
set -u

INTERVAL="${INTERVAL:-300}"
EDGE_NAME="${EDGE_NAME:?EDGE_NAME required}"
STAGES_FILE="${STAGES_FILE:-/etc/data-policy/stages.tsv}"

# --- reclaim ------------------------------------------------------------------
# Both must be satisfied before anything is removed: RECLAIM_ENABLED is
# dataPolicy.enabled, DRY_RUN is dataPolicy.dryRun. Defaults are the safe
# corner, so a partial upgrade or a missing env var reports instead of deleting.
#
# The chart ALSO mounts the volumes read-only unless both are set, so in
# report-only mode this process physically cannot delete even if the logic
# below were wrong. Belt and braces, because the alternative is patient data.
# One pass then exit, instead of looping. Used by tests/data-policy/run-tests.sh
# and useful for an operator who wants a single on-demand report without waiting
# out an interval. The loop is the default because this is a DaemonSet.
ONESHOT="${ONESHOT:-false}"
RECLAIM_ENABLED="${RECLAIM_ENABLED:-false}"
DRY_RUN="${DRY_RUN:-true}"
# Blast-radius cap per stage per pass, matching the S3 reclaimer's design: a
# "delete everything" bug is bounded to this many sessions, leaving the rest
# for a human to notice first.
MAX_REMOVALS="${MAX_REMOVALS:-50}"
# Nothing is touched while it may still be being written. group/assign copy
# trees in, and a directory that looks complete mid-copy is exactly how a
# half-session gets reclaimed.
SETTLE_MINUTES="${SETTLE_MINUTES:-5}"
# How long a session may fail its reclaim condition before it is called
# stuck. 0 or "-" disables the check entirely. See the branch that uses it.
STUCK_AFTER_S="${STUCK_AFTER_S:-0}"
# The uploader's fingerprint state dir. A file here named after a session is
# the uploader's own record that it finished pushing that session to S3 — the
# observable signal `onUploaded` is derived from, needing no change to
# xnat-ingest and no new marker protocol.
UPLOAD_STATE_DIR="${UPLOAD_STATE_DIR:-/data/LOGS/s3-uploader-state}"
# Where assign writes. Used only to answer `onAssigned` for the grouped stage.
ASSIGNED_DIR="${ASSIGNED_DIR:-/data/assigned}"

# --- originals ----------------------------------------------------------------
# THE THIRD SWITCH. Originals are the only identifiable copy of a study, so
# expiring one is not the same act as reclaiming a derived tree and does not
# share its consent. Even with RECLAIM_ENABLED=true and DRY_RUN=false, nothing
# with kind=original is touched unless this is also true — and the chart mounts
# the facility backup read-only unless all three line up.
ALLOW_ORIGINAL_EXPIRY="${ALLOW_ORIGINAL_EXPIRY:-false}"

# --- orthanc-rest backend -----------------------------------------------------
# Orthanc names its files by UUID, so a directory walk cannot map them back to
# sessions. Reclaiming it means asking Orthanc. This is the ONLY place in the
# engine that knows Orthanc exists, reached only by a stage that declares
# `backend: orthanc-rest` — which is what lets a different de-identifier ship
# its own adapter without touching anything else here.
ORTHANC_URL="${ORTHANC_URL:-}"
ORTHANC_PROCESSED_LABEL="${ORTHANC_PROCESSED_LABEL:-xnat-ingest-processed}"
ORTHANC_USER="${ORTHANC_USER:-}"
ORTHANC_PASS="${ORTHANC_PASS:-}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-30}"

# Strip anything that would break one-JSON-object-per-line. A path or a df error
# can carry quotes and backslashes; one unescaped character makes Loki's | json
# stage drop the line, which takes the alert with it.
jsan() {
    printf '%s' "${1:-}" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-300
}

jlog() {
    # $1=event  $2=stage  $3=message  $4=extra JSON (leading comma, optional)
    printf '{"ts":"%s","component":"data-policy","edge":"%s","event":"%s","stage":"%s","message":"%s"%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S+00:00)" "$(jsan "$EDGE_NAME")" "$1" "$(jsan "${2:-}")" \
        "$(jsan "${3:-}")" "${4:-}"
}

[ -f "$STAGES_FILE" ] || {
    jlog startup_failed "" "no stage file at ${STAGES_FILE} — the chart renders it; nothing can be reported without it"
    # Exit non-zero so the pod restarts visibly rather than looping while
    # reporting nothing. Silence here would look exactly like a healthy site.
    exit 1
}

# Free percent for the filesystem holding a path.
#
# busybox df has no -P, so the LAST line is parsed: a long device name wraps
# onto its own line and would otherwise shift every column. Emits nothing rather
# than a wrong number if the shape is unexpected — a fabricated free_pct would
# silence EdgeDiskLow instead of firing it.
report_disk() {
    stage="$1" path="$2"
    line=$(df -k "$path" 2>/dev/null | tail -n1)
    size=$(echo "$line" | awk '{print $2}')
    avail=$(echo "$line" | awk '{print $4}')
    case "${size:-}${avail:-}" in
        ''|*[!0-9]*)
            jlog stage_unreadable "$stage" "df gave no usable numbers for ${path} — free space is UNKNOWN, not fine" \
                 ",\"location\":\"$(jsan "$path")\""
            return 1 ;;
    esac
    [ "$size" -gt 0 ] 2>/dev/null || return 1
    FREE_PCT=$(( avail * 100 / size ))
    SIZE_KB="$size"
    AVAIL_KB="$avail"
    return 0
}

# Entry count and the age of the OLDEST file under a path.
#
# The oldest matters more than the count: "has anything been stuck here past the
# threshold" is the question quarantine.alertAfter asks, and one very old study
# matters even when the count is 1.
#
# busybox find has no -printf, so `-exec stat -c %Y` is the portable form.
# Batched with `{} +`, NOT `{} \;`: the terminator form forks one stat per
# file, which makes every sweep O(files) in process spawns. Measured in this
# image over 2000 files, 24.5s vs 1.6s under a 100m quota. busybox find
# supports `+`; verified in curlimages/curl:8.11.1.
report_age() {
    path="$1"
    ENTRIES=$(find "$path" -type f 2>/dev/null | wc -l | tr -d ' ')
    case "${ENTRIES:-}" in ''|*[!0-9]*) ENTRIES=0 ;; esac
    if [ "$ENTRIES" -eq 0 ]; then
        OLDEST_AGE_S=0
        return 0
    fi
    oldest=$(find "$path" -type f -exec stat -c %Y {} + 2>/dev/null | sort -n | head -n1)
    case "${oldest:-}" in
        ''|*[!0-9]*) OLDEST_AGE_S=-1; return 1 ;;
    esac
    now=$(date -u +%s)
    OLDEST_AGE_S=$(( now - oldest ))
    [ "$OLDEST_AGE_S" -ge 0 ] || OLDEST_AGE_S=0
    return 0
}

# -----------------------------------------------------------------------------
# CONDITIONS — "has this session moved on far enough that its copy here is
# reconstructible?" Answered from OBSERVABLE FILESYSTEM STATE, never from a
# marker protocol we would have to persuade xnat-ingest to adopt.
#
# Returns non-zero on ANY doubt, and every caller treats that as KEEP. An
# unknown condition word is a keep, not a delete: a typo in values.yaml must not
# be able to authorise removal.
# -----------------------------------------------------------------------------
# MUST MATCH s3-uploader.sh's fingerprint() EXACTLY. The uploader writes this
# value into the state file after a successful sync; condition_met recomputes it
# to check that what is on disk now is what was uploaded then. If the two
# implementations drift, every session looks changed and nothing is ever
# reclaimed -- which fails safe, but silently.
fingerprint() {
    find -L "$1" -type f -printf '%P %s %T@\n' 2>/dev/null | sort | md5sum | cut -d' ' -f1
}

condition_met() {   # condition_met <reclaim-word> <session-name> <stage-name>
    case "$1" in
        onUploaded)
            # THE MARKER'S CONTENT, NOT ITS EXISTENCE. The uploader writes a
            # fingerprint of exactly the bytes it uploaded; this recomputes it
            # and compares.
            #
            # Existence alone was safe only while the marker was swept in the
            # same pass that wrote it, so it could never outlive the data it
            # described. Now that it survives by age, an existence test would be
            # a standing permission to delete anything that later appeared under
            # the same session name: a supplementary or re-sent study would be
            # authorised for removal on the strength of a marker describing an
            # upload of different bytes.
            [ -f "${UPLOAD_STATE_DIR}/$2" ] || return 1
            [ -d "${ASSIGNED_DIR}/$2" ] || return 0   # already gone; nothing to protect
            [ "$(cat "${UPLOAD_STATE_DIR}/$2" 2>/dev/null)" = "$(fingerprint "${ASSIGNED_DIR}/$2")" ] ;;
        onAssigned)
            # Either assign has produced its output, or the session has already
            # travelled further and assign's copy is gone. The second half
            # matters: without it, a session whose assigned copy was already
            # reclaimed would pin its grouped copy forever.
            [ -d "${ASSIGNED_DIR}/$2" ] || [ -f "${UPLOAD_STATE_DIR}/$2" ] ;;
        onDeidentified)
            # NEVER TRUE HERE, BY DESIGN, and listed so that it is documented
            # rather than silently unknown. This condition is satisfied by the
            # deidentify STAGE, which unlinks each session's input once it has
            # written a complete de-identified copy. That happens inside
            # xnat-ingest and leaves no artefact this engine can observe, so the
            # engine reports the tree and never acts on it. A session still
            # present under this word is one the stage has not finished with,
            # and keeping it is the correct answer.
            return 1 ;;
        *)
            # AN UNKNOWN WORD IS NOT AN UNMET CONDITION, and until now both
            # returned 1. A typo -- onDeidentifed, onUpladed -- behaved exactly
            # like a correctly configured site whose condition had not yet come
            # true: nothing reclaimed, for ever, logged as normal operation. The
            # reclaim words are validated nowhere else; the enum in values.yaml
            # is a comment with no schema behind it.
            jlog reclaim_unknown_condition "$3" "reclaim word '$1' is not one this engine implements, so no session in this stage can ever be reclaimed. Expected never, onUploaded, onAssigned or onDeidentified" \
                 ",\"session\":\"$(jsan "$2")\",\"reclaim\":\"$(jsan "$1")\""
            return 1 ;;
    esac
}

# Age of the NEWEST file in a tree. Newest, not oldest: minAge asks "has this
# been quiet long enough", and one freshly-written file means the answer is no
# even if everything beside it is ancient.
newest_age_s() {
    newest=$(find "$1" -type f -exec stat -c %Y {} + 2>/dev/null | sort -n | tail -n1)
    case "${newest:-}" in
        ''|*[!0-9]*) echo -1; return 1 ;;
    esac
    echo $(( $(date -u +%s) - newest ))
}

reclaim_stage() {   # reclaim_stage <name> <kind> <location> <min_age_s> <reclaim>
    r_name="$1" r_kind="$2" r_loc="$3" r_minage="$4" r_word="$5"

    # ORIGINALS ARE NEVER RECLAIMED HERE. facilityBackup/quarantine expiry means
    # deleting the only identifiable copy, and that needs its own design and
    # sign-off. Reporting on them is live; removing them is deliberately not.
    [ "$r_kind" = "derived" ] || return 0
    case "$r_word" in never|-|"") return 0 ;; esac
    case "${r_minage:-}" in ''|-|*[!0-9]*) r_minage=0 ;; esac

    r_removed=0
    for d in "$r_loc"/*/; do
        [ -d "$d" ] || continue
        s=$(basename "$d")
        case "$s" in __*|'*') continue ;; esac

        if [ "$r_removed" -ge "$MAX_REMOVALS" ]; then
            jlog reclaim_skipped "$r_name" "per-pass cap of ${MAX_REMOVALS} reached — remaining entries left for the next pass" \
                 ",\"session\":\"$(jsan "$s")\""
            break
        fi

        # Still being written: leave it entirely alone.
        if find "$d" -mmin -"$SETTLE_MINUTES" -print -quit 2>/dev/null | grep -q .; then
            continue
        fi

        if ! condition_met "$r_word" "$s" "$r_name"; then
            # A SESSION WHOSE CONDITION NEVER COMES TRUE IS STUCK, AND UNTIL NOW
            # NOTHING SAID SO. Keeping it is the right call every single time --
            # the copy is not provably reconstructible, so it stays -- but a
            # session that has been failing that test for days is not the same
            # event as one that failed it a minute ago, and both logged the
            # identical line. The steady drip of reclaim_kept is indistinguishable
            # from normal operation, which is how a permanently stuck session hid
            # in this repo twice.
            #
            # This does NOT delete or move anything. It raises the event that an
            # alert can key on, and leaves the data exactly where it is. Moving a
            # stuck session was the original proposal; it is deliberately not done
            # here. Quarantining means moving the input AND removing the partial
            # output as ONE action: doing only the first leaves an orphan with
            # nothing left to repair it from, which upload would then collect. An
            # engine that can do half of that should do neither. (Its /data mount
            # is also read-only unless retention is armed, so a move would work in
            # one mode and silently not in the other, but the two-operations
            # argument holds whatever the mount says.)
            if [ "${STUCK_AFTER_S:--}" != "-" ] && [ "${STUCK_AFTER_S:-0}" -gt 0 ]; then
                s_age=$(newest_age_s "$d") || s_age=-1
                if [ "$s_age" -ge "$STUCK_AFTER_S" ]; then
                    jlog stage_stuck "$r_name" "session has not satisfied '${r_word}' for ${s_age}s and is not being retried by anything — the stage it is waiting on has not produced what this condition looks for" \
                         ",\"session\":\"$(jsan "$s")\",\"reclaim\":\"$(jsan "$r_word")\",\"age_s\":${s_age}"
                    continue
                fi
            fi
            jlog reclaim_kept "$r_name" "condition ${r_word} not satisfied — nothing downstream proves this copy is reconstructible" \
                 ",\"session\":\"$(jsan "$s")\",\"reclaim\":\"$(jsan "$r_word")\""
            continue
        fi

        age=$(newest_age_s "$d") || {
            jlog reclaim_kept "$r_name" "could not read mtimes — age is UNKNOWN, so not eligible" \
                 ",\"session\":\"$(jsan "$s")\""
            continue
        }
        if [ "$age" -lt "$r_minage" ]; then
            jlog reclaim_skipped "$r_name" "condition met but only ${age}s old, minAge is ${r_minage}s — inside the recovery window" \
                 ",\"session\":\"$(jsan "$s")\",\"age_s\":${age},\"min_age_s\":${r_minage}"
            continue
        fi

        if [ "$RECLAIM_ENABLED" != "true" ] || [ "$DRY_RUN" = "true" ]; then
            jlog reclaim_skipped "$r_name" "WOULD remove (dataPolicy enabled=${RECLAIM_ENABLED} dryRun=${DRY_RUN})" \
                 ",\"session\":\"$(jsan "$s")\",\"age_s\":${age},\"min_age_s\":${r_minage}"
            continue
        fi

        if rm -rf "$d" 2>/dev/null && [ ! -d "$d" ]; then
            r_removed=$((r_removed + 1))
            jlog reclaim_removed "$r_name" "removed after ${r_word} and minAge ${r_minage}s" \
                 ",\"session\":\"$(jsan "$s")\",\"age_s\":${age}"
        else
            jlog reclaim_failed "$r_name" "rm returned but the directory is still present — check permissions on the mount" \
                 ",\"session\":\"$(jsan "$s")\""
        fi
    done
}

# -----------------------------------------------------------------------------
# ORIGINALS EXPIRY — the only path that removes an identifiable copy.
#
# THE UNIT IS THE TOP-LEVEL ENTRY, NOT THE FILE. Under the facility backup that
# entry is one PATIENT (<PatientID>/<StudyUID>/<SOPUID>.dcm), so with
# retain: 30d the rule reads:
#
#   A patient directory whose most recent file is older than 30 days is
#   deleted ENTIRELY.
#
# Age is measured on the NEWEST file in the entry, not the oldest. A patient
# holding one recent study is not expired because an older study beside it has
# aged out; the conservative reading is the correct one when the alternative is
# destroying the archive of record. The corollary is that when a patient does
# expire, studies far older than the window go with them — this is per-entry
# expiry, not per-study.
#
# There is no CONDITION here, unlike derived stages — nothing downstream can
# vouch for an original, because it IS the source. Age is the whole rule, which
# is exactly why it needs its own switch.
# -----------------------------------------------------------------------------
expire_original() {   # expire_original <name> <location> <retain_seconds> <policy>
    e_name="$1" e_loc="$2" e_age="$3" e_policy="$4"

    # `forever` renders as `-`; anything non-numeric means "no expiry rule", and
    # is treated as forever rather than as 0. A malformed duration must never
    # become "expire immediately".
    case "${e_age:-}" in ''|-|*[!0-9]*) return 0 ;; esac
    [ "$e_age" -gt 0 ] 2>/dev/null || return 0

    if [ "$ALLOW_ORIGINAL_EXPIRY" != "true" ]; then
        jlog expiry_skipped "$e_name" "retain=${e_policy} is a duration, but dataPolicy.originals.allowExpiry is false — originals are not expired" \
             ",\"retain\":\"$(jsan "$e_policy")\""
        return 0
    fi

    e_removed=0
    for d in "$e_loc"/*/; do
        [ -d "$d" ] || continue
        s=$(basename "$d")
        case "$s" in __*|'*') continue ;; esac

        if [ "$e_removed" -ge "$MAX_REMOVALS" ]; then
            jlog expiry_skipped "$e_name" "per-pass cap of ${MAX_REMOVALS} reached" ",\"entry\":\"$(jsan "$s")\""
            break
        fi
        if find "$d" -mmin -"$SETTLE_MINUTES" -print -quit 2>/dev/null | grep -q .; then
            continue
        fi

        age=$(newest_age_s "$d") || {
            jlog expiry_kept "$e_name" "could not read mtimes — age UNKNOWN, so not expired" ",\"entry\":\"$(jsan "$s")\""
            continue
        }
        if [ "$age" -lt "$e_age" ]; then
            continue
        fi
        if [ "$DRY_RUN" = "true" ] || [ "$RECLAIM_ENABLED" != "true" ]; then
            jlog expiry_skipped "$e_name" "WOULD expire (age ${age}s >= retain ${e_age}s), but enabled=${RECLAIM_ENABLED} dryRun=${DRY_RUN}" \
                 ",\"entry\":\"$(jsan "$s")\",\"age_s\":${age},\"retain_s\":${e_age}"
            continue
        fi
        if rm -rf "$d" 2>/dev/null && [ ! -d "$d" ]; then
            e_removed=$((e_removed + 1))
            jlog expiry_removed "$e_name" "ORIGINAL expired after ${e_age}s retention" \
                 ",\"entry\":\"$(jsan "$s")\",\"age_s\":${age},\"retain_s\":${e_age}"
        else
            jlog expiry_failed "$e_name" "rm returned but the entry is still present — is the mount read-only?" \
                 ",\"entry\":\"$(jsan "$s")\""
        fi
    done
}

# -----------------------------------------------------------------------------
# ORTHANC-REST BACKEND — reclaim a store the filesystem cannot describe.
#
# Orthanc's own label is the condition: group-orthanc applies
# ingest.orthancGroup.processedLabel once it has pulled a study out, so a study
# carrying it has already left for the pipeline. Age comes from Orthanc's
# LastUpdate (YYYYMMDDTHHMMSS, UTC).
#
# Every uncertainty returns without deleting: no URL, a non-200, an unparseable
# timestamp, an empty study list. The bytes also remain in the facility backup,
# but that is a reason to be careful rather than a licence to guess.
# -----------------------------------------------------------------------------
orthanc_curl() {   # orthanc_curl <method> <path> [data]
    if [ -n "$ORTHANC_USER" ]; then
        printf 'user = "%s:%s"\n' "$ORTHANC_USER" "$ORTHANC_PASS" \
            | curl -sS --max-time "$HTTP_TIMEOUT" -K - -X "$1" \
                   ${3:+-d "$3"} "${ORTHANC_URL}$2" 2>/dev/null
    else
        curl -sS --max-time "$HTTP_TIMEOUT" -X "$1" ${3:+-d "$3"} "${ORTHANC_URL}$2" 2>/dev/null
    fi
}

reclaim_orthanc() {   # reclaim_orthanc <name> <policy> <min_age_seconds>
    o_name="$1" o_policy="$2" o_age="$3"
    case "$o_policy" in never|-|"") return 0 ;; esac
    case "${o_age:-}" in ''|-|*[!0-9]*) o_age=0 ;; esac

    if [ -z "$ORTHANC_URL" ]; then
        jlog backend_unavailable "$o_name" "backend=orthanc-rest but ORTHANC_URL is empty — nothing examined, nothing removed"
        return 0
    fi

    ids=$(orthanc_curl POST /tools/find \
            "{\"Level\":\"Study\",\"Query\":{},\"Labels\":[\"${ORTHANC_PROCESSED_LABEL}\"],\"LabelsConstraint\":\"All\"}" \
          | tr -d '[]" ' | tr ',' '\n' | grep -v '^$')
    if [ -z "$ids" ]; then
        jlog backend_idle "$o_name" "no studies carry ${ORTHANC_PROCESSED_LABEL} — nothing to reclaim"
        return 0
    fi

    o_removed=0
    now=$(date -u +%s)
    for id in $ids; do
        [ "$o_removed" -ge "$MAX_REMOVALS" ] && {
            jlog reclaim_skipped "$o_name" "per-pass cap of ${MAX_REMOVALS} reached"; break; }

        # Extract the QUOTED value, not "everything after the colon". Orthanc
        # pretty-prints its JSON, so a cut on ':' left the trailing comma
        # attached ("20260806T145356,") and every study was then rejected as
        # having an unparseable timestamp — safe, but it would have meant this
        # backend silently never reclaimed anything.
        last=$(orthanc_curl GET "/studies/${id}" \
               | sed -n 's/.*"LastUpdate"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        case "${last:-}" in
            ''|*[!0-9T]*) jlog reclaim_kept "$o_name" "no usable LastUpdate for study ${id} — age UNKNOWN" \
                               ",\"study\":\"$(jsan "$id")\""; continue ;;
        esac
        epoch=$(date -u -D '%Y%m%dT%H%M%S' -d "$last" +%s 2>/dev/null)
        case "${epoch:-}" in ''|*[!0-9]*)
            jlog reclaim_kept "$o_name" "could not parse LastUpdate ${last} for ${id}" ",\"study\":\"$(jsan "$id")\""
            continue ;;
        esac
        age=$(( now - epoch ))
        if [ "$age" -lt "$o_age" ]; then
            continue
        fi
        if [ "$RECLAIM_ENABLED" != "true" ] || [ "$DRY_RUN" = "true" ]; then
            jlog reclaim_skipped "$o_name" "WOULD delete study ${id} (age ${age}s >= minAge ${o_age}s), enabled=${RECLAIM_ENABLED} dryRun=${DRY_RUN}" \
                 ",\"study\":\"$(jsan "$id")\",\"age_s\":${age},\"min_age_s\":${o_age}"
            continue
        fi
        if orthanc_curl DELETE "/studies/${id}" >/dev/null 2>&1; then
            o_removed=$((o_removed + 1))
            jlog reclaim_removed "$o_name" "deleted study ${id} from Orthanc after ${o_age}s" \
                 ",\"study\":\"$(jsan "$id")\",\"age_s\":${age}"
        else
            jlog reclaim_failed "$o_name" "Orthanc refused DELETE for study ${id}" ",\"study\":\"$(jsan "$id")\""
        fi
    done
}

count_stages=$(grep -cv '^[[:space:]]*$' "$STAGES_FILE" 2>/dev/null || echo 0)
if [ "$RECLAIM_ENABLED" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    DP_MODE="reclaim-ARMED"
elif [ "$RECLAIM_ENABLED" = "true" ]; then
    DP_MODE="reclaim-dry-run"
else
    DP_MODE="report-only"
fi
jlog startup "" "data-policy engine starting mode=${DP_MODE} interval=${INTERVAL}s stages=${count_stages} maxRemovals=${MAX_REMOVALS} settle=${SETTLE_MINUTES}m"

while true; do
    # Fields: name, kind, location, minFreeDiskPercent, alertAfterSeconds, retain
    # Durations are converted to seconds by the chart, so this stays free of
    # shell duration parsing and the engine cannot disagree with the template.
    while IFS="$(printf '\t')" read -r name kind location min_free alert_after policy age_sec backend; do
        [ -n "${name:-}" ] || continue
        case "$name" in \#*) continue ;; esac

        if [ ! -d "$location" ]; then
            # ABSENT IS REPORTED, NOT SKIPPED. A stage whose directory does not
            # exist is either not in use yet (fileDrop before the first drop, or
            # quarantine before the first rejection) or a location that has
            # drifted from where the data really goes. Both are worth a line;
            # silence would make the second indistinguishable from a tidy site.
            jlog stage_absent "$name" "no directory at ${location}" \
                 ",\"location\":\"$(jsan "$location")\",\"kind\":\"$(jsan "$kind")\""
            continue
        fi

        report_disk "$name" "$location" || continue
        report_age "$location"

        extra=",\"location\":\"$(jsan "$location")\",\"kind\":\"$(jsan "$kind")\""
        extra="${extra},\"free_pct\":${FREE_PCT},\"size_kb\":${SIZE_KB},\"avail_kb\":${AVAIL_KB}"
        extra="${extra},\"entries\":${ENTRIES},\"oldest_age_s\":${OLDEST_AGE_S}"
        # Thresholds are echoed with the reading so a Loki rule can compare
        # against the stage's OWN limit rather than one hardcoded fleet-wide,
        # and so an operator reading the log can see what it was judged against.
        [ -n "${min_free:-}" ] && [ "$min_free" != "-" ] && \
            extra="${extra},\"min_free_pct\":${min_free}"
        [ -n "${alert_after:-}" ] && [ "$alert_after" != "-" ] && \
            extra="${extra},\"alert_after_s\":${alert_after}"
        [ -n "${policy:-}" ] && [ "$policy" != "-" ] && \
            extra="${extra},\"policy\":\"$(jsan "$policy")\""
        [ -n "${backend:-}" ] && [ "$backend" != "-" ] && \
            extra="${extra},\"backend\":\"$(jsan "$backend")\""

        jlog stage_report "$name" "${FREE_PCT}% free, ${ENTRIES} file(s), oldest ${OLDEST_AGE_S}s" "$extra"

        # Reclaim runs AFTER the report for the same stage, so the log always
        # shows the state a decision was made against.
        #
        # DISPATCH BY kind THEN backend. Originals never reach reclaim_stage —
        # they have no downstream condition to satisfy, only age, and only with
        # their own switch. A derived stage goes to its declared backend, which
        # is the seam a future store plugs into.
        case "$kind" in
            original)
                expire_original "$name" "$location" "$age_sec" "$policy" ;;
            derived)
                case "${backend:-filesystem}" in
                    orthanc-rest) reclaim_orthanc "$name" "$policy" "$age_sec" ;;
                    filesystem|-|"") reclaim_stage "$name" "$kind" "$location" "$age_sec" "$policy" ;;
                    *)  # An unknown backend must not fall through to a
                        # filesystem walk: /data/orthanc-storage walked as if it
                        # were session directories would delete Orthanc's own
                        # UUID folders.
                        jlog backend_unknown "$name" "unknown backend '${backend}' — nothing examined, nothing removed" \
                             ",\"backend\":\"$(jsan "$backend")\"" ;;
                esac ;;
        esac
    done < "$STAGES_FILE"

    [ "$ONESHOT" = "true" ] && break
    sleep "$INTERVAL"
done
