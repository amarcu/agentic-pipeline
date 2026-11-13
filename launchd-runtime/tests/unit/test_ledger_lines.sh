#!/bin/bash
# Tests for daily-summary's ledger-lines — Step 4 of the digest as one command.
#
# Step 4 used to list three commands, and the trace of the 2026-11-12 digest
# shows the model ran one of them. What these pin is that one call runs all
# three, in order, and that one of them failing or staying silent never costs
# the lines of the others or the digest itself.

_ll_setup() {
    LL_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-ledgerlines.XXXXXX)
    /bin/cp "$REPO_ROOT/skills/daily-summary/scripts/ledger-lines" "$LL_TMP/ledger-lines"
    LL_BIN="$LL_TMP/ledger-lines"
}

_ll_teardown() {
    /bin/rm -rf "$LL_TMP"
}

# _ll_stub <name> <body> — a stand-in for one of the three scripts
_ll_stub() {
    printf '#!/bin/bash\n%s\n' "$2" > "$LL_TMP/$1"
    /bin/chmod +x "$LL_TMP/$1"
}

test_ledger_lines_runs_all_three_in_order_with_the_date() {
    _ll_setup
    local rc=0 out
    _ll_stub spend-today 'echo "SPEND: $1"'
    _ll_stub friction    'echo "FRICTION: $1"'
    _ll_stub review-line 'echo "REVIEW: $1"'
    out=$("$LL_BIN" 2026-11-13)
    assert_exit 0 $? "the command succeeds" || rc=1
    assert_equal "SPEND: 2026-11-13|FRICTION: 2026-11-13|REVIEW: 2026-11-13" \
        "$(echo "$out" | /usr/bin/paste -sd'|' -)" "three lines, in the digest's order, each given the date" || rc=1
    _ll_teardown
    return $rc
}

test_ledger_lines_keeps_going_past_a_failure_and_a_silence() {
    _ll_setup
    local rc=0 out
    _ll_stub spend-today 'echo "boom" >&2; exit 3'
    _ll_stub friction    'exit 0'
    _ll_stub review-line 'echo "REVIEW: still here"'
    out=$("$LL_BIN" 2026-11-13 2>&1)
    assert_exit 0 $? "a failing script is not the digest's failure" || rc=1
    assert_equal "REVIEW: still here" "$out" "its error is not passed on, and the last line still prints" || rc=1
    /bin/rm "$LL_TMP/friction"
    out=$("$LL_BIN" 2026-11-13 2>&1)
    assert_exit 0 $? "nor is a script that is missing" || rc=1
    out=$("$LL_BIN" today 2>&1)
    assert_exit 2 $? "a date that is not YYYY-MM-DD is a usage error" || rc=1
    _ll_teardown
    return $rc
}

test_daily_summary_step_4_is_the_one_command() {
    local skill="$REPO_ROOT/skills/daily-summary/SKILL.md" rc=0
    if ! /usr/bin/grep -q '^${CLAUDE_SKILL_DIR}/scripts/ledger-lines <TODAY>$' "$skill"; then
        echo "  FAIL: Step 4 no longer runs scripts/ledger-lines"
        rc=1
    fi
    if /usr/bin/grep -qE '^\$\{CLAUDE_SKILL_DIR\}/scripts/(spend-today|friction|review-line) ' "$skill"; then
        echo "  FAIL: Step 4 lists one of the three scripts as its own command again"
        rc=1
    fi
    return $rc
}
