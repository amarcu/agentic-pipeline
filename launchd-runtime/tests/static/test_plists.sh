#!/bin/bash
# Static checks for LaunchAgent and LaunchDaemon plists.
# Would have caught: missing prompt files, dead executables in
# ProgramArguments, weird schedules.

PLIST_DIR_USER="$RUNTIME_DIR/agents"
PLIST_DIR_SYSTEM="$RUNTIME_DIR/system"

test_all_user_plists_parse() {
    local rc=0
    for plist in "$PLIST_DIR_USER"/*.plist; do
        if ! /usr/bin/plutil -lint "$plist" > /dev/null 2>&1; then
            echo "  FAIL: $plist does not parse"
            /usr/bin/plutil -lint "$plist" 2>&1 | sed 's/^/    /'
            rc=1
        fi
    done
    return $rc
}

test_system_plist_parses() {
    if ! /usr/bin/plutil -lint "$PLIST_DIR_SYSTEM/com.agentic-skills.wakeschedule.plist" > /dev/null 2>&1; then
        echo "  FAIL: wakeschedule plist does not parse"
        return 1
    fi
    return 0
}

test_user_plists_point_to_existing_program() {
    local rc=0
    for plist in "$PLIST_DIR_USER"/*.plist; do
        local prog
        prog=$(/usr/bin/plutil -extract ProgramArguments.0 raw "$plist" 2>/dev/null)
        if [[ -z "$prog" ]]; then
            echo "  FAIL: $plist has no ProgramArguments.0"
            rc=1
            continue
        fi
        # The tracked plists are templates: launchd takes absolute paths only,
        # so install.sh fills in the state directory and the home. A template
        # that names a real path would be one machine's, and this used to pass
        # only on a host that already had the install.
        if [[ "$prog" != "__AGENTIC_HOME__/routines/_run.sh" ]]; then
            echo "  FAIL: $plist runs '$prog', not __AGENTIC_HOME__/routines/_run.sh"
            rc=1
        fi
    done
    if [[ ! -x "$RUNTIME_DIR/bin/_run.sh" ]]; then
        echo "  FAIL: bin/_run.sh, which install.sh links there, is missing or not executable"
        rc=1
    fi
    return $rc
}

test_user_plists_render_to_absolute_paths_and_carry_none_of_their_own() {
    local rc=0 plist out
    for plist in "$PLIST_DIR_USER"/*.plist; do
        if /usr/bin/grep -qE '/Users/|/home/' "$plist"; then
            echo "  FAIL: ${plist##*/} carries a home path; use __HOME__ or __AGENTIC_HOME__"
            rc=1
        fi
        # The same substitution install.sh makes.
        out=$(/usr/bin/sed -e 's|__AGENTIC_HOME__|/Users/dev/.agentic-skills|g' -e 's|__HOME__|/Users/dev|g' "$plist")
        if echo "$out" | /usr/bin/grep -q '__'; then
            echo "  FAIL: ${plist##*/} still has a placeholder after rendering"
            rc=1
        fi
        if ! echo "$out" | /usr/bin/plutil -lint - > /dev/null 2>&1; then
            echo "  FAIL: ${plist##*/} is not a valid plist once rendered"
            rc=1
        fi
    done
    return $rc
}

test_every_routine_plist_has_matching_prompt() {
    # plist's ProgramArguments[1] is the routine name; there must be a
    # matching .md in launchd-runtime/prompts/.
    local rc=0
    for plist in "$PLIST_DIR_USER"/*.plist; do
        local routine
        routine=$(/usr/bin/plutil -extract ProgramArguments.1 raw "$plist" 2>/dev/null) || continue
        [[ -z "$routine" ]] && continue
        if [[ ! -f "$RUNTIME_DIR/prompts/$routine.md" ]]; then
            echo "  FAIL: $plist references routine '$routine' but no $RUNTIME_DIR/prompts/$routine.md"
            rc=1
        fi
    done
    return $rc
}

test_plist_schedule_hours_are_sane() {
    # All plists fire at Hour 0-23. Catches accidental "Hour=24" or string typos.
    local rc=0
    for plist in "$PLIST_DIR_USER"/*.plist; do
        local hour minute
        hour=$(/usr/bin/plutil -extract StartCalendarInterval.Hour raw "$plist" 2>/dev/null) || continue
        minute=$(/usr/bin/plutil -extract StartCalendarInterval.Minute raw "$plist" 2>/dev/null) || continue
        if [[ "$hour" -lt 0 || "$hour" -gt 23 ]]; then
            echo "  FAIL: $plist Hour=$hour out of range 0-23"
            rc=1
        fi
        if [[ "$minute" -lt 0 || "$minute" -gt 59 ]]; then
            echo "  FAIL: $plist Minute=$minute out of range 0-59"
            rc=1
        fi
    done
    return $rc
}

test_every_plist_sets_routine_timeout() {
    # Each routine should declare a per-routine ROUTINE_TIMEOUT_SECONDS so
    # we don't fall back to the runner's default (1800s). Tight, routine-
    # specific budgets are how we fail-fast when claude-cli's stream stalls
    # after a tool call (which happened on 2026-05-12 for morning-triage,
    # morning-proposals — both did their work in <30s then sat idle for
    # 30-44 min until the watchdog killed them).
    local rc=0
    # Sane bounds per routine. Edit here if budgets need adjustment.
    declare_min_max() {
        case "$1" in
            wake-status-digest)     echo "60 600"   ;;  # 1m-10m
            morning-triage)         echo "60 600"   ;;
            morning-proposals)      echo "120 1200" ;;  # 2m-20m
            daily-summary-routine)  echo "120 1200" ;;
            daily-review-nudge)     echo "120 1200" ;;  # 2m-20m (read-only queue assembly)
            skill-assess-weekly)    echo "300 1800" ;;  # 5m-30m (static suite + the changed skills)
            dispatch-tasks-night)   echo "900 5400" ;;  # 15m-90m (the only daily dispatch)
            pr-review-night)        echo "600 5400" ;;  # 10m-90m (up to 4 reviews at opus/high)
            pr-iterate-night)       echo "600 5400" ;;  # 10m-90m (up to 3 iterations at opus/high)
            merge-lane-night)       echo "300 1800" ;;  # 5m-30m (model runs only to report a failed lane)
            playtest-build-night)   echo "300 1800" ;;  # 5m-30m (model runs only to report a broken build routine)
            *)                      echo ""         ;;
        esac
    }
    for plist in "$PLIST_DIR_USER"/*.plist; do
        local routine
        routine=$(/usr/bin/plutil -extract ProgramArguments.1 raw "$plist" 2>/dev/null) || continue
        local timeout
        timeout=$(/usr/bin/plutil -extract EnvironmentVariables.ROUTINE_TIMEOUT_SECONDS raw "$plist" 2>/dev/null)
        if [[ -z "$timeout" ]]; then
            echo "  FAIL: $(basename "$plist") missing ROUTINE_TIMEOUT_SECONDS (would fall back to default 1800s)"
            rc=1
            continue
        fi
        local bounds=$(declare_min_max "$routine")
        if [[ -z "$bounds" ]]; then
            echo "  FAIL: $routine not in bounds map — add it to test_every_plist_sets_routine_timeout"
            rc=1
            continue
        fi
        local min=$(echo "$bounds" | /usr/bin/awk '{print $1}')
        local max=$(echo "$bounds" | /usr/bin/awk '{print $2}')
        if [[ "$timeout" -lt "$min" || "$timeout" -gt "$max" ]]; then
            echo "  FAIL: $routine timeout=${timeout}s out of range [${min}s, ${max}s]"
            rc=1
        fi
    done
    return $rc
}

test_plist_labels_match_filenames() {
    # The plist Label key should match the filename (minus .plist).
    local rc=0
    for plist in "$PLIST_DIR_USER"/*.plist; do
        local expected actual
        expected=$(/usr/bin/basename "$plist" .plist)
        actual=$(/usr/bin/plutil -extract Label raw "$plist" 2>/dev/null)
        if [[ "$actual" != "$expected" ]]; then
            echo "  FAIL: $plist Label=$actual but filename is $expected.plist"
            rc=1
        fi
    done
    return $rc
}

test_routine_rosters_match_installed_plists() {
    # The installed plists are the only source of truth for which routines
    # exist. Two rosters have to agree with them, and both drifted silently
    # before: bin/routines-status tracked a routine retired in May 2026 and
    # omitted daily-review-nudge, and so did the 04:00 digest prompt — which
    # is the AUTOMATIC silent-failure detector, so a routine missing there
    # dies without anyone being told.
    local rc=0
    local installed
    installed=$(for plist in "$PLIST_DIR_USER"/*.plist; do
        /usr/bin/plutil -extract ProgramArguments.1 raw "$plist" 2>/dev/null
    done | /usr/bin/sort)

    local status_roster
    status_roster=$(/usr/bin/sed -n '/^ROUTINES=(/,/^)/p' "$RUNTIME_DIR/bin/routines-status" \
        | /usr/bin/sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' | /usr/bin/sort)

    if [[ "$installed" != "$status_roster" ]]; then
        echo "  FAIL: bin/routines-status ROUTINES does not match the installed plists"
        echo "    installed: $(echo "$installed" | /usr/bin/tr '\n' ' ')"
        echo "    roster:    $(echo "$status_roster" | /usr/bin/tr '\n' ' ')"
        rc=1
    fi

    local wake_prompt="$RUNTIME_DIR/prompts/wake-status-digest.md"
    while IFS= read -r routine; do
        [[ -z "$routine" ]] && continue
        if ! /usr/bin/grep -q -- "\`$routine\`" "$wake_prompt"; then
            echo "  FAIL: $routine absent from prompts/wake-status-digest.md roster — its failure would be silent"
            rc=1
        fi
    done <<< "$installed"
    return $rc
}

test_every_test_file_parses() {
    # A test file with a syntax error is sourced, fails, and its tests simply
    # never run — the suite still prints "All N tests passed" with a smaller N
    # that nobody reads. That happened while resolving a merge here: a dropped
    # closing brace silently removed four cost-capture tests from the run and
    # the suite still reported green.
    local rc=0
    for f in "$RUNTIME_DIR"/tests/helpers.sh "$RUNTIME_DIR"/tests/unit/*.sh "$RUNTIME_DIR"/tests/static/*.sh; do
        [[ -f "$f" ]] || continue
        if ! /bin/bash -n "$f" 2>/dev/null; then
            echo "  FAIL: $(basename "$f") does not parse — its tests would be skipped silently"
            /bin/bash -n "$f" 2>&1 | /usr/bin/head -3 | /usr/bin/sed 's/^/    /'
            rc=1
        fi
    done
    return $rc
}

test_all_plists_are_well_formed_xml() {
    # test_all_user_plists_parse uses `plutil -lint`, which is lenient: it
    # accepts a comment containing a double hyphen, which XML forbids. A plist
    # that passed that check was rejected outright by xmllint and by Python's
    # parser. Anything in the toolchain that is not Apple's own parser then
    # breaks on a file the suite called healthy.
    local rc=0
    for plist in "$PLIST_DIR_USER"/*.plist "$PLIST_DIR_SYSTEM"/*.plist; do
        [[ -f "$plist" ]] || continue
        if ! /usr/bin/python3 -c "import xml.etree.ElementTree as ET,sys; ET.parse(sys.argv[1])" "$plist" 2>/dev/null; then
            echo "  FAIL: $(basename "$plist") is not well-formed XML (plutil -lint does not catch this)"
            /usr/bin/python3 -c "import xml.etree.ElementTree as ET,sys;"$'\n'"try: ET.parse(sys.argv[1])"$'\n'"except Exception as e: print('    ', e)" "$plist"
            rc=1
        fi
    done
    return $rc
}

test_every_routine_plist_captures_the_run_envelope() {
    # The run's JSON envelope is the only record of what a routine spent and
    # what its deny-net refused. Capture was opt-in and two of nine routines
    # had it, so the spend line and the denial ledger (PR #49) each saw two
    # routines and reported them as the whole pipeline — and the routines that
    # meet a deny rule most, dispatch and PR review, were among the seven.
    local rc=0 plist routine value
    for plist in "$PLIST_DIR_USER"/*.plist; do
        routine=$(/usr/bin/plutil -extract ProgramArguments.1 raw "$plist" 2>/dev/null) || continue
        [[ -z "$routine" ]] && continue
        if ! value=$(/usr/bin/plutil -extract EnvironmentVariables.ROUTINE_CAPTURE_JSON raw "$plist" 2>/dev/null) \
           || [[ -z "$value" ]]; then
            echo "  FAIL: $(/usr/bin/basename "$plist") does not set ROUTINE_CAPTURE_JSON"
            rc=1
        fi
    done
    return $rc
}
