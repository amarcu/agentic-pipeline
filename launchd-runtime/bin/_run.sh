#!/bin/bash
# Generic runner for claude-cli-driven launchd routines.
#
# Usage: _run.sh <routine-name>
#
# Reads prompt from: <ROUTINE_DIR>/<routine-name>.prompt.md
# Logs to:           <ROUTINE_DIR>/logs/<routine-name>-YYYY-MM-DD.log
# Sends Telegram alert on non-zero exit (with last 30 lines of log).
#
# Exit codes: the CLI's own on a completed run, otherwise
#   2 usage error, missing prompt file, or unreadable deny-net
#   3 not on AC power
#   4 wrong host for this routine, or auth canary abort
#   5 jq not found
#   6 invalid ROUTINE_EFFORT
#
# Telegram credentials are loaded from $HOME/.claude/settings.json
# (single source of truth — same place Claude Desktop reads them).
#
# This script is launchd-safe: no shell-rc dependencies, all paths absolute.

set -uo pipefail
# NB: NOT -e — we capture exit codes manually so we can alert on failure.

ROUTINE="${1:-}"
if [[ -z "$ROUTINE" ]]; then
    echo "Usage: $0 <routine-name>" >&2
    exit 2
fi

# Paths are env-var overridable so the test harness can run this script
# against fixtures without touching production paths.
ROUTINE_DIR="${ROUTINE_DIR:-${AGENTIC_SKILLS_HOME:-$HOME/.agentic-skills}/routines}"
SETTINGS_FILE="${SETTINGS_FILE:-$HOME/.claude/settings.json}"
CLAUDE_CLI="${CLAUDE_CLI:-${AGENTIC_SKILLS_HOME:-$HOME/.agentic-skills}/claude-cli}"
TELEGRAM_API_URL="${TELEGRAM_API_URL:-https://api.telegram.org}"

PROMPT_FILE="${ROUTINE_DIR}/${ROUTINE}.prompt.md"
LOG_DIR="${ROUTINE_DIR}/logs"
LOG_FILE="${LOG_DIR}/${ROUTINE}-$(/bin/date +%Y-%m-%d).log"

/bin/mkdir -p "$LOG_DIR"

# Per-run cost sidecars and the append-only spend ledger (ROUTINE_CAPTURE_JSON).
# Created unconditionally: if this directory is missing when capture is on, the
# stdout redirect below fails BEFORE $CLAUDE_CLI ever runs, turning the first
# enabled night into a silent no-op rather than an error.
METRICS_DIR="${ROUTINE_DIR}/metrics"
/bin/mkdir -p "$METRICS_DIR"

if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')] ERROR: prompt file missing: $PROMPT_FILE" >> "$LOG_FILE"
    exit 2
fi

# Resolve jq once. Apple only started shipping /usr/bin/jq in macOS 15, and
# /usr/bin sits on the read-only signed system volume, so on an older host it
# cannot simply be installed there. Hardcoding the path made the runner
# non-portable to a second Mac. Order matters: prefer the system copy, then
# the usual package-manager prefixes, then a user-local install.
if [[ -z "${JQ:-}" ]]; then
    for _jq_candidate in /usr/bin/jq /opt/homebrew/bin/jq /usr/local/bin/jq "$HOME/.local/bin/jq"; do
        if [[ -x "$_jq_candidate" ]]; then
            JQ="$_jq_candidate"
            break
        fi
    done
fi
if [[ -z "${JQ:-}" ]]; then
    JQ=$(command -v jq 2>/dev/null || echo "")
fi
if [[ -z "$JQ" ]]; then
    # Every credential in this script is read with jq, including the Telegram
    # token — so there is no way to alert from here. Log loudly and exit with
    # a distinct code the host watchdog can recognise.
    echo "[runner] ABORT — jq not found. Looked in /usr/bin, /opt/homebrew/bin," >> "$LOG_FILE"
    echo "[runner] /usr/local/bin and ~/.local/bin. Install jq or set JQ=<path>." >> "$LOG_FILE"
    END=$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')
    {
        echo ""
        echo "----"
        echo "[$END] ROUTINE END: $ROUTINE  exit=5  (aborted: jq not found)"
        echo "================================================================"
        echo ""
    } >> "$LOG_FILE"
    exit 5
fi

# Secrets. launchd-runtime/secrets.env is the local, git-ignored file for them:
# KEY=value lines, as secrets.env.example shows. It is parsed, never sourced,
# so a line in it cannot run a command, and it is read only when nobody but
# its owner can read it. A Telegram credential it does not hold falls back to
# the env block of the Claude settings file, where both lived before this
# file existed. A value inherited from the caller's environment is never used:
# an interactive shell may carry a different bot's.
_SECRETS_SELF="$0"
while [[ -L "$_SECRETS_SELF" ]]; do
    _SECRETS_LINK=$(/usr/bin/readlink "$_SECRETS_SELF")
    [[ "$_SECRETS_LINK" == /* ]] || _SECRETS_LINK="$(/usr/bin/dirname "$_SECRETS_SELF")/$_SECRETS_LINK"
    _SECRETS_SELF="$_SECRETS_LINK"
done
SECRETS_FILE="${SECRETS_FILE:-$(/usr/bin/dirname "$_SECRETS_SELF")/../secrets.env}"
SECRETS_NOTE=""
if [[ -f "$SECRETS_FILE" ]]; then
    case "$(/usr/bin/stat -f '%Lp' "$SECRETS_FILE" 2>/dev/null)" in
        ?00) ;;
        *)   SECRETS_NOTE="ignored: readable by group or others (chmod 600 it)"
             SECRETS_FILE="" ;;
    esac
else
    SECRETS_FILE=""
fi
# _secret <KEY> — the last KEY=value line's value, with one pair of quotes removed.
_secret() {
    [[ -n "$SECRETS_FILE" ]] || return 0
    /usr/bin/sed -n "s/^$1=//p" "$SECRETS_FILE" | /usr/bin/tail -1 \
        | /usr/bin/sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}
TELEGRAM_BOT_TOKEN=$(_secret TELEGRAM_BOT_TOKEN)
TELEGRAM_CHAT_ID=$(_secret TELEGRAM_CHAT_ID)
[[ -n "$TELEGRAM_BOT_TOKEN" ]] || TELEGRAM_BOT_TOKEN=$("$JQ" -r '.env.TELEGRAM_BOT_TOKEN // ""' "$SETTINGS_FILE" 2>/dev/null || echo "")
[[ -n "$TELEGRAM_CHAT_ID" ]] || TELEGRAM_CHAT_ID=$("$JQ" -r '.env.TELEGRAM_CHAT_ID // ""' "$SETTINGS_FILE" 2>/dev/null || echo "")
export TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID
_TYPESAFE=$(_secret TYPESAFE_API_KEY)
[[ -n "$_TYPESAFE" ]] && export TYPESAFE_API_KEY="$_TYPESAFE"

# Machine identity. Resolved unconditionally: the ownership guard below
# compares against both, and every ledger row records which machine ran.
THIS_HOST=$(/bin/hostname -s)
# LC_ALL=C: `ioreg -l` carries bytes that are not UTF-8, and awk in a UTF-8
# locale warns about each on stderr, quoting the byte — noise in every run's
# stderr, and enough to break a strict decode of a test run's output.
THIS_SERIAL=$(/usr/sbin/ioreg -l 2>/dev/null | LC_ALL=C /usr/bin/awk -F'"' '/IOPlatformSerialNumber/{print $4}' | /usr/bin/head -1)

# Routine-ownership guard. Moving the scheduled pipeline to a dedicated
# machine is phased: for weeks, one Mac legitimately runs some routines and
# the other runs the rest. Two dispatchers picking the same `approved` issue
# produce duplicate PRs on identically-named task/issue-N branches, which is
# the one migration failure that corrupts state rather than wasting a night.
#
# .pipeline-host declares who owns what. Keep the SAME file on every machine
# (symlinking it into the repo is the tidy way) so there is one answer:
#
#     # comments and blank lines are ignored
#     WORKMAC001                        <- bare id: default owner, all routines
#     daily-summary-routine PIPEMAC002  <- per-routine owner, overrides default
#
# An identifier is either a short hostname or a hardware serial. Prefer the
# serial: macOS Bonjour renames collide-and-suffix, so two Macs named
# work-mac and -2 can swap names when one is off the network.
#
# No file, or no line that applies, means unguarded — a single-machine setup
# is unaffected. Bypass with _RUN_SKIP_HOST_CHECK=1 when testing off-host.
PIPELINE_HOST_FILE="${ROUTINE_DIR}/.pipeline-host"
if [[ -z "${_RUN_SKIP_HOST_CHECK:-}" ]] && [[ -f "$PIPELINE_HOST_FILE" ]]; then
    # bash 3.2 on macOS: no associative arrays, so scan the file once and
    # keep the two candidates.
    _default_owner=""
    _routine_owner=""
    while IFS= read -r _line || [[ -n "$_line" ]]; do
        _line="${_line%%#*}"
        _line=$(printf '%s' "$_line" | /usr/bin/awk '{$1=$1; print}')
        [[ -z "$_line" ]] && continue
        _first="${_line%% *}"
        if [[ "$_first" == "$_line" ]]; then
            _default_owner="$_first"
        else
            _rest=$(printf '%s' "${_line#* }" | /usr/bin/awk '{$1=$1; print}')
            if [[ "$_first" == "$ROUTINE" ]]; then
                _routine_owner="$_rest"
            fi
        fi
    done < "$PIPELINE_HOST_FILE"

    if [[ -n "$_routine_owner" ]]; then
        EXPECTED_HOST="$_routine_owner"
        _owner_scope="declared for $ROUTINE"
    else
        EXPECTED_HOST="$_default_owner"
        _owner_scope="the default owner"
    fi

    if [[ -n "$EXPECTED_HOST" ]] && [[ "$EXPECTED_HOST" != "$THIS_HOST" ]] && [[ "$EXPECTED_HOST" != "$THIS_SERIAL" ]]; then
        echo "[runner] ABORT — wrong host for this routine. $_owner_scope is '$EXPECTED_HOST';" >> "$LOG_FILE"
        echo "[runner] this is '$THIS_HOST' (serial $THIS_SERIAL)." >> "$LOG_FILE"
        echo "[runner] Unload $ROUTINE here, or correct $PIPELINE_HOST_FILE." >> "$LOG_FILE"

        # One alert per host per day — during a migration every routine would
        # otherwise fire one, and six identical Telegrams teach you to ignore them.
        HOST_ALERT_MARKER="${LOG_DIR}/.host-alerted-$(/bin/date +%Y-%m-%d)"
        if [[ ! -f "$HOST_ALERT_MARKER" ]] && [[ -n "$TELEGRAM_BOT_TOKEN" ]] && [[ -n "$TELEGRAM_CHAT_ID" ]]; then
            MSG="🚫 Routine SKIPPED on the wrong host: ${ROUTINE}
This is ${THIS_HOST}; that routine belongs to ${EXPECTED_HOST}.
Unload it here, or update .pipeline-host."
            /usr/bin/curl -s -m 30 -X POST "${TELEGRAM_API_URL}/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -H "Content-Type: application/json" \
                -d "$("$JQ" -n --arg c "$TELEGRAM_CHAT_ID" --arg t "$MSG" '{chat_id:$c, text:$t}')" \
                > /dev/null 2>&1 || true
            /usr/bin/touch "$HOST_ALERT_MARKER" 2>/dev/null || true
        fi

        END=$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')
        {
            echo ""
            echo "----"
            echo "[$END] ROUTINE END: $ROUTINE  exit=4  (aborted: wrong host for this routine)"
            echo "================================================================"
            echo ""
        } >> "$LOG_FILE"
        exit 4
    fi
fi

# Long-lived headless auth (R1). Interactive OAuth expires and took the
# routines down for two days in June 2026. `claude setup-token` mints a
# long-lived token; paste it into settings.json under
# .env.CLAUDE_CODE_OAUTH_TOKEN and every scheduled run authenticates with
# it (launchd jobs don't inherit shell env, so the settings file is the
# reliable channel — same as the Telegram creds above).
CLAUDE_CODE_OAUTH_TOKEN=$("$JQ" -r '.env.CLAUDE_CODE_OAUTH_TOKEN // ""' "$SETTINGS_FILE" 2>/dev/null || echo "")
if [[ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]]; then
    export CLAUDE_CODE_OAUTH_TOKEN
fi

START=$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')
START_EPOCH=$(/bin/date +%s)

# Asked for once: the log header and the ledger row must name the same CLI,
# and a second call could straddle an upgrade mid-run.
CLAUDE_VERSION=$("$CLAUDE_CLI" --version 2>&1 | /usr/bin/head -1)

{
    echo "================================================================"
    echo "[$START] ROUTINE START: $ROUTINE"
    echo "================================================================"
    echo "host:           $(/bin/hostname)"
    echo "user:           $(/usr/bin/whoami)"
    echo "pwd:            $(/bin/pwd)"
    echo "claude-cli:     $CLAUDE_VERSION"
    echo "telegram creds: token_len=${#TELEGRAM_BOT_TOKEN} chat_id=$TELEGRAM_CHAT_ID"
    [[ -z "$SECRETS_NOTE" ]] || echo "secrets.env:    $SECRETS_NOTE"
    echo "----"
} >> "$LOG_FILE"

# Run the prompt via claude-cli with three protections:
#
#   1. `caffeinate -i -w PID` prevents idle system sleep while claude-cli
#      runs. macOS sleep was killing API streaming connections silently:
#      we saw a real case on 2026-05-11 where night-dispatch's session
#      sat idle for 6.5 hours after the Mac slept right after launch,
#      then died with "Stream idle timeout - partial response received".
#      caffeinate is the actual fix for that class of failure.
#
#   2. **Wall-clock** watchdog. macOS `sleep` uses CLOCK_MONOTONIC which
#      pauses during system sleep — so a `sleep 1800` watchdog can take
#      6+ wall-clock hours to fire. We poll `date +%s` every 30s instead.
#      Belt-and-suspenders if caffeinate fails for any reason.
#
#   3. Process group kill. `set -m` puts claude-cli in its own pgroup so
#      `kill -PGID` reaches every descendant (find orphans, npm children,
#      etc.) — we hit that bug on 2026-05-10 with an 8.5h orphan find.
#
# Default timeout: 1800s (30 min). Override via env ROUTINE_TIMEOUT_SECONDS.
TIMEOUT_SECONDS="${ROUTINE_TIMEOUT_SECONDS:-1800}"

PROMPT_CONTENT=$(/bin/cat "$PROMPT_FILE")

echo "[runner] timeout: ${TIMEOUT_SECONDS}s (wall-clock)" >> "$LOG_FILE"

# Reasoning effort. The CLI accepts exactly these five values; anything else
# it merely WARNS about and then runs at its default, which is a silent
# downgrade repeated every night until someone reads a log. Reject it here,
# before the canary and the run spend anything on a typo.
EFFORT="${ROUTINE_EFFORT:-high}"
case "$EFFORT" in
    low|medium|high|xhigh|max) ;;
    *)
        echo "[runner] ABORT — invalid ROUTINE_EFFORT='$EFFORT' (low|medium|high|xhigh|max)" >> "$LOG_FILE"
        END=$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')
        {
            echo ""
            echo "----"
            echo "[$END] ROUTINE END: $ROUTINE  exit=6  (aborted: invalid ROUTINE_EFFORT)"
            echo "================================================================"
            echo ""
        } >> "$LOG_FILE"
        exit 6
        ;;
esac

# AC-power precheck.
#
# caffeinate -s is documented as "valid only when running on AC power".
# On battery the strongest sleep-prevention assertion silently no-ops,
# the Mac slides into deep idle / standby, and the routine hangs until
# the watchdog kills it — wasting the full budget. We saw this on
# 2026-05-21: Mac briefly switched to BATT overnight, all four morning
# routines hung 4927s and got watchdog-killed at the same instant.
#
# Fail fast instead: if not on AC, send a short Telegram, exit 3,
# don't even start claude-cli. SET _RUN_SKIP_AC_CHECK=1 in the
# environment if you genuinely want to test the runner on battery.
if [[ -z "${_RUN_SKIP_AC_CHECK:-}" ]] && [[ -x /usr/bin/pmset ]]; then
    PWR_SOURCE=$(/usr/bin/pmset -g batt 2>/dev/null | /usr/bin/head -1)
    if [[ "$PWR_SOURCE" != *"AC Power"* ]]; then
        echo "[runner] ABORT — not on AC. Power source: $PWR_SOURCE" >> "$LOG_FILE"
        echo "[runner] caffeinate -s is a no-op on battery; overnight routines hang." >> "$LOG_FILE"
        echo "[runner] Re-plug the laptop or set _RUN_SKIP_AC_CHECK=1 to bypass." >> "$LOG_FILE"

        # Best-effort Telegram so the user knows
        TELEGRAM_BOT_TOKEN=$("$JQ" -r '.env.TELEGRAM_BOT_TOKEN // ""' "$SETTINGS_FILE" 2>/dev/null || echo "")
        TELEGRAM_CHAT_ID=$("$JQ" -r '.env.TELEGRAM_CHAT_ID // ""' "$SETTINGS_FILE" 2>/dev/null || echo "")
        if [[ -n "$TELEGRAM_BOT_TOKEN" ]] && [[ -n "$TELEGRAM_CHAT_ID" ]]; then
            MSG="⚡ Routine SKIPPED: ${ROUTINE}
Mac is on battery (caffeinate -s is no-op on DC power).
Re-plug the laptop and re-trigger if you need this run."
            # -m 30: this exact alert once hung 46 minutes; never block.
            /usr/bin/curl -s -m 30 -X POST "${TELEGRAM_API_URL}/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -H "Content-Type: application/json" \
                -d "$("$JQ" -n --arg c "$TELEGRAM_CHAT_ID" --arg t "$MSG" '{chat_id:$c, text:$t}')" \
                > /dev/null 2>&1 || true
        fi

        # Close out the log normally so routines-status shows a clean line
        END=$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')
        {
            echo ""
            echo "----"
            echo "[$END] ROUTINE END: $ROUTINE  exit=3  (aborted: not on AC)"
            echo "================================================================"
            echo ""
        } >> "$LOG_FILE"
        exit 3
    fi
    echo "[runner] AC power confirmed: $PWR_SOURCE" >> "$LOG_FILE"
fi

# Kill a process and ALL its descendants. Walks the tree with pgrep,
# kills bottom-up so parents can't re-spawn children faster than we kill.
# More robust on macOS than `kill -PGID`: subshells don't always become
# pgroup leaders, and child processes (e.g. bash spawning a backgrounded
# `find &`) can land in their own pgroups regardless.
kill_tree() {
    local root=$1
    local sig=${2:-TERM}
    local pids=("$root")
    local frontier=("$root")
    while [[ ${#frontier[@]} -gt 0 ]]; do
        local next=()
        for p in "${frontier[@]}"; do
            for c in $(/usr/bin/pgrep -P "$p" 2>/dev/null); do
                pids+=("$c")
                next+=("$c")
            done
        done
        # Under `set -u`, expanding an empty array is an unbound-variable
        # error. Bail before that assignment if there are no descendants.
        if [[ ${#next[@]} -eq 0 ]]; then
            break
        fi
        frontier=("${next[@]}")
    done
    # Kill bottom-up (children before parents)
    for ((i=${#pids[@]}-1; i>=0; i--)); do
        /bin/kill "-$sig" "${pids[i]}" 2>/dev/null || true
    done
}
export -f kill_tree 2>/dev/null || true  # so watchdog subshell sees it

# Precheck: a cheap script that decides whether there is work before a model is
# started. Between 2026-09-14 and 26 the review and iterate routines spent $88
# on full Opus sessions on nights with no agent PR to act on, and dispatch paid
# for eight nights whose gate read eligible=-. The script owns that question;
# the runner only honours its answer.
#
#   ROUTINE_PRECHECK         an executable, absolute or relative to this bin/
#   exit 10                  nothing to do: its stdout (the routine's contract
#                            line) goes to the log, a zero-cost `skipped` row
#                            goes to the ledger, and the run ends here, exit 0
#   exit 0                   work exists: continue to the canary and the model
#   anything else, or a hang the model runs anyway, after a WARN — a broken
#                            precheck must never pass for an idle night
#   ROUTINE_PRECHECK_SHADOW  =1: log what the precheck decided, always run the
#                            model; how a new precheck earns trust before it
#                            is allowed to skip anything
#
# Before the canary on purpose: a skipped night costs no CLI call at all.
if [[ -n "${ROUTINE_PRECHECK:-}" ]]; then
    PRECHECK="$ROUTINE_PRECHECK"
    if [[ "$PRECHECK" != /* ]]; then
        # Beside THIS script, through the symlink install.sh leaves in the
        # routines dir — the same resolution the deny-net uses below.
        _pc_self="$0"
        while [[ -L "$_pc_self" ]]; do
            _pc_link=$(/usr/bin/readlink "$_pc_self")
            [[ "$_pc_link" == /* ]] || _pc_link="$(/usr/bin/dirname "$_pc_self")/$_pc_link"
            _pc_self="$_pc_link"
        done
        PRECHECK="$(/usr/bin/dirname "$_pc_self")/$PRECHECK"
    fi
    PRECHECK_OUT="$LOG_DIR/.precheck-${ROUTINE}.out"
    PRECHECK_TIMEOUT="${ROUTINE_PRECHECK_TIMEOUT:-300}"
    PRECHECK_STATUS=0
    if [[ ! -x "$PRECHECK" ]]; then
        PRECHECK_STATUS=127
        echo "precheck not executable: $PRECHECK" > "$PRECHECK_OUT"
    else
        ROUTINE="$ROUTINE" "$PRECHECK" > "$PRECHECK_OUT" 2>&1 &
        _pc_pid=$!
        _pc_t0=$(/bin/date +%s)
        _pc_hung=""
        while /bin/kill -0 "$_pc_pid" 2>/dev/null; do
            if [[ $(( $(/bin/date +%s) - _pc_t0 )) -gt "$PRECHECK_TIMEOUT" ]]; then
                _pc_hung=1
                kill_tree "$_pc_pid" KILL
                break
            fi
            /bin/sleep 1
        done
        wait "$_pc_pid" 2>/dev/null
        PRECHECK_STATUS=$?
        # kill_tree goes bottom-up, so the script can outlive its child by a
        # moment and still exit 10. A precheck that hung has decided nothing.
        if [[ -n "$_pc_hung" ]]; then
            PRECHECK_STATUS=124
            echo "precheck hung past ${PRECHECK_TIMEOUT}s" > "$PRECHECK_OUT"
        fi
    fi
    PRECHECK_LINE=$(/usr/bin/head -1 "$PRECHECK_OUT" 2>/dev/null)

    if [[ "$PRECHECK_STATUS" -eq 10 && -n "${ROUTINE_PRECHECK_SHADOW:-}" ]]; then
        echo "[runner] precheck (shadow) would skip: ${PRECHECK_LINE:-no reason given} — running the model anyway" >> "$LOG_FILE"
    elif [[ "$PRECHECK_STATUS" -eq 10 ]]; then
        {
            echo "[runner] precheck: nothing to do — model not started"
            /bin/cat "$PRECHECK_OUT"
        } >> "$LOG_FILE"
        END_EPOCH=$(/bin/date +%s)
        DURATION=$((END_EPOCH - START_EPOCH))
        END=$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')
        "$JQ" -nc --arg r "$ROUTINE" --arg ts "$END" --arg dur "$DURATION" \
            --arg rid "${ROUTINE}-${END_EPOCH}-$$" --arg host "$THIS_HOST" --arg serial "$THIS_SERIAL" \
            --arg effort "${ROUTINE_EFFORT:-high}" --arg model "${ROUTINE_MODEL:-claude-opus-4-8}" \
            --arg ver "$CLAUDE_VERSION" --arg why "$PRECHECK_LINE" '
            { routine: $r, ts: $ts, exit: 0, duration_s: ($dur | tonumber),
              run_id: $rid, host: $host, serial: $serial,
              model_requested: $model, effort_requested: $effort, claude_version: $ver,
              cost_usd: 0, subtype: "skipped", skip_reason: $why }
        ' >> "${METRICS_DIR}/runs.jsonl" 2>/dev/null || true
        {
            echo ""
            echo "----"
            echo "[$END] ROUTINE END: $ROUTINE  exit=0  duration=${DURATION}s  (skipped: precheck)"
            echo "================================================================"
            echo ""
        } >> "$LOG_FILE"
        exit 0
    elif [[ "$PRECHECK_STATUS" -ne 0 ]]; then
        echo "[runner] WARN — precheck exited ${PRECHECK_STATUS}; running the model anyway: ${PRECHECK_LINE:-no output}" >> "$LOG_FILE"
    else
        echo "[runner] precheck: work found — ${PRECHECK_LINE:-continuing}" >> "$LOG_FILE"
    fi
fi

# Auth pre-flight canary.
#
# 2026-06-24/25: an expired OAuth token made every routine fail in 3-5s
# with a 401 for two straight days — 10 lost runs and 10 identical generic
# alerts. Four 2026-07-06 stalls were the same auth path hanging. Probe
# with the cheapest model before spending the real budget: if auth is
# broken, abort with ONE actionable alert per day (marker-file dedup) and
# a distinct exit code (4). Set _RUN_SKIP_AUTH_CANARY=1 to bypass
# (test fixtures, quick manual runs on a known-good login).
if [[ -z "${_RUN_SKIP_AUTH_CANARY:-}" ]]; then
    CANARY_OUT="$LOG_DIR/.auth-canary-${ROUTINE}.out"
    # Per-attempt watchdog — the canary itself must never hang the routine.
    # Same wall-clock poll + kill_tree approach as the main watchdog (macOS
    # has no `timeout` binary; `sleep` pauses during system sleep). A healthy
    # canary answers in seconds, so a timed-out attempt is itself a signal:
    # the 2026-07-06 stalls hung in the auth path BEFORE emitting anything,
    # and in -p print mode a hung run is indistinguishable from a healthy
    # silent one — this pre-flight is where that class gets caught. One
    # retry absorbs a transient blip; two straight hangs abort the run.
    CANARY_TIMEOUT="${CANARY_TIMEOUT:-60}"
    CANARY_HANGS=0
    CANARY_EXIT=1
    for CANARY_ATTEMPT in 1 2; do
        CANARY_T0=$(/bin/date +%s)
        (
            set -m
            # caffeinate wraps the canary directly (exits with it): the
            # main run's caffeinate only starts after the spawn below, and
            # an unguarded ~2min canary window reopens the maintenance-
            # sleep class documented at the main spawn (2026-05-13).
            /usr/bin/caffeinate -s -d -i "$CLAUDE_CLI" -p 'ok' --model claude-haiku-4-5 > "$CANARY_OUT" 2>&1
        ) &
        CANARY_PID=$!
        (
            while /bin/kill -0 "$CANARY_PID" 2>/dev/null; do
                /bin/sleep 2
                if [[ $(( $(/bin/date +%s) - CANARY_T0 )) -gt "$CANARY_TIMEOUT" ]]; then
                    echo "[runner] auth canary attempt ${CANARY_ATTEMPT} hit its ${CANARY_TIMEOUT}s watchdog — killing it" >> "$LOG_FILE"
                    kill_tree "$CANARY_PID" TERM
                    /bin/sleep 2
                    /bin/kill -0 "$CANARY_PID" 2>/dev/null && kill_tree "$CANARY_PID" KILL
                    break
                fi
            done
        ) &
        CANARY_WATCHDOG_PID=$!
        wait "$CANARY_PID"
        CANARY_EXIT=$?
        /bin/kill "$CANARY_WATCHDOG_PID" 2>/dev/null || true
        wait "$CANARY_WATCHDOG_PID" 2>/dev/null || true

        if [[ "$CANARY_EXIT" -eq 0 ]]; then
            break
        fi
        if [[ $(( $(/bin/date +%s) - CANARY_T0 )) -ge "$CANARY_TIMEOUT" ]]; then
            CANARY_HANGS=$((CANARY_HANGS + 1))
            continue  # hung attempt — retry once; second hang aborts below
        fi
        break  # fast failure — classified below, no retry
    done

    CANARY_ABORT=""
    if [[ "$CANARY_EXIT" -ne 0 ]] && /usr/bin/grep -qiE 'authenticat|401' "$CANARY_OUT" 2>/dev/null; then
        CANARY_ABORT="auth"
    elif [[ "$CANARY_HANGS" -ge 2 ]]; then
        CANARY_ABORT="hang"
    fi

    if [[ -n "$CANARY_ABORT" ]]; then
        if [[ "$CANARY_ABORT" == "hang" ]]; then
            echo "[runner] ABORT — auth canary hung twice (${CANARY_TIMEOUT}s each): network down or auth path stalled" >> "$LOG_FILE"
        else
            echo "[runner] ABORT — auth canary failed (exit=$CANARY_EXIT):" >> "$LOG_FILE"
        fi
        /usr/bin/head -5 "$CANARY_OUT" >> "$LOG_FILE" 2>/dev/null

        # ONE alert per day across all routines — the marker file dedups
        # (the 2026-06 outage sent 10 identical generic alerts).
        ALERT_MARKER="$LOG_DIR/.auth-alerted-$(/bin/date +%Y-%m-%d)"
        if [[ ! -f "$ALERT_MARKER" ]] && [[ -n "$TELEGRAM_BOT_TOKEN" ]] && [[ -n "$TELEGRAM_CHAT_ID" ]]; then
            if [[ "$CANARY_ABORT" == "hang" ]]; then
                MSG="🔌 CANARY HUNG twice on $(/bin/hostname) — network down or auth path stalled; check connectivity, then claude setup-token / claude login; routines suspended"
            else
                MSG="🔑 AUTH EXPIRED on $(/bin/hostname) — run claude setup-token or claude login; routines suspended"
            fi
            /usr/bin/curl -s -m 30 -X POST "${TELEGRAM_API_URL}/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                -H "Content-Type: application/json" \
                -d "$("$JQ" -n --arg c "$TELEGRAM_CHAT_ID" --arg t "$MSG" '{chat_id:$c, text:$t}')" \
                > /dev/null 2>&1 || true
            /usr/bin/touch "$ALERT_MARKER"
        fi

        # Close out the log normally so routines-status shows a clean line
        END=$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')
        {
            echo ""
            echo "----"
            echo "[$END] ROUTINE END: $ROUTINE  exit=4  (aborted: auth canary)"
            echo "================================================================"
            echo ""
        } >> "$LOG_FILE"
        exit 4
    elif [[ "$CANARY_EXIT" -ne 0 ]]; then
        # Non-auth canary failure (flake, network blip): note it and let
        # the main run proceed — its own watchdogs catch real problems.
        echo "[runner] WARN — auth canary failed (exit=$CANARY_EXIT) without an auth signature; continuing" >> "$LOG_FILE"
    else
        echo "[runner] auth canary passed" >> "$LOG_FILE"
    fi
fi

# ── Headless deny-net ─────────────────────────────────────────────────────
# The rules, and the reasoning behind each family, live in
# `bin/headless-deny.sh`: one list, read here and by `tests/smoke/run-smoke.sh`,
# so the smoke gate cannot drift away from what the routines actually run
# under. Resolved beside THIS script — through the symlink install.sh leaves in
# the routines dir — rather than hardcoded, so a second checkout tests its own
# copy. `HEADLESS_DENY_FILE` overrides it for the test harness.
_RUN_SELF="$0"
while [[ -L "$_RUN_SELF" ]]; do
    _RUN_LINK=$(/usr/bin/readlink "$_RUN_SELF")
    [[ "$_RUN_LINK" == /* ]] || _RUN_LINK="$(/usr/bin/dirname "$_RUN_SELF")/$_RUN_LINK"
    _RUN_SELF="$_RUN_LINK"
done
DENY_FILE="${HEADLESS_DENY_FILE:-$(/usr/bin/dirname "$_RUN_SELF")/headless-deny.sh}"
# The prompts name runtime scripts as $AGENTIC_SKILLS_ROOT/launchd-runtime/...,
# so no prompt carries one machine's checkout path. The Bash tool inherits it.
export AGENTIC_SKILLS_ROOT="${AGENTIC_SKILLS_ROOT:-$(cd "$(/usr/bin/dirname "$_RUN_SELF")/../.." 2>/dev/null && pwd -P)}"
if [[ ! -r "$DENY_FILE" ]]; then
    # Starting without the deny-net is worse than not starting: it is the one
    # part of the boundary that holds whatever the model does. Refuse, loudly.
    echo "[runner] ABORT — deny-net not readable: $DENY_FILE" >> "$LOG_FILE"
    END=$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')
    {
        echo ""
        echo "----"
        echo "[$END] ROUTINE END: $ROUTINE  exit=2  (aborted: deny-net missing)"
        echo "================================================================"
        echo ""
    } >> "$LOG_FILE"
    exit 2
fi
. "$DENY_FILE"

# Two hooks ride in the same --settings as the deny-net, which reaches the
# headless run without touching ~/.claude/settings.json. Both fire under
# `claude -p` (verified 2026-09-13 and 2026-11-12).
#
#   PostToolUseFailure -> bin/record-tool-failure: a failed tool call — a Read
#     of a file that is not there, a command that exits non-zero — never
#     reaches the JSON envelope, so this records it to the friction ledger.
#   PostToolUse -> bin/record-tool-call: a call that worked left nothing at
#     all, so a run's time could not be placed on its steps. This records the
#     tool, its duration and a short label; bin/run-trace reads both back.
#
# Each is added on its own: a missing recorder costs its ledger, never the run
# and never the other hook.
RUN_SETTINGS="$HEADLESS_DENY"
# _add_hook <event> <recorder> <what to log when the recorder is missing>
_add_hook() {
    local recorder next
    recorder="$(/usr/bin/dirname "$_RUN_SELF")/$2"
    if [[ ! -x "$recorder" ]]; then
        echo "[runner] WARN — $3: $recorder" >> "$LOG_FILE"
        return 0
    fi
    next=$("$JQ" -c --arg ev "$1" --arg cmd "/usr/bin/python3 '$recorder' '$METRICS_DIR'" \
        '.hooks = ((.hooks // {}) + {($ev): [{matcher: "*", hooks: [{type: "command", command: $cmd}]}]})' \
        <<< "$RUN_SETTINGS" 2>/dev/null)
    [[ -n "$next" ]] && RUN_SETTINGS="$next"
    return 0
}
_add_hook PostToolUseFailure record-tool-failure "tool-failure recorder missing, no friction rows this run"
_add_hook PostToolUse        record-tool-call    "tool-call recorder missing, no trace rows this run"

# Spawn the CLI in its own process group.
#
#   --effort: reasoning effort. A skill declares its own `effort:` in
#     SKILL.md frontmatter and that wins the moment it loads, so this flag
#     covers the wrapper turn only. Override via ROUTINE_EFFORT (validated
#     above — the CLI itself would only warn and run at its default).
#   --model: pin the model instead of inheriting whatever was last set
#     interactively in ~/.claude/settings.json. Unpinned runs drifted
#     across three models and cost a measured $13/30d extra (2026-07-14
#     assessment, C1). Override per routine via ROUTINE_MODEL in the plist.
#   --max-budget-usd: per-run spend cap — the worst unbounded run burned
#     8.9 hours (2026-05-10). A runaway guard, not a tight budget: the
#     costliest healthy run measured ≈$2-3 at Opus pricing, so 5.00 leaves
#     headroom (a 2.00 cap would truncate long dispatch/proposals runs).
#     Override via ROUTINE_MAX_BUDGET_USD (C3).
#   --output-format json (opt-in, ROUTINE_CAPTURE_JSON): makes the CLI report
#     its own spend. Without it total_cost_usd, modelUsage, num_turns and
#     permission_denials are all produced and discarded, and the runner records
#     only exit= and duration=.
CAPTURE_JSON="${ROUTINE_CAPTURE_JSON:-}"
METRICS_FILE=""

# One epoch for the whole run: it names the sidecar and anchors the id exported
# to the CLI, so a skill's own writes, the sidecar and the ledger row all join
# on the same key without anyone having to correlate timestamps. The pid is
# what keeps the id unique — a manual run started in the same second as the
# scheduled one shares the epoch, and one of the two rows would be unreadable.
RUN_EPOCH=$(/bin/date +%s)
ROUTINE_RUN_ID="${ROUTINE}-${RUN_EPOCH}-$$"
export ROUTINE ROUTINE_RUN_ID

# Resolved once so the flags passed and the fields recorded cannot disagree.
MODEL_REQUESTED="${ROUTINE_MODEL:-claude-opus-4-8}"
BUDGET_USD="${ROUTINE_MAX_BUDGET_USD:-5.00}"

# One argv, two redirect paths — listing the flags twice would let them drift.
CLI_ARGS=(
    -p "$PROMPT_CONTENT"
    --dangerously-skip-permissions
    --settings "$RUN_SETTINGS"
    --effort "$EFFORT"
    --model "$MODEL_REQUESTED"
    --max-budget-usd "$BUDGET_USD"
)
if [[ -n "$CAPTURE_JSON" ]]; then
    METRICS_FILE="${METRICS_DIR}/${ROUTINE}-$(/bin/date +%Y-%m-%d)-${RUN_EPOCH}.json"
    CLI_ARGS+=(--output-format json)
fi

(
    set -m
    if [[ -n "$CAPTURE_JSON" ]]; then
        # stdout carries the JSON envelope, so it goes to the sidecar; stderr
        # keeps appending to the log exactly as before.
        "$CLAUDE_CLI" "${CLI_ARGS[@]}" > "$METRICS_FILE" 2>> "$LOG_FILE"
    else
        "$CLAUDE_CLI" "${CLI_ARGS[@]}" >> "$LOG_FILE" 2>&1
    fi
) &
CLAUDE_PID=$!

# Caffeinate: hold three sleep-prevention assertions for as long as
# claude-cli runs. `-w PID` makes caffeinate self-terminate when the
# watched process exits, so no cleanup is needed.
#
# Why all three flags on this Mac:
#   -s  PreventSystemSleep — prevents ALL system sleep transitions,
#       including 'Maintenance Sleep' (the TCPKeepAlive-driven dark-wake-
#       to-sleep cycle that hit us on 2026-05-13: log showed "Entering
#       Sleep state due to 'Maintenance Sleep'" at 04:00:02, two seconds
#       before our routines started). -i and -d do NOT prevent maintenance
#       sleep. -s is the right hammer. Valid only on AC power, which our
#       docked Mac always is.
#   -i  PreventUserIdleSystemSleep — defends idle-sleep path on battery
#       (where -s is a no-op). Belt-and-suspenders.
#   -d  PreventUserIdleDisplaySleep — keeps the OS-level display
#       assertion alive so external-monitor DPMS doesn't trigger any
#       lingering clamshell-sleep paths. With lid OPEN this is largely
#       redundant (internal display is always present), but kept as
#       defence-in-depth for the lid-closed-anyway scenario.
if [[ -x /usr/bin/caffeinate ]]; then
    /usr/bin/caffeinate -s -d -i -w "$CLAUDE_PID" &
    CAFFEINATE_PID=$!
    echo "[runner] caffeinate -s -d -i -w $CLAUDE_PID started (pid $CAFFEINATE_PID)" >> "$LOG_FILE"
fi

# Wall-clock watchdog: poll periodically, kill the tree if elapsed > budget.
# We use `date +%s` (real time) instead of `sleep $TIMEOUT_SECONDS` (which
# pauses during macOS sleep, defeating the purpose).
#
# Poll interval is adaptive: fast (every 2s) for short timeouts so tests
# don't have to wait 30s to verify; capped at 30s for production timeouts
# where polling overhead doesn't matter.
POLL_INTERVAL=$(( TIMEOUT_SECONDS / 2 ))
[[ "$POLL_INTERVAL" -lt 2 ]] && POLL_INTERVAL=2
[[ "$POLL_INTERVAL" -gt 30 ]] && POLL_INTERVAL=30
echo "[runner] watchdog poll interval: ${POLL_INTERVAL}s" >> "$LOG_FILE"

# NOTE on stall detection: a first-output/log-growth stall check was tried
# here and reverted before landing. In -p print mode the CLI writes NOTHING
# until completion, so "no output yet" cannot distinguish a hung run from a
# healthy one (morning-proposals runs healthily silent for 287s median /
# 520s p95). The 2026-07-06 zero-output stall class is caught by the auth
# canary above instead: a canary that hangs twice aborts the run in ~2×
# CANARY_TIMEOUT before the real budget is spent.

# A killed CLI cannot write its own JSON envelope, so the cost block below has
# nothing to derive a ledger row from. The watchdog runs in a subshell and
# cannot set a variable in the parent — it leaves this marker instead, beside
# the sidecar it stands in for and part of the same run record. Only a capture
# run writes a ledger row, so only a capture run has anything to mark.
WATCHDOG_MARKER=""
if [[ -n "$METRICS_FILE" ]]; then
    WATCHDOG_MARKER="${METRICS_FILE%.json}.timeout"
fi

(
    START_TS=$(/bin/date +%s)
    while /bin/kill -0 "$CLAUDE_PID" 2>/dev/null; do
        /bin/sleep "$POLL_INTERVAL"
        NOW=$(/bin/date +%s)
        ELAPSED=$((NOW - START_TS))
        if [[ "$ELAPSED" -gt "$TIMEOUT_SECONDS" ]]; then
            echo "[runner] TIMEOUT after ${ELAPSED}s wall-clock (budget=${TIMEOUT_SECONDS}s) — SIGTERM to tree rooted at $CLAUDE_PID" >> "$LOG_FILE"
            if [[ -n "$WATCHDOG_MARKER" ]]; then
                /usr/bin/touch "$WATCHDOG_MARKER" 2>/dev/null || true
            fi
            kill_tree "$CLAUDE_PID" TERM
            /bin/sleep 5
            if /bin/kill -0 "$CLAUDE_PID" 2>/dev/null; then
                echo "[runner] still alive after SIGTERM — SIGKILL the tree" >> "$LOG_FILE"
                kill_tree "$CLAUDE_PID" KILL
            fi
            break
        fi
    done
) &
WATCHDOG_PID=$!

# Wait for the CLI to finish (whether naturally or via watchdog).
wait "$CLAUDE_PID"
EXIT=$?

# Tear down the watchdog if it's still around.
/bin/kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true
# caffeinate auto-exits when CLAUDE_PID exits (see -w flag); explicit kill is paranoia.
[[ -n "${CAFFEINATE_PID:-}" ]] && /bin/kill "$CAFFEINATE_PID" 2>/dev/null || true

END_EPOCH=$(/bin/date +%s)
DURATION=$((END_EPOCH - START_EPOCH))
END=$(/bin/date '+%Y-%m-%d %H:%M:%S %Z')

END_NOTE=""

# Cost capture. This block only ever APPENDS to the log; it must never divert
# output away from it, because the failure alert below tails $LOG_FILE and an
# empty tail is a failure report with no failure in it.
#
# Branch on ERROR STATE, not on parseability. The CLI's structured failure
# envelope is itself valid JSON (subtype "error_max_budget_usd", is_error true),
# so "did it parse?" takes the happy path on exactly the runs that most need
# their reason written down.
if [[ -n "$CAPTURE_JSON" ]]; then
    # What the run was ASKED for, alongside what it did. Skills now route
    # themselves (their own model:/effort: frontmatter wins in-run), so a row
    # that records only the outcome cannot say which request produced it.
    # Shared by both writers below: one list, no drift between them.
    LEDGER_ARGS=(
        --arg r "$ROUTINE" --arg ts "$END" --arg ex "$EXIT" --arg dur "$DURATION"
        --arg rid "$ROUTINE_RUN_ID" --arg host "$THIS_HOST" --arg serial "$THIS_SERIAL"
        --arg model "$MODEL_REQUESTED" --arg effort "$EFFORT" --arg budget "$BUDGET_USD"
        --arg ver "$CLAUDE_VERSION" --arg f "$METRICS_FILE"
    )

    if [[ -s "$METRICS_FILE" ]] && "$JQ" -e . "$METRICS_FILE" > /dev/null 2>&1; then
        COST_LINE=$("$JQ" -r "${LEDGER_ARGS[@]}" '
            (.modelUsage // {}) as $m
            | (([$m[] | .inputTokens // 0]              | add) // 0) as $in
            | (([$m[] | .outputTokens // 0]             | add) // 0) as $out
            | (([$m[] | .cacheReadInputTokens // 0]     | add) // 0) as $cr
            | (([$m[] | .cacheCreationInputTokens // 0] | add) // 0) as $cw
            | (($m | keys | join(",")) | if . == "" then "-" else . end) as $models
            | "ROUTINE COST: \($r) cost_usd=\(.total_cost_usd // 0) in=\($in) out=\($out) cache_read=\($cr) cache_write=\($cw) turns=\(.num_turns // 0) model=\($models) subtype=\(.subtype // "-") denials=\((.permission_denials // []) | length) effort=\($effort) stop_reason=\(.stop_reason // "-") terminal_reason=\(.terminal_reason // "-") run_id=\($rid)"
        ' "$METRICS_FILE" 2>/dev/null)
        [[ -n "$COST_LINE" ]] && echo "$COST_LINE" >> "$LOG_FILE"

        "$JQ" -c "${LEDGER_ARGS[@]}" '
            (.modelUsage // {}) as $m
            | { routine: $r, ts: $ts, exit: ($ex | tonumber), duration_s: ($dur | tonumber),
                run_id: $rid, host: $host, serial: $serial,
                model_requested: $model, effort_requested: $effort,
                budget_usd: ($budget | tonumber? // null), claude_version: $ver,
                cost_usd: (.total_cost_usd // 0), turns: (.num_turns // 0),
                subtype: (.subtype // null), is_error: (.is_error // null),
                api_error_status: (.api_error_status // null),
                terminal_reason: (.terminal_reason // null),
                stop_reason: (.stop_reason // null),
                models: ($m | keys),
                input_tokens:       (([$m[] | .inputTokens // 0]              | add) // 0),
                output_tokens:      (([$m[] | .outputTokens // 0]             | add) // 0),
                cache_read_tokens:  (([$m[] | .cacheReadInputTokens // 0]     | add) // 0),
                cache_write_tokens: (([$m[] | .cacheCreationInputTokens // 0] | add) // 0),
                denials: ((.permission_denials // []) | length),
                session_id: (.session_id // null), sidecar: $f }
        ' "$METRICS_FILE" >> "${METRICS_DIR}/runs.jsonl" 2>/dev/null || true

        # The denials themselves, one row each — the row above only counts
        # them. skills/daily-summary/scripts/friction reads this for a rule that keeps
        # blocking the same routine.
        "$JQ" -c "${LEDGER_ARGS[@]}" '
            (.permission_denials // [])[]
            | { ts: $ts, routine: $r, run_id: $rid,
                tool: (.tool_name // .toolName // null),
                input: ((.tool_input // .toolInput // {}) | tojson | .[0:300]) }
        ' "$METRICS_FILE" >> "${METRICS_DIR}/denials.jsonl" 2>/dev/null || true

        # Parsed, but the run still failed: put the reason in the log too, so
        # the Telegram tail says what went wrong rather than just that it did.
        IS_ERROR=$("$JQ" -r '.is_error // false' "$METRICS_FILE" 2>/dev/null)
        if [[ "$EXIT" -ne 0 ]] || [[ "$IS_ERROR" == "true" ]]; then
            {
                echo "[runner] run reported an error — from the JSON envelope:"
                "$JQ" -r '"  subtype: \(.subtype // "-")",
                          "  api_error_status: \(.api_error_status // "-")",
                          "  result: \(.result // "-")"' "$METRICS_FILE" 2>/dev/null
            } >> "$LOG_FILE"
        else
            # Without capture the run's final text streams into the log; with
            # it, stdout is the envelope and lands in the sidecar. Copied back,
            # so the log keeps what the run said: daily-review-nudge reads its
            # own previous logs for it.
            "$JQ" -r '.result // empty' "$METRICS_FILE" >> "$LOG_FILE" 2>/dev/null || true

            # Only the final message is the run's result, so a contract line the
            # routine printed in an earlier turn, or inside a sentence, is lost.
            # Say so here, where the next reader of the log will see it (#52).
            # bin/routine-contracts.tsv is the table the smoke gate enforces.
            CONTRACTS_FILE="${ROUTINE_CONTRACTS_FILE:-$(/usr/bin/dirname "$_RUN_SELF")/routine-contracts.tsv}"
            if [[ -r "$CONTRACTS_FILE" ]]; then
                RESULT_TEXT=$("$JQ" -r '.result // ""' "$METRICS_FILE" 2>/dev/null)
                while IFS= read -r _group; do
                    [[ -z "$_group" || "$_group" == "-" ]] && continue
                    if ! printf '%s' "$RESULT_TEXT" | /usr/bin/grep -qE -- "^[[:space:]]*($_group)"; then
                        echo "[runner] WARN — the final message has no ${_group//|/ or } line (bin/routine-contracts.tsv)" >> "$LOG_FILE"
                    fi
                done < <(LC_ALL=C /usr/bin/awk -F'\t' -v r="$ROUTINE" '$1 == r {print $2}' "$CONTRACTS_FILE")
            fi
        fi
    else
        # Unparseable or empty: the CLI wrote something we cannot read, and it
        # is the only record of what happened. Put it in the log verbatim.
        {
            echo "[runner] WARN — cost sidecar unreadable; raw CLI stdout follows:"
            /usr/bin/head -40 "$METRICS_FILE" 2>/dev/null || echo "  (sidecar empty or missing)"
        } >> "$LOG_FILE"

        # A watchdog kill lands here every time — the CLI never got to write
        # its envelope — and those are precisely the runs that spent the whole
        # budget, so leaving them out of the ledger hides the worst spenders.
        # Write the row from what the runner itself knows.
        if [[ -f "$WATCHDOG_MARKER" ]]; then
            "$JQ" -nc "${LEDGER_ARGS[@]}" '
                { routine: $r, ts: $ts, exit: ($ex | tonumber), duration_s: ($dur | tonumber),
                  run_id: $rid, host: $host, serial: $serial,
                  model_requested: $model, effort_requested: $effort,
                  budget_usd: ($budget | tonumber? // null), claude_version: $ver,
                  cost_usd: null, subtype: "watchdog_timeout", sidecar: $f }
            ' >> "${METRICS_DIR}/runs.jsonl" 2>/dev/null || true
            echo "[runner] ledger row written as subtype=watchdog_timeout (no envelope to cost)" >> "$LOG_FILE"
        fi
    fi
fi

{
    echo ""
    echo "----"
    echo "[$END] ROUTINE END: $ROUTINE  exit=$EXIT  duration=${DURATION}s${END_NOTE}"
    echo "================================================================"
    echo ""
} >> "$LOG_FILE"

# On failure, send a Telegram alert with the log tail.
if [[ "$EXIT" -ne 0 ]] && [[ -n "$TELEGRAM_BOT_TOKEN" ]] && [[ -n "$TELEGRAM_CHAT_ID" ]]; then
    TAIL=$(/usr/bin/tail -30 "$LOG_FILE")
    MSG="❌ Routine FAILED: ${ROUTINE}
exit=${EXIT} duration=${DURATION}s
log: ${LOG_FILE}

Last 30 lines:
${TAIL}"
    # -m 30: an abort-path alert curl once hung 46 minutes; alerts must
    # never block the runner.
    /usr/bin/curl -s -m 30 -X POST "${TELEGRAM_API_URL}/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "$("$JQ" -n --arg c "$TELEGRAM_CHAT_ID" --arg t "$MSG" '{chat_id:$c, text:$t}')" \
        > /dev/null 2>&1 || true
fi

exit "$EXIT"
