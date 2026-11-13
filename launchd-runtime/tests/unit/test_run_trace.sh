#!/bin/bash
# Tests for launchd-runtime/bin/run-trace — one run's tool calls as a timeline.
#
# The reader has to put a run's failed steps back among the ones that worked,
# because the two arrive through different hooks into different ledgers, and it
# has to say where the time went. A run with no rows is an error with the run's
# name in it, never an empty timeline that reads as "this run did nothing".

_rt_setup() {
    RT_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-trace.XXXXXX)
    RT_BIN="$RUNTIME_DIR/bin/run-trace"
    RT_METRICS="$RT_TMP/metrics"
    /bin/mkdir -p "$RT_METRICS"
    _rt_call 2026-11-12T04:10:00+0000 dispatch-tasks-night run-A Bash 2000  "gh issue list"
    _rt_call 2026-11-12T04:10:30+0000 dispatch-tasks-night run-A Skill 500  "work-on-task"
    # Rows are stamped when a call completes: a 50 s gate that finished at
    # 04:12:00 started at 04:11:10, ten seconds after the failed Read.
    _rt_call 2026-11-12T04:12:00+0000 dispatch-tasks-night run-A Bash 50000 "make test"
    _rt_fail 2026-11-12T04:11:00+0000 dispatch-tasks-night run-A Read "File does not exist."
    _rt_call 2026-11-12T04:02:00+0000 morning-triage       run-B Bash 100   "gh pr list"
    _rt_call 2026-11-13T04:10:00+0000 dispatch-tasks-night run-C Bash 100   "gh issue list"
    echo '{"ts": "2026-11-13T04:10:05+0000", "run_id": "run-C", "tool": "Ba' >> "$RT_METRICS/tool-calls.jsonl"
}

_rt_teardown() {
    /bin/rm -rf "$RT_TMP"
}

# _rt_call <ts> <routine> <run_id> <tool> <duration_ms> <what>
_rt_call() {
    "$JQ_BIN" -nc --arg ts "$1" --arg r "$2" --arg rid "$3" --arg t "$4" --argjson ms "$5" --arg w "$6" \
        '{ts: $ts, routine: $r, run_id: $rid, session_id: "s", tool: $t, duration_ms: $ms, what: $w}' \
        >> "$RT_METRICS/tool-calls.jsonl"
}

# _rt_fail <ts> <routine> <run_id> <tool> <error>
_rt_fail() {
    "$JQ_BIN" -nc --arg ts "$1" --arg r "$2" --arg rid "$3" --arg t "$4" --arg e "$5" \
        '{ts: $ts, routine: $r, run_id: $rid, session_id: "s", tool: $t, input: "{}", error: $e}' \
        >> "$RT_METRICS/tool-failures.jsonl"
}

test_run_trace_prints_a_runs_steps_in_time_order_with_its_failures() {
    _rt_setup
    local rc=0 out
    out=$("$RT_BIN" run-A "$RT_METRICS")
    assert_exit 0 $? "a run with rows prints" || rc=1
    assert_equal "gh issue list|work-on-task|File does not exist.|make test" \
        "$(echo "$out" | /usr/bin/awk '/^04:/' | /usr/bin/sed -E 's/.*(gh issue list|work-on-task|File does not exist\.|make test)$/\1/' | /usr/bin/paste -sd'|' -)" \
        "the failed Read sits between the calls either side of it" || rc=1
    assert_contains "$out" "FAIL" "and is marked as a failure" || rc=1
    assert_equal "10s" "$(echo "$out" | /usr/bin/awk '/make test$/ {print $2}')" \
        "a step's wait is the gap minus its own duration, because a row is stamped on completion" || rc=1
    assert_equal "30s" "$(echo "$out" | /usr/bin/awk '/FAIL/ {print $2}')" \
        "a failed call carries no duration, so its wait is the whole gap" || rc=1
    assert_contains "$out" "4 steps, 1 failed: 52.5s inside tools, 69.5s waited between them" \
        "the summary says where the time went" || rc=1
    assert_not_contains "$out" "gh pr list" "another run's steps stay out" || rc=1
    _rt_teardown
    return $rc
}

test_run_trace_takes_the_last_run_of_a_routine_and_lists_runs() {
    _rt_setup
    local rc=0 out
    out=$("$RT_BIN" --last dispatch-tasks-night "$RT_METRICS")
    assert_contains "$out" "run run-C" "--last is the most recent run of that routine" || rc=1
    assert_contains "$out" "1 steps" "and a half-written ledger line is left out, not fatal" || rc=1
    out=$("$RT_BIN" --runs "$RT_METRICS")
    assert_equal "run-B run-A run-C" "$(echo "$out" | /usr/bin/awk '{print $NF}' | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')" \
        "--runs lists every run with rows, oldest first" || rc=1
    _rt_teardown
    return $rc
}

test_run_trace_fails_by_name_when_a_run_has_no_rows() {
    _rt_setup
    local rc=0 out
    out=$("$RT_BIN" run-Z "$RT_METRICS" 2>&1)
    assert_exit 1 $? "an unknown run is exit 1" || rc=1
    assert_contains "$out" "run-Z" "and the message names it" || rc=1
    out=$("$RT_BIN" --last no-such-routine "$RT_TMP/never-created" 2>&1)
    assert_exit 1 $? "so is a routine with no rows, in a metrics dir that does not exist" || rc=1
    out=$("$RT_BIN" 2>&1)
    assert_exit 2 $? "no argument is a usage error" || rc=1
    _rt_teardown
    return $rc
}

test_make_trace_lists_runs_with_no_argument_and_traces_with_one() {
    # A recipe line is its own shell, so an `exit 0` on one line never skips
    # the next: the first version listed the runs and then ran `--last ""`,
    # which is exit 1 (Cursor review, PR #96 f1). The three cases share one
    # shell now, and this pins each of them.
    _rt_setup
    local rc=0 out
    out=$(METRICS_DIR="$RT_METRICS" /usr/bin/make -s -C "$REPO_ROOT" trace 2>&1)
    assert_exit 0 $? "make trace with no argument succeeds" || rc=1
    assert_contains "$out" "run-B" "and lists the runs" || rc=1
    assert_not_contains "$out" "no rows for routine" "without going on to trace a routine named nothing" || rc=1
    out=$(METRICS_DIR="$RT_METRICS" /usr/bin/make -s -C "$REPO_ROOT" trace ROUTINE=morning-triage 2>&1)
    assert_contains "$out" "run run-B" "ROUTINE= traces that routine's last run" || rc=1
    out=$(METRICS_DIR="$RT_METRICS" /usr/bin/make -s -C "$REPO_ROOT" trace RUN=run-A 2>&1)
    assert_contains "$out" "run run-A" "RUN= traces that run" || rc=1
    _rt_teardown
    return $rc
}
