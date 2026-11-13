#!/bin/bash
# Unit tests for daily-summary's friction reader.
#
# The point of the friction line is a rule that keeps getting in the way: the
# same denial or the same failed call in more than one run. One occurrence is a
# run's own business and stays out of the digest, and an absent ledger is
# silence, never "0 blockers" — the same honesty spend-today keeps.
#
# The two ledgers carry different timestamp formats: _run.sh writes denials
# with its local stamp ("2026-09-13 04:02:11 UTC"), record-tool-failure writes
# ISO-8601. Both start with YYYY-MM-DD, which is the only thing the window may
# rely on; the tests use each.

_fr_setup() {
    TEST_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-friction.XXXXXX)
    FR_BIN="$REPO_ROOT/skills/daily-summary/scripts/friction"
    FR_METRICS="$TEST_TMP/metrics"
    /bin/mkdir -p "$FR_METRICS"
}

_fr_teardown() {
    /bin/rm -rf "$TEST_TMP"
}

# _fr_denial <ts> <routine> <run_id> <command>
_fr_denial() {
    "$JQ_BIN" -nc --arg ts "$1" --arg r "$2" --arg rid "$3" --arg c "$4" \
        '{ts: $ts, routine: $r, run_id: $rid, tool: "Bash", input: ({command: $c} | tojson)}' \
        >> "$FR_METRICS/denials.jsonl"
}

# _fr_failure <ts> <routine> <run_id> <path>
_fr_failure() {
    "$JQ_BIN" -nc --arg ts "$1" --arg r "$2" --arg rid "$3" --arg p "$4" \
        '{ts: $ts, routine: $r, run_id: $rid, session_id: "s", tool: "Read",
          input: ({file_path: $p} | tojson), error: "File does not exist."}' \
        >> "$FR_METRICS/tool-failures.jsonl"
}

test_friction_is_silent_when_the_metrics_directory_is_absent() {
    _fr_setup
    local rc=0 out
    out=$("$FR_BIN" 2026-09-13 "$TEST_TMP/never-created" 2>&1)
    assert_exit 0 $? "an absent metrics dir is not an error" || rc=1
    assert_equal "" "$out" "and prints nothing at all" || rc=1
    _fr_teardown
    return $rc
}

test_friction_is_silent_for_a_block_seen_in_only_one_run() {
    _fr_setup
    local rc=0 out
    _fr_denial "2026-09-13 04:02:11 UTC" dispatch-tasks-night dispatch-1 "gh pr ready 12"
    out=$("$FR_BIN" 2026-09-13 "$FR_METRICS" 2>&1)
    assert_equal "" "$out" "one run hitting a rule is not friction" || rc=1
    _fr_teardown
    return $rc
}

test_friction_counts_runs_not_rows() {
    _fr_setup
    local rc=0 out
    _fr_denial "2026-09-13 04:02:11 UTC" dispatch-tasks-night dispatch-1 "gh pr ready 12"
    _fr_denial "2026-09-13 04:02:40 UTC" dispatch-tasks-night dispatch-1 "gh pr ready 12"
    out=$("$FR_BIN" 2026-09-13 "$FR_METRICS" 2>&1)
    assert_equal "" "$out" "two rows from the same run are still one run" || rc=1
    _fr_teardown
    return $rc
}

test_friction_names_a_denial_repeated_across_runs() {
    _fr_setup
    local rc=0 out
    _fr_denial "2026-09-11 04:02:11 UTC" dispatch-tasks-night dispatch-1 "gh pr ready 12"
    _fr_denial "2026-09-13 04:02:11 UTC" dispatch-tasks-night dispatch-2 "gh pr ready 12"
    out=$("$FR_BIN" 2026-09-13 "$FR_METRICS" 2>&1)
    assert_exit 0 $? "exit 0" || rc=1
    assert_contains "$out" "FRICTION:" "the line is printed" || rc=1
    assert_contains "$out" "denied" "it says what kind" || rc=1
    assert_contains "$out" "dispatch-tasks-night" "names the routine" || rc=1
    assert_contains "$out" "gh pr ready 12" "and the command that was refused" || rc=1
    assert_contains "$out" "×2" "and in how many runs" || rc=1
    _fr_teardown
    return $rc
}

test_friction_names_a_repeated_tool_failure() {
    _fr_setup
    local rc=0 out
    _fr_failure "2026-09-12T04:02:11+03:00" work-on-task work-1 /nope/BASELINE.md
    _fr_failure "2026-09-13T04:02:11+03:00" work-on-task work-2 /nope/BASELINE.md
    out=$("$FR_BIN" 2026-09-13 "$FR_METRICS" 2>&1)
    assert_contains "$out" "failed" "it says what kind" || rc=1
    assert_contains "$out" "work-on-task" "names the routine" || rc=1
    assert_contains "$out" "BASELINE.md" "and what it tried to reach" || rc=1
    _fr_teardown
    return $rc
}

test_friction_ignores_repeats_older_than_seven_days() {
    _fr_setup
    local rc=0 out
    _fr_denial "2026-09-01 04:02:11 UTC" dispatch-tasks-night dispatch-1 "gh pr ready 12"
    _fr_denial "2026-09-02 04:02:11 UTC" dispatch-tasks-night dispatch-2 "gh pr ready 12"
    out=$("$FR_BIN" 2026-09-13 "$FR_METRICS" 2>&1)
    assert_equal "" "$out" "a rule that stopped blocking a week ago is not today's news" || rc=1
    _fr_teardown
    return $rc
}

test_friction_prints_one_line_at_most() {
    _fr_setup
    local rc=0 out
    local c
    for c in "gh pr ready 12" "gh pr merge 13" "git push --force"; do
        _fr_denial "2026-09-12 04:02:11 UTC" dispatch-tasks-night dispatch-1 "$c"
        _fr_denial "2026-09-13 04:02:11 UTC" dispatch-tasks-night dispatch-2 "$c"
    done
    out=$("$FR_BIN" 2026-09-13 "$FR_METRICS" 2>&1)
    assert_equal "1" "$(printf '%s\n' "$out" | /usr/bin/grep -c .)" "one line, however many repeats" || rc=1
    assert_contains "$out" "3 repeated" "and it says how many there are" || rc=1
    _fr_teardown
    return $rc
}

test_friction_skips_lines_carrying_invalid_utf8_bytes() {
    # The analogue of spend-today's test: a watchdog can kill the writer
    # mid-line, and a strict read raised UnicodeDecodeError before any parsing,
    # so one byte cost the whole line — and broke the promise of silence.
    _fr_setup
    local rc=0 out
    {
        # Octal, not \xHH: /usr/bin/printf on macOS has no \x escape.
        /usr/bin/printf '\377\376{"ts":"2026-09-13 04:00:00 UTC","routine":"garbage","run_id":"g1","tool":"Bash","input":"x"}\n'
    } >> "$FR_METRICS/denials.jsonl"
    _fr_denial "2026-09-12 04:02:11 UTC" dispatch-tasks-night dispatch-1 "gh pr ready 12"
    _fr_denial "2026-09-13 04:02:11 UTC" dispatch-tasks-night dispatch-2 "gh pr ready 12"
    out=$("$FR_BIN" 2026-09-13 "$FR_METRICS" 2>&1)
    assert_exit 0 $? "undecodable bytes are skipped, not fatal" || rc=1
    assert_contains "$out" "dispatch-tasks-night" "the readable repeat is still reported" || rc=1
    assert_not_contains "$out" "garbage" "and the half-written row is not" || rc=1
    _fr_teardown
    return $rc
}

test_friction_names_the_error_of_a_repeated_tool_failure() {
    # The line once read `EnterWorktree "/Users/…/StarBonk/.claude/worktrees…" ×2`:
    # the cap ate the part of the path that differs, and the error was not shown,
    # so the reader could not tell whether anything was broken.
    _fr_setup
    local rc=0 out
    local wt=/Users/dev/code/StarBonk/.claude/worktrees/issue-58
    _fr_failure "2026-09-12T04:02:11+03:00" pr-iterate-night iterate-1 "$wt"
    _fr_failure "2026-09-13T04:02:11+03:00" pr-iterate-night iterate-2 "$wt"
    out=$("$FR_BIN" 2026-09-13 "$FR_METRICS" 2>&1)
    assert_contains "$out" "worktrees/issue-58" "a long path keeps its end" || rc=1
    assert_contains "$out" "×2: File does not exist." "and the error follows the count" || rc=1
    _fr_teardown
    return $rc
}

test_friction_shows_no_error_for_a_denial() {
    _fr_setup
    local rc=0 out
    _fr_denial "2026-09-12 04:02:11 UTC" dispatch-tasks-night dispatch-1 "gh pr ready 12"
    _fr_denial "2026-09-13 04:02:11 UTC" dispatch-tasks-night dispatch-2 "gh pr ready 12"
    out=$("$FR_BIN" 2026-09-13 "$FR_METRICS" 2>&1)
    assert_contains "$out" '"gh pr ready 12" ×2' "a denial has no error text" || rc=1
    assert_not_contains "$out" "×2:" "so nothing follows its count" || rc=1
    _fr_teardown
    return $rc
}
