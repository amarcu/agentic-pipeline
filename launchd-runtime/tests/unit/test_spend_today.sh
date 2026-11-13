#!/bin/bash
# Unit tests for daily-summary's spend-today reader.
#
# The digest's spend line is optional by design. On a host that has never run
# a routine there is no metrics directory at all, and a digest reporting
# "$0.00" there would be claiming a measurement it never made — so the silence
# is pinned as hard as the arithmetic.
#
# The two ledgers are written by different processes with different timestamp
# formats: _run.sh writes runs.jsonl with a local human stamp
# ("2026-09-03 18:07:12 CEST") and telegram-send writes sends.jsonl with an
# ISO-8601 offset stamp. Both start with YYYY-MM-DD, which is the only thing
# the date filter may rely on; a test for each keeps that assumption honest.

_spend_setup() {
    TEST_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-spend.XXXXXX)
    SPEND_BIN="$REPO_ROOT/skills/daily-summary/scripts/spend-today"
    SPEND_METRICS="$TEST_TMP/metrics"
    /bin/mkdir -p "$SPEND_METRICS"
}

# Mirrors _tgs_teardown in test_telegram_send.sh: the directory removed is the
# one this file's mktemp -d just created.
_spend_teardown() {
    /bin/rm -rf "$TEST_TMP"
}

test_spend_today_is_silent_when_the_metrics_directory_is_absent() {
    _spend_setup
    local rc=0 out
    out=$("$SPEND_BIN" 2026-09-03 "$TEST_TMP/never-created" 2>&1)
    assert_exit 0 $? "an absent metrics dir is not an error" || rc=1
    assert_equal "" "$out" "and prints nothing at all" || rc=1
    _spend_teardown
    return $rc
}

test_spend_today_is_silent_when_no_row_carries_the_date() {
    _spend_setup
    local rc=0 out
    # Present, parsable, and about a different day.
    /bin/echo '{"routine":"morning-triage","ts":"2026-09-02 09:00:12 CEST","cost_usd":0.94}' \
        > "$SPEND_METRICS/runs.jsonl"
    /bin/echo '{"ts":"2026-09-02T18:07:12+02:00","routine":"daily-summary-routine"}' \
        > "$SPEND_METRICS/sends.jsonl"

    out=$("$SPEND_BIN" 2026-09-03 "$SPEND_METRICS" 2>&1)
    assert_exit 0 $? "a day with no rows is not an error" || rc=1
    assert_equal "" "$out" "and reports no spend rather than zero spend" || rc=1
    _spend_teardown
    return $rc
}

test_spend_today_reports_the_day_total_per_routine_and_send_count() {
    _spend_setup
    local rc=0 out
    {
        /bin/echo '{"routine":"morning-triage","ts":"2026-09-03 09:00:12 CEST","cost_usd":0.94}'
        /bin/echo '{"routine":"dispatch-tasks-night","ts":"2026-09-03 04:10:03 CEST","cost_usd":1.2}'
        /bin/echo '{"routine":"dispatch-tasks-night","ts":"2026-09-02 04:10:03 CEST","cost_usd":9.99}'
    } > "$SPEND_METRICS/runs.jsonl"
    {
        /bin/echo '{"ts":"2026-09-03T18:07:12+02:00","routine":"daily-summary-routine"}'
        /bin/echo '{"ts":"2026-09-03T04:20:00+02:00","routine":"dispatch-tasks-night"}'
        /bin/echo '{"ts":"2026-09-01T18:07:12+02:00","routine":"daily-summary-routine"}'
    } > "$SPEND_METRICS/sends.jsonl"

    out=$("$SPEND_BIN" 2026-09-03 "$SPEND_METRICS")
    assert_exit 0 $? "a day with rows exits 0" || rc=1
    assert_contains "$out" "total_usd=2.14" "yesterday's \$9.99 run is not in today's total" || rc=1
    assert_contains "$out" "runs=2" "two runs on the date" || rc=1
    assert_contains "$out" "sends=2" "two sends on the date" || rc=1
    # Costliest routine first: the digest names at most three, so the order is
    # what decides which ones the human sees.
    assert_contains "$out" "dispatch-tasks-night=1.20 morning-triage=0.94" \
        "per-routine costs, costliest first" || rc=1
    assert_equal 1 "$(/bin/echo "$out" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" \
        "exactly one SPEND: line" || rc=1
    _spend_teardown
    return $rc
}

test_spend_today_survives_null_costs_and_unparsable_rows() {
    _spend_setup
    local rc=0 out
    # cost_usd is null on a watchdog kill (_run.sh writes the row from what the
    # runner knows when the CLI never got to emit its envelope), and a
    # half-written last line is normal for a file two processes append to.
    {
        /bin/echo '{"routine":"wake-status-digest","ts":"2026-09-03 07:00:00 CEST","cost_usd":null}'
        /bin/echo '{"routine":"morning-triage","ts":"2026-09-03 09:00:12 CEST","cost_usd":0.5}'
        /bin/echo ''
        /bin/echo '{"routine":"truncated","ts":"2026-09-03 10'
    } > "$SPEND_METRICS/runs.jsonl"

    out=$("$SPEND_BIN" 2026-09-03 "$SPEND_METRICS")
    assert_exit 0 $? "a null cost and a truncated row are not errors" || rc=1
    assert_contains "$out" "total_usd=0.50" "a null cost counts as zero, not as a crash" || rc=1
    assert_contains "$out" "runs=2" "the unparsable row is skipped, not counted" || rc=1
    assert_contains "$out" "wake-status-digest=0.00" "a zero-cost routine still appears" || rc=1
    assert_contains "$out" "sends=0" "an absent sends ledger reads as zero sends" || rc=1
    _spend_teardown
    return $rc
}

test_spend_today_skips_lines_carrying_invalid_utf8_bytes() {
    _spend_setup
    local rc=0 out
    # A watchdog can kill the writer mid-line, so the tail of a ledger can be
    # a half-written UTF-8 sequence rather than merely truncated JSON. Reading
    # the file strictly raised UnicodeDecodeError before any parsing, which
    # cost the whole day's figure over one byte.
    {
        # Octal, not \xHH: /usr/bin/printf on macOS has no \x escape and would
        # write the literal characters, which decode fine and would test
        # nothing. \377\376 puts two genuinely undecodable bytes on the line.
        /usr/bin/printf '\377\376{"routine":"garbage","ts":"2026-09-03 08:00:00 CEST","cost_usd":7.0}\n'
        /bin/echo '{"routine":"morning-triage","ts":"2026-09-03 09:00:12 CEST","cost_usd":0.75}'
    } > "$SPEND_METRICS/runs.jsonl"

    out=$("$SPEND_BIN" 2026-09-03 "$SPEND_METRICS" 2>&1)
    assert_exit 0 $? "undecodable bytes are skipped, not fatal" || rc=1
    assert_contains "$out" "runs=1" "only the decodable row is counted" || rc=1
    assert_contains "$out" "total_usd=0.75" "and the garbage row's cost is not in the total" || rc=1
    assert_not_contains "$out" "garbage" "the unparsable row names no routine" || rc=1
    _spend_teardown
    return $rc
}

test_spend_today_names_at_most_the_three_costliest_routines() {
    _spend_setup
    local rc=0 out
    # references/digest-format.md caps the digest's spend line at three
    # routines. The cap lives in the script so it holds wherever the line is
    # rendered from, and `total_usd` still covers every run.
    {
        /bin/echo '{"routine":"alpha","ts":"2026-09-03 01:00:00 CEST","cost_usd":5.0}'
        /bin/echo '{"routine":"bravo","ts":"2026-09-03 02:00:00 CEST","cost_usd":4.0}'
        /bin/echo '{"routine":"charlie","ts":"2026-09-03 03:00:00 CEST","cost_usd":3.0}'
        /bin/echo '{"routine":"delta","ts":"2026-09-03 04:00:00 CEST","cost_usd":2.0}'
        /bin/echo '{"routine":"echo","ts":"2026-09-03 05:00:00 CEST","cost_usd":1.0}'
    } > "$SPEND_METRICS/runs.jsonl"

    out=$("$SPEND_BIN" 2026-09-03 "$SPEND_METRICS")
    assert_exit 0 $? "five routines still exit 0" || rc=1
    assert_contains "$out" "alpha=5.00 bravo=4.00 charlie=3.00" \
        "the three costliest, in cost order" || rc=1
    assert_not_contains "$out" "delta=" "the fourth routine is not named" || rc=1
    assert_not_contains "$out" "echo=" "nor the fifth" || rc=1
    # The cap trims the names, never the arithmetic.
    assert_contains "$out" "total_usd=15.00" "the total still covers all five" || rc=1
    assert_contains "$out" "runs=5" "as does the run count" || rc=1
    _spend_teardown
    return $rc
}
