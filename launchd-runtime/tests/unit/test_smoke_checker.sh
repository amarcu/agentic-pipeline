#!/bin/bash
# Unit tests for tests/smoke/check-envelope.sh — the half of the smoke gate
# that decides pass or FAIL.
#
# `make smoke` spends real API calls, so it cannot run here. Its judgement can:
# every verdict is exercised against a fixture envelope in
# fixtures/smoke-envelopes/, including the two production outages the gate
# exists to catch. A checker nobody checks is a green light nobody earned.

_SMOKE_CHECK="$RUNTIME_DIR/tests/smoke/check-envelope.sh"
_SMOKE_FIXTURES="$FIXTURES_DIR/smoke-envelopes"

# Verdict for one fixture, as one line: "pass" or "FAIL <reason>".
_smoke_verdict() {
    local routine="$1" fixture="$2" cli_exit="${3:-0}"
    "$_SMOKE_CHECK" "$routine" "$_SMOKE_FIXTURES/$fixture" "$cli_exit" 2>&1
}

test_smoke_checker_passes_a_clean_run() {
    local rc=0 out
    out=$(_smoke_verdict morning-triage morning-triage-pass.json)
    assert_equal "pass" "$out" "clean morning-triage envelope" || rc=1
    "$_SMOKE_CHECK" morning-triage "$_SMOKE_FIXTURES/morning-triage-pass.json" 0 > /dev/null
    assert_exit 0 $? "checker exit code on a pass" || rc=1
    return $rc
}

test_smoke_checker_catches_the_disable_model_invocation_outage() {
    # 2026-09-05/06: every routine whose prompt says "run the /skill" halted
    # because the flag blocks the Skill tool. The run "succeeded" — exit 0,
    # is_error false — and did nothing, which is exactly why the gate matches
    # the signature in the result text rather than trusting the status fields.
    local rc=0 out
    out=$(_smoke_verdict morning-triage flag-refusal.json)
    assert_contains "$out" "FAIL" "flag refusal must not pass" || rc=1
    assert_contains "$out" "disable-model-invocation" "reason names the signature" || rc=1
    "$_SMOKE_CHECK" morning-triage "$_SMOKE_FIXTURES/flag-refusal.json" 0 > /dev/null
    assert_exit 1 $? "checker exit code on a FAIL" || rc=1
    return $rc
}

test_smoke_checker_catches_the_forked_worker_with_no_arguments() {
    # 2026-09-07: dispatch forked work-on-task and the fork arrived with no
    # arguments. The dispatcher's own lines were all present and correct.
    local rc=0 out
    out=$(_smoke_verdict dispatch-tasks-night dispatch-no-args.json)
    assert_contains "$out" "FAIL" "no-args run must not pass" || rc=1
    assert_contains "$out" "issue number" "reason names the signature" || rc=1
    return $rc
}

test_smoke_checker_wants_a_worker_line_only_when_the_gate_opened() {
    local rc=0 out
    # eligible=- : no worker was due, the dispatcher's two lines are the whole
    # contract.
    out=$(_smoke_verdict dispatch-tasks-night dispatch-gate-closed.json)
    assert_equal "pass" "$out" "closed gate needs no worker line" || rc=1
    # eligible=<repo> with the worker's PLANNED: line present.
    out=$(_smoke_verdict dispatch-tasks-night dispatch-worker-planned.json)
    assert_equal "pass" "$out" "open gate with a worker line" || rc=1
    return $rc
}

test_smoke_checker_fails_an_open_gate_with_no_worker_line() {
    # The same envelope minus the PLANNED: line: the fork produced nothing and
    # the dispatcher still closed cleanly. That is the shape of a hand-off bug.
    local rc=0 out tmp
    tmp=$(/usr/bin/mktemp -t smoke-noworker)
    "$JQ_BIN" '.result |= (split("\n") | map(select(startswith("PLANNED:") | not)) | join("\n"))' \
        "$_SMOKE_FIXTURES/dispatch-worker-planned.json" > "$tmp"
    out=$("$_SMOKE_CHECK" dispatch-tasks-night "$tmp" 0 2>&1)
    assert_contains "$out" "FAIL" "open gate with no worker line must fail" || rc=1
    assert_contains "$out" "eligible=" "reason names the gate's eligible list" || rc=1
    /bin/rm -f "$tmp"
    return $rc
}

test_smoke_checker_passes_a_morning_that_only_refilled() {
    # On a night the one active repo is human-led, morning-proposals' final
    # message is refill-queue's PLANNED: lines and nothing else. That is the
    # routine having spoken, not a missing contract line (Cursor, PR #100 f2).
    local rc=0 out
    out=$(_smoke_verdict morning-proposals morning-proposals-refill.json)
    assert_equal "pass" "$out" "an envelope whose only contract lines are PLANNED: passes" || rc=1
    return $rc
}

test_smoke_checker_fails_on_a_permission_denial() {
    # Under the dry run a routine reads and decides; a denial means it reached
    # for a write. The smoke's extra deny family exists to turn that into this.
    local rc=0 out
    out=$(_smoke_verdict morning-proposals denied-write.json)
    assert_contains "$out" "FAIL" "a denial must not pass" || rc=1
    assert_contains "$out" "permission_denials=1" "reason counts the denials" || rc=1
    assert_contains "$out" "gh issue create" "reason names the denied command" || rc=1
    return $rc
}

test_smoke_checker_fails_on_an_error_envelope() {
    local rc=0 out
    out=$(_smoke_verdict daily-summary-routine budget-exhausted.json)
    assert_contains "$out" "FAIL" "is_error must not pass" || rc=1
    assert_contains "$out" "error_max_budget_usd" "reason names the subtype" || rc=1
    return $rc
}

test_smoke_checker_fails_on_a_nonzero_cli_exit() {
    local rc=0 out
    out=$(_smoke_verdict morning-triage morning-triage-pass.json 143)
    assert_contains "$out" "FAIL" "a killed run must not pass" || rc=1
    assert_contains "$out" "cli-exit=143" "reason names the exit code" || rc=1
    return $rc
}

test_smoke_checker_requires_each_routines_contract_line() {
    # The pass fixture carries TRIAGE:, so every other routine's contract is
    # missing from it — one fixture, eight assertions.
    local rc=0 out routine
    for routine in morning-proposals daily-summary-routine pr-review-night \
                   pr-iterate-night skill-assess-weekly dispatch-tasks-night; do
        out=$(_smoke_verdict "$routine" morning-triage-pass.json)
        assert_contains "$out" "FAIL" "$routine must want its own contract line" || rc=1
    done
    # The two report-only routines promise a non-empty result and nothing more.
    for routine in wake-status-digest daily-review-nudge; do
        out=$(_smoke_verdict "$routine" morning-triage-pass.json)
        assert_equal "pass" "$out" "$routine has no contract line to want" || rc=1
    done
    return $rc
}

test_smoke_checker_does_not_accept_the_token_inside_prose() {
    # The model narrates. "I could not produce a TRIAGE: line" contains the
    # token, and a substring match would have called that a pass — the exact
    # false green this gate exists to prevent.
    local rc=0 out tmp
    tmp=$(/usr/bin/mktemp -t smoke-prose)
    "$JQ_BIN" '.result = "I scanned the repos but could not produce a TRIAGE: line this run."' \
        "$_SMOKE_FIXTURES/morning-triage-pass.json" > "$tmp"
    out=$("$_SMOKE_CHECK" morning-triage "$tmp" 0 2>&1)
    assert_contains "$out" "FAIL" "a token inside prose is not a contract line" || rc=1
    /bin/rm -f "$tmp"
    return $rc
}

test_smoke_checker_fails_an_empty_result_and_a_missing_envelope() {
    local rc=0 out tmp
    tmp=$(/usr/bin/mktemp -t smoke-empty)
    "$JQ_BIN" '.result = ""' "$_SMOKE_FIXTURES/morning-triage-pass.json" > "$tmp"
    out=$("$_SMOKE_CHECK" wake-status-digest "$tmp" 0 2>&1)
    assert_contains "$out" "empty-result" "an empty result is a failure" || rc=1
    /bin/rm -f "$tmp"

    out=$("$_SMOKE_CHECK" wake-status-digest "$_SMOKE_FIXTURES/does-not-exist.json" 0 2>&1)
    assert_contains "$out" "no-envelope" "a missing envelope is a failure" || rc=1
    return $rc
}

test_smoke_checker_refuses_a_routine_it_has_no_contract_for() {
    # A new prompt file joins `make smoke` automatically. It fails here until
    # someone writes down what the routine is supposed to print.
    local rc=0 out
    out=$(_smoke_verdict brand-new-routine morning-triage-pass.json)
    assert_contains "$out" "unknown-routine" "an unlisted routine must fail" || rc=1
    return $rc
}

test_smoke_every_prompt_has_a_contract_and_the_runner_reads_the_shared_deny() {
    # Two wiring checks that need no API call:
    #   1. every routine `make smoke` would run has a contract the checker
    #      enforces — since #52 a row in bin/routine-contracts.tsv, which the
    #      checker and the runner both read, so they cannot disagree;
    #   2. the deny-net the smoke launches with is the file the runner reads,
    #      so production and rehearsal cannot drift apart.
    local rc=0 name
    local contracts="$RUNTIME_DIR/bin/routine-contracts.tsv"
    for prompt in "$RUNTIME_DIR"/prompts/*.md; do
        name=$(/usr/bin/basename "$prompt" .md)
        if ! LC_ALL=C /usr/bin/awk -F'\t' -v r="$name" '$1 == r {found=1} END {exit !found}' "$contracts"; then
            echo "  ASSERT FAIL: prompts/$name.md has no row in bin/routine-contracts.tsv"
            rc=1
        fi
    done
    # The assignment that reads the table, not any mention of it: both files
    # also name the table in comments, and the runner in its warning text.
    /usr/bin/grep -qE '^[[:space:]]*CONTRACTS=.*/routine-contracts\.tsv' "$_SMOKE_CHECK" \
        || { echo "  ASSERT FAIL: check-envelope.sh no longer reads bin/routine-contracts.tsv"; rc=1; }
    /usr/bin/grep -qE '^[[:space:]]*CONTRACTS_FILE=.*/routine-contracts\.tsv' "$RUNTIME_DIR/bin/_run.sh" \
        || { echo "  ASSERT FAIL: _run.sh no longer reads bin/routine-contracts.tsv"; rc=1; }

    assert_file_exists "$RUNTIME_DIR/bin/headless-deny.sh" "shared deny-net" || rc=1
    /usr/bin/grep -qF 'bin/headless-deny.sh' "$RUNTIME_DIR/bin/_run.sh" \
        || { echo "  ASSERT FAIL: _run.sh no longer reads bin/headless-deny.sh"; rc=1; }
    /usr/bin/grep -qF 'bin/headless-deny.sh' "$RUNTIME_DIR/tests/smoke/run-smoke.sh" \
        || { echo "  ASSERT FAIL: run-smoke.sh no longer reads bin/headless-deny.sh"; rc=1; }
    # The rules live in one file and nowhere else: a second HEADLESS_DENY=
    # assignment is the drift this factoring exists to prevent.
    if /usr/bin/grep -q '^HEADLESS_DENY=' "$RUNTIME_DIR/bin/_run.sh"; then
        echo "  ASSERT FAIL: _run.sh defines HEADLESS_DENY inline again"
        rc=1
    fi
    return $rc
}

test_smoke_dry_run_contract_reaches_every_routine_skill() {
    # ROUTINE_DRY_RUN is the smoke's read-only guarantee. It is only worth
    # anything if the skills can SEE it: `env` and `printenv` are denied in a
    # headless run, so the Step 0 echo is the only channel.
    local rc=0 skill
    for skill in dispatch-tasks morning-triage daily-summary propose-tasks \
                 refill-queue skill-assess work-on-task review-pr iterate-on-pr; do
        if ! /usr/bin/grep -qF 'ROUTINE_DRY_RUN' "$REPO_ROOT/skills/$skill/SKILL.md"; then
            echo "  ASSERT FAIL: $skill/SKILL.md never echoes ROUTINE_DRY_RUN"
            rc=1
        fi
    done
    /usr/bin/grep -qF 'ROUTINE_DRY_RUN' "$REPO_ROOT/BASELINE.md" \
        || { echo "  ASSERT FAIL: BASELINE.md does not define the ROUTINE_DRY_RUN contract"; rc=1; }
    return $rc
}

# A scan in which every repo errored reports zero of everything, which reads as
# a quiet day. 2026-09-12: a smoke run started over ssh had no gh on PATH, all
# seven repos came back as ERROR:, and the run printed a well-formed TRIAGE:
# line on top of a scan that saw nothing.
_smoke_triage_fixture() {
    local line="$1" out="$2"
    "$JQ_BIN" --arg line "$line" '.result = ("Scanned the roster under ROUTINE_DRY_RUN=1.\n\n" + $line)' \
        "$_SMOKE_FIXTURES/morning-triage-pass.json" > "$out"
}

test_smoke_checker_fails_a_triage_run_in_which_every_repo_errored() {
    local rc=0 tmp out
    tmp=$(/usr/bin/mktemp /tmp/agentic-test-smoke.XXXXXX)
    _smoke_triage_fixture "TRIAGE: run=smoke-1 repos=7 blocking=0 needs_approval=0 proposed=0 escalated=0 errors=7" "$tmp"
    out=$("$_SMOKE_CHECK" morning-triage "$tmp" 0 2>&1)
    assert_contains "$out" "FAIL" "a scan that saw nothing must not pass" || rc=1
    assert_contains "$out" "every repo errored" "and the reason says why" || rc=1
    /bin/rm -f "$tmp"
    return $rc
}

test_smoke_checker_passes_a_triage_run_with_some_repo_errors() {
    # An ERROR: block is a normal per-repo outcome; the scan carries on.
    local rc=0 tmp out
    tmp=$(/usr/bin/mktemp /tmp/agentic-test-smoke.XXXXXX)
    _smoke_triage_fixture "TRIAGE: run=smoke-1 repos=9 blocking=1 needs_approval=3 proposed=4 escalated=0 errors=2" "$tmp"
    out=$("$_SMOKE_CHECK" morning-triage "$tmp" 0 2>&1)
    assert_equal "pass" "$out" "two failed repos out of nine is still a scan" || rc=1
    /bin/rm -f "$tmp"
    return $rc
}

test_smoke_checker_wants_the_errors_count_on_the_triage_line() {
    # Without the count, a scan that saw nothing is indistinguishable from a
    # quiet day, which is the case this line exists to tell apart.
    local rc=0 tmp out
    tmp=$(/usr/bin/mktemp /tmp/agentic-test-smoke.XXXXXX)
    _smoke_triage_fixture "TRIAGE: run=smoke-1 repos=9 blocking=1 needs_approval=3 proposed=4 escalated=0" "$tmp"
    out=$("$_SMOKE_CHECK" morning-triage "$tmp" 0 2>&1)
    assert_contains "$out" "FAIL" "a TRIAGE: line with no errors= count must not pass" || rc=1
    assert_contains "$out" "errors=" "and the reason names the missing field" || rc=1
    /bin/rm -f "$tmp"
    return $rc
}

test_smoke_checker_reads_contract_lines_from_the_shared_table() {
    # #52: the runner and this checker must not disagree about what a routine
    # owes, so both read bin/routine-contracts.tsv. A routine added only to the
    # table is judged by it.
    local rc=0 out table
    table=$(/usr/bin/mktemp /tmp/agentic-test-contracts.XXXXXX)
    /bin/cat "$RUNTIME_DIR/bin/routine-contracts.tsv" > "$table"
    printf 'brand-new-routine\tHELLO:\n' >> "$table"
    out=$(ROUTINE_CONTRACTS_FILE="$table" "$_SMOKE_CHECK" brand-new-routine \
        "$_SMOKE_FIXTURES/morning-triage-pass.json" 0 2>&1)
    assert_contains "$out" "no HELLO: line in result" "the table's row is what the checker enforces" || rc=1
    /bin/rm -f "$table"
    return $rc
}
