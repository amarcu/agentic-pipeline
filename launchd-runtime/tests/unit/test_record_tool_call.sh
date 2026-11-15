#!/bin/bash
# Tests for launchd-runtime/bin/record-tool-call, the PostToolUse hook _run.sh
# registers for every routine.
#
# A step that worked used to leave nothing: the ledgers held failures and
# denials only, so nobody could say where a forty-minute run spent its time.
# This writes one row per completed tool call. It runs inside the routine it
# observes, once per call, so the tests pin three things hardest: it can never
# disturb that run, it never copies what a tool returned, and a tool it does
# not know gets no label rather than a dump of its input.

_rtc_setup() {
    RTC_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-rtc.XXXXXX)
    RTC_BIN="$RUNTIME_DIR/bin/record-tool-call"
    RTC_METRICS="$RTC_TMP/metrics"
    RTC_LEDGER="$RTC_METRICS/tool-calls.jsonl"
}

_rtc_teardown() {
    /bin/rm -rf "$RTC_TMP"
}

# The event as a headless run delivered it on 2026-11-12, trimmed to the
# fields the recorder reads plus the response it must not keep.
# _rtc_event <tool> <tool_input json>
_rtc_event() {
    "$JQ_BIN" -nc --arg tool "$1" --argjson input "$2" \
        '{session_id: "sess-1", hook_event_name: "PostToolUse", tool_name: $tool,
          tool_input: $input, tool_use_id: "toolu_1", duration_ms: 160, cwd: "/",
          tool_response: {stdout: "SECRET-OUTPUT-MARKER", stderr: ""}}'
}

test_record_tool_call_appends_one_row_per_completed_call() {
    _rtc_setup
    local rc=0 out
    out=$(_rtc_event Bash '{"command":"make test\necho second-line","description":"run the gate"}' \
        | ROUTINE=dispatch-tasks-night ROUTINE_RUN_ID=dispatch-tasks-night-1-2 "$RTC_BIN" "$RTC_METRICS" 2>&1)
    assert_exit 0 $? "the hook exits 0" || rc=1
    assert_equal "" "$out" "and prints nothing the model would see" || rc=1
    assert_file_exists "$RTC_LEDGER" "the ledger is created" || rc=1
    if [[ -f "$RTC_LEDGER" ]]; then
        assert_equal "dispatch-tasks-night dispatch-tasks-night-1-2 Bash 160" \
            "$("$JQ_BIN" -r '"\(.routine) \(.run_id) \(.tool) \(.duration_ms)"' "$RTC_LEDGER")" \
            "the row names the routine, the run, the tool and how long it took" || rc=1
        assert_equal "make test" "$("$JQ_BIN" -r .what "$RTC_LEDGER")" \
            "and labels a command by its first line" || rc=1
    fi
    _rtc_teardown
    return $rc
}

test_record_tool_call_never_keeps_what_a_tool_returned() {
    _rtc_setup
    local rc=0 long
    long=$(/usr/bin/printf 'x%.0s' $(/usr/bin/seq 1 400))
    _rtc_event Read "{\"file_path\":\"/some/long/prefix/$long/secrets/BASELINE.md\"}" | "$RTC_BIN" "$RTC_METRICS"
    _rtc_event Mystery '{"payload":"PRIVATE-INPUT-MARKER"}' | "$RTC_BIN" "$RTC_METRICS"
    assert_not_contains "$(/bin/cat "$RTC_LEDGER")" "SECRET-OUTPUT-MARKER" "tool_response is never written" || rc=1
    assert_not_contains "$(/bin/cat "$RTC_LEDGER")" "PRIVATE-INPUT-MARKER" "nor the input of a tool it has no label for" || rc=1
    assert_equal "120 BASELINE.md" \
        "$(/usr/bin/head -1 "$RTC_LEDGER" | "$JQ_BIN" -r '"\(.what | length) \(.what | split("/") | last)"')" \
        "a path is capped and keeps its end, because the end names the file" || rc=1
    assert_equal "Mystery " "$(/usr/bin/tail -1 "$RTC_LEDGER" | "$JQ_BIN" -r '"\(.tool) \(.what)"')" \
        "an unknown tool is still a step, with an empty label" || rc=1
    _rtc_teardown
    return $rc
}

test_record_tool_call_never_disturbs_the_run() {
    _rtc_setup
    local rc=0 out
    out=$(echo 'not json at all' | "$RTC_BIN" "$RTC_METRICS" 2>&1)
    assert_exit 0 $? "garbage on stdin still exits 0" || rc=1
    assert_equal "" "$out" "and prints nothing" || rc=1
    out=$(_rtc_event Bash '{"command":"ls"}' | "$RTC_BIN" 2>&1)
    assert_exit 0 $? "a missing metrics dir argument still exits 0" || rc=1
    assert_equal "" "$out" "and prints nothing" || rc=1
    out=$(_rtc_event Bash '{"command":"ls"}' | "$RTC_BIN" /dev/null/cannot-be-a-directory 2>&1)
    assert_exit 0 $? "an unwritable metrics dir still exits 0" || rc=1
    assert_equal "" "$out" "and prints nothing" || rc=1
    _rtc_teardown
    return $rc
}

test_record_tool_call_falls_back_to_the_session_outside_a_routine() {
    _rtc_setup
    local rc=0
    _rtc_event Skill '{"skill":"work-on-task","args":"42"}' \
        | env -u ROUTINE -u ROUTINE_RUN_ID "$RTC_BIN" "$RTC_METRICS"
    assert_equal "null sess-1 work-on-task 42" "$("$JQ_BIN" -r '"\(.routine) \(.run_id) \(.what)"' "$RTC_LEDGER")" \
        "with no routine the row joins on the session id, and a skill is labelled by name and arguments" || rc=1
    _rtc_teardown
    return $rc
}

test_record_tool_call_keeps_a_skills_arguments_so_a_run_names_its_issue() {
    # bin/item-trace reads the issue and the repo back out of this label; with
    # the skill's name alone a dispatch run could not be tied to what it built.
    _rtc_setup
    local rc=0
    _rtc_event Skill '{"skill":"work-on-task","args":"97 --repo acme/game\nPRIVATE-SECOND-LINE"}' | "$RTC_BIN" "$RTC_METRICS"
    _rtc_event Skill '{"skill":"daily-summary"}' | "$RTC_BIN" "$RTC_METRICS"
    assert_equal "work-on-task 97 --repo acme/game" "$(/usr/bin/head -1 "$RTC_LEDGER" | "$JQ_BIN" -r .what)" \
        "the label is the skill and the first line of its arguments" || rc=1
    assert_equal "daily-summary" "$(/usr/bin/tail -1 "$RTC_LEDGER" | "$JQ_BIN" -r .what)" \
        "a skill called with no arguments is labelled by name alone" || rc=1
    _rtc_teardown
    return $rc
}
