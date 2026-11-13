#!/bin/bash
# Tests for launchd-runtime/bin/record-tool-failure, the PostToolUseFailure
# hook _run.sh registers for every routine.
#
# A scheduled run's failed tool calls — a Read of a file that is not there, a
# command that exits non-zero — used to vanish into a transcript nobody reads.
# This writes one row per failure to the friction ledger. It runs inside the
# routine it observes, so what these pin hardest is that it can never disturb
# that run: no output, exit 0 on every path.

_rtf_setup() {
    RTF_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-rtf.XXXXXX)
    RTF_BIN="$RUNTIME_DIR/bin/record-tool-failure"
    RTF_METRICS="$RTF_TMP/metrics"
}

_rtf_teardown() {
    /bin/rm -rf "$RTF_TMP"
}

# The event as a headless run delivered it on 2026-09-13, trimmed to the fields
# the recorder reads, plus a second error line it must drop.
_rtf_event() {
    /bin/cat <<'JSON'
{"session_id":"sess-1","hook_event_name":"PostToolUseFailure","tool_name":"Read","tool_input":{"file_path":"/Users/dev/code/agentic-skills/BASELINE.md"},"tool_use_id":"toolu_1","error":"File does not exist. Note: your current working directory is /.\nsecond line","is_interrupt":false,"cwd":"/"}
JSON
}

test_record_tool_failure_appends_one_row_per_failed_call() {
    _rtf_setup
    local rc=0 out ledger
    out=$(_rtf_event | ROUTINE=morning-triage ROUTINE_RUN_ID=morning-triage-1-2 "$RTF_BIN" "$RTF_METRICS" 2>&1)
    assert_exit 0 $? "the hook exits 0" || rc=1
    assert_equal "" "$out" "and prints nothing the model would see" || rc=1
    ledger="$RTF_METRICS/tool-failures.jsonl"
    assert_file_exists "$ledger" "the ledger is created" || rc=1
    if [[ -f "$ledger" ]]; then
        assert_equal "morning-triage" "$("$JQ_BIN" -r .routine "$ledger")" "row names the routine" || rc=1
        assert_equal "morning-triage-1-2" "$("$JQ_BIN" -r .run_id "$ledger")" "and the run" || rc=1
        assert_equal "Read" "$("$JQ_BIN" -r .tool "$ledger")" "and the tool" || rc=1
        assert_contains "$("$JQ_BIN" -r .input "$ledger")" "BASELINE.md" "and what it tried" || rc=1
        assert_equal "File does not exist. Note: your current working directory is /." \
            "$("$JQ_BIN" -r .error "$ledger")" "and only the first line of the error" || rc=1
    fi
    _rtf_teardown
    return $rc
}

test_record_tool_failure_never_disturbs_the_run() {
    # Exit 2 from a PostToolUseFailure hook feeds its stderr to the model, and
    # a traceback is noise in the transcript. Bad input in, silence out.
    _rtf_setup
    local rc=0 out
    out=$(printf 'not json at all' | "$RTF_BIN" "$RTF_METRICS" 2>&1)
    assert_exit 0 $? "unreadable input still exits 0" || rc=1
    assert_equal "" "$out" "and prints nothing" || rc=1
    out=$(_rtf_event | "$RTF_BIN" 2>&1)
    assert_exit 0 $? "a missing metrics-dir argument still exits 0" || rc=1
    assert_equal "" "$out" "and prints nothing" || rc=1
    out=$(_rtf_event | "$RTF_BIN" "/dev/null/cannot-be-created" 2>&1)
    assert_exit 0 $? "an unwritable directory still exits 0" || rc=1
    assert_equal "" "$out" "and prints nothing" || rc=1
    _rtf_teardown
    return $rc
}

test_record_tool_failure_falls_back_to_the_session_outside_a_routine() {
    _rtf_setup
    local rc=0 ledger="$RTF_METRICS/tool-failures.jsonl"
    (unset ROUTINE ROUTINE_RUN_ID; _rtf_event | "$RTF_BIN" "$RTF_METRICS")
    assert_file_exists "$ledger" "a row is still written" || rc=1
    if [[ -f "$ledger" ]]; then
        assert_equal "null" "$("$JQ_BIN" -r .routine "$ledger")" "no routine outside one" || rc=1
        assert_equal "sess-1" "$("$JQ_BIN" -r .run_id "$ledger")" "the session stands in for the run" || rc=1
    fi
    _rtf_teardown
    return $rc
}
