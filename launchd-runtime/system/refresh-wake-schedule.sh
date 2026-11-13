#!/bin/bash
# Maintains the pmset wake schedule queue.
# Run by /Library/LaunchDaemons/com.agentic-skills.wakeschedule.plist daily at noon.
# Also runs at boot (RunAtLoad=true).
#
# Wake times are DERIVED from the com.agentic-skills.routines.* LaunchAgents present
# on this host (10 minutes before each, collapsing wakes within 20 minutes of
# one another), for the next 3 days — today + tomorrow + day after, about 48h
# of coverage. They were hardcoded to 03:55/17:55 until 2026-08-30, which only
# worked while every routine lived on a single Mac.
#
# Why only 3 days? Because the daemon refreshes daily at noon, so we
# only need enough buffer to survive one missed run. Scheduling 7 days
# at once was unreliable from the launchd context (only 3 days actually
# landed in the queue on 2026-05-10), root cause unknown. Less is more.
#
# Honors a pause-state file at <owner home>/.wake-schedule.state — if
# present and contains a future date (YYYY-MM-DD) or "forever", refresh
# is skipped.
#
# Logs to /var/log/wake-schedule.log via stdout (the launchd plist
# redirects). Each run writes a timestamped line.

set -euo pipefail

# Root runs this, so $HOME is not the owner's. system/install.sh writes the
# owner's home over the placeholder when it deploys the script; run straight
# from the repo (the tests do), it falls back to $HOME.
OWNER_HOME="__OWNER_HOME__"
[[ "$OWNER_HOME" == __*__ ]] && OWNER_HOME="$HOME"
STATE_FILE="${WAKE_STATE_FILE:-$OWNER_HOME/.wake-schedule.state}"
LOG_PREFIX="[$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')] [wake-schedule]"

log() { echo "$LOG_PREFIX $*"; }

# ── Pause check ──────────────────────────────────────────────────────────
if [[ -f "$STATE_FILE" ]]; then
    PAUSED_UNTIL=$(/bin/cat "$STATE_FILE" | /usr/bin/head -1 | /usr/bin/tr -d '[:space:]')

    if [[ "$PAUSED_UNTIL" == "forever" ]]; then
        log "Paused indefinitely; skipping refresh"
        exit 0
    fi

    TODAY=$(/bin/date +%Y-%m-%d)
    # String comparison works because YYYY-MM-DD sorts correctly
    if [[ "$TODAY" < "$PAUSED_UNTIL" ]]; then
        log "Paused until $PAUSED_UNTIL; skipping refresh"
        exit 0
    fi

    # Pause expired — clear the file and continue
    /bin/rm -f "$STATE_FILE"
    log "Pause expired ($PAUSED_UNTIL); resuming"
fi

# ── Derive wake times from the routines installed on THIS host ───────────
# This used to be a hardcoded 03:55/17:55 pair, which was correct only while
# every routine lived on one Mac. The moment daily-summary moved to the M2,
# the M4 kept waking at 17:55 for nothing and had no wake at all before the
# 19:00 review nudge. Deriving the times means each machine's queue follows
# its own routines automatically as they migrate.
#
# Wake 10 minutes before each routine, then collapse any wake falling within
# 20 minutes of an earlier one — the machine is still up by then, so the
# 04:00/04:02/04:05/04:10 batch needs one wake, not four.
ROUTINE_PLIST_DIR="${ROUTINE_PLIST_DIR:-$OWNER_HOME/Library/LaunchAgents}"
WAKE_LEAD_MINUTES=10
WAKE_COLLAPSE_MINUTES=20

derive_wake_times() {
    local raw="" p h m total
    local key i
    for p in "$ROUTINE_PLIST_DIR"/com.agentic-skills.routines.*.plist; do
        [ -f "$p" ] || continue
        # StartCalendarInterval is one dict, or an array of them (playtest-build-night fires on three
        # weekdays). Every entry's time becomes a daily wake: a wake on a day the routine skips
        # costs nothing, a missed one costs the run.
        for i in "" 0 1 2 3 4 5 6; do
            key="StartCalendarInterval${i:+.$i}"
            h=$(/usr/bin/plutil -extract "$key.Hour" raw "$p" 2>/dev/null) || continue
            m=$(/usr/bin/plutil -extract "$key.Minute" raw "$p" 2>/dev/null) || continue
            case "$h$m" in *[!0-9]*) continue ;; esac
            total=$(( (h * 60 + m - WAKE_LEAD_MINUTES + 1440) % 1440 ))
            raw="$raw$total\n"
        done
    done
    [ -z "$raw" ] && return 0
    local last=-999 t
    for t in $(printf "$raw" | /usr/bin/sort -n | /usr/bin/uniq); do
        if [ $(( t - last )) -ge $WAKE_COLLAPSE_MINUTES ]; then
            printf '%02d:%02d:00\n' $(( t / 60 )) $(( t % 60 ))
            last=$t
        fi
    done
}

WAKE_TIMES=$(derive_wake_times)
if [ -z "$WAKE_TIMES" ]; then
    log "no routine LaunchAgents found in $ROUTINE_PLIST_DIR — leaving the queue alone"
    log "(install a routine first, or set ROUTINE_PLIST_DIR)"
    exit 0
fi
log "derived wake times from installed routines: $(echo $WAKE_TIMES | /usr/bin/tr '\n' ' ')"

# ── Refresh queue: 3 days × derived wakes ────────────────────────────────
log "starting refresh"
/usr/bin/pmset schedule cancelall 2>&1 || true
log "cancelled existing queue"

QUEUED=0
FAILED=0
for i in 0 1 2; do
    DATE=$(/bin/date -v +${i}d +%m/%d/%Y)
    for TIME in $WAKE_TIMES; do
        if /usr/bin/pmset schedule wake "$DATE $TIME" 2>&1; then
            QUEUED=$((QUEUED + 1))
        else
            FAILED=$((FAILED + 1))
            log "FAILED to queue $DATE $TIME"
        fi
    done
done

log "Refresh complete: $QUEUED queued, $FAILED failed"
log "Current queue:"
/usr/bin/pmset -g sched | /usr/bin/sed 's/^/  /'
