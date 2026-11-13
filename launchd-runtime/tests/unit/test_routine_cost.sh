#!/bin/bash
# Unit tests for bin/routine-cost, the per-routine rollup over runs.jsonl.
#
# The rollup's whole value is that the numbers are trustworthy enough to make
# routing decisions on (which routine to move off Opus, which cap to lower), so
# the arithmetic is pinned harder than the layout. Two things in particular:
#
#   1. A watchdog kill writes cost_usd: null — the CLI never emitted the
#      envelope its spend is computed from. Folding that in as $0 would drag
#      the median down on exactly the runs that ran longest, so the null rows
#      count toward runs and t/o and nothing else. Every fixture here carries
#      one, and the expected median differs depending on which way it lands.
#   2. Both ledgers are appended to by processes a watchdog can kill mid-line,
#      so the tail of a file can be truncated JSON or a half-written UTF-8
#      sequence. Neither may cost the window its figures.
#
#   3. The window is closed at BOTH ends. A row stamped in the future -- a
#      clock-skewed host, or a backfill imported with the wrong year -- must
#      not be folded into a window whose header says it ends today. The fixture
#      carries one, so every count asserted below doubles as a guard on the
#      upper bound.
#
# Dates are generated relative to today so the default --days 7 window is
# exercised for real. Nothing sits on the window boundary: the in-window rows
# are at most 4 days old, the old row is 9 days old and the future row is
# tomorrow, so a run that straddles midnight shifts the window without changing
# any expected count.

_cost_setup() {
    TEST_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-cost.XXXXXX)
    COST_BIN="$RUNTIME_DIR/bin/routine-cost"
    COST_METRICS="$TEST_TMP/metrics"
    /bin/mkdir -p "$COST_METRICS"

    COST_D0=$(/bin/date +%Y-%m-%d)
    COST_D1=$(/bin/date -v-1d +%Y-%m-%d)
    COST_D2=$(/bin/date -v-2d +%Y-%m-%d)
    COST_D3=$(/bin/date -v-3d +%Y-%m-%d)
    COST_D4=$(/bin/date -v-4d +%Y-%m-%d)
    COST_D5=$(/bin/date -v-5d +%Y-%m-%d)
    COST_D9=$(/bin/date -v-9d +%Y-%m-%d)
    COST_TOMORROW=$(/bin/date -v+1d +%Y-%m-%d)
}

# Mirrors _spend_teardown in test_spend_today.sh: the directory removed is the
# one this file's mktemp -d just created.
_cost_teardown() {
    /bin/rm -rf "$TEST_TMP"
}

# Two routines over ten days, with every row shape _run.sh can write:
# ordinary successes, a budget-cap trip, an api_error_status, a watchdog kill
# with a null cost and no turns, and two unreadable lines at the end.
_cost_write_ledger() {
    {
        /bin/echo '{"routine":"alpha-nightly","ts":"'"$COST_D0"' 04:00:00 CEST","run_id":"a-0","model_requested":"claude-opus-4-8","models":["claude-opus-4-8"],"cost_usd":1.0,"turns":10,"subtype":"success","is_error":false,"api_error_status":null,"input_tokens":250,"output_tokens":250,"cache_read_tokens":500,"cache_write_tokens":0}'
        /bin/echo '{"routine":"alpha-nightly","ts":"'"$COST_D1"' 04:00:00 CEST","run_id":"a-1","model_requested":"claude-opus-4-8","models":["claude-opus-4-8"],"cost_usd":2.0,"turns":20,"subtype":"success","is_error":false,"api_error_status":null}'
        /bin/echo '{"routine":"alpha-nightly","ts":"'"$COST_D3"' 04:00:00 CEST","run_id":"a-3","model_requested":"claude-opus-4-8","models":["claude-opus-4-8"],"cost_usd":3.0,"turns":30,"subtype":"success","is_error":false,"api_error_status":null}'
        /bin/echo '{"routine":"alpha-nightly","ts":"'"$COST_D4"' 04:00:00 CEST","run_id":"a-4","model_requested":"claude-opus-4-8","models":["claude-opus-4-8"],"cost_usd":4.0,"turns":40,"subtype":"success","is_error":false,"api_error_status":null}'
        # Watchdog kill: no cost, no turns, no models — the runner wrote this
        # row from what it knew, because the CLI never got to emit an envelope.
        /bin/echo '{"routine":"alpha-nightly","ts":"'"$COST_D2"' 04:00:00 CEST","run_id":"a-2","model_requested":"claude-opus-4-8","cost_usd":null,"subtype":"watchdog_timeout"}'
        # Ten days back: outside the default week, inside --since.
        /bin/echo '{"routine":"alpha-nightly","ts":"'"$COST_D9"' 04:00:00 CEST","run_id":"a-9","model_requested":"claude-opus-4-8","models":["claude-opus-4-8"],"cost_usd":100.0,"turns":99,"subtype":"success","is_error":false,"api_error_status":null}'
        /bin/echo '{"routine":"bravo-triage","ts":"'"$COST_D0"' 09:00:00 CEST","run_id":"b-0","model_requested":"claude-sonnet-4-8","models":["claude-sonnet-4-8"],"cost_usd":5.0,"turns":60,"subtype":"error_max_budget_usd","is_error":true,"api_error_status":null,"input_tokens":100,"output_tokens":100,"cache_read_tokens":800,"cache_write_tokens":0}'
        /bin/echo '{"routine":"bravo-triage","ts":"'"$COST_D1"' 09:00:00 CEST","run_id":"b-1","model_requested":"claude-sonnet-4-8","models":["claude-sonnet-4-8"],"cost_usd":0.5,"turns":5,"subtype":"success","is_error":false,"api_error_status":529}'
        # Tomorrow: a host whose clock ran ahead, or a backfill imported with
        # the wrong date. Out of every window that ends today.
        /bin/echo '{"routine":"future-skew","ts":"'"$COST_TOMORROW"' 04:00:00 CEST","run_id":"f-1","model_requested":"claude-opus-4-8","models":["claude-opus-4-8"],"cost_usd":42.0,"turns":7,"subtype":"success","is_error":false,"api_error_status":null}'
        # Octal, not \xHH: /usr/bin/printf on macOS has no \x escape and would
        # write the literal characters, which decode fine and would test
        # nothing. \377\376 puts two genuinely undecodable bytes on the line.
        /usr/bin/printf '\377\376{"routine":"garbage-utf8","ts":"'"$COST_D0"' 08:00:00 CEST","cost_usd":77.0}\n'
        # Killed mid-append: a last line that is not a whole JSON object.
        /bin/echo '{"routine":"garbage-trunc","ts":"'"$COST_D0"' 10'
    } > "$COST_METRICS/runs.jsonl"
}

_cost_write_sends() {
    {
        /bin/echo '{"ts":"'"$COST_D0"'T18:07:12+02:00","routine":"alpha-nightly","run_id":"a-0"}'
        /bin/echo '{"ts":"'"$COST_D1"'T18:07:12+02:00","routine":"alpha-nightly","run_id":"a-1"}'
        /bin/echo '{"ts":"'"$COST_D0"'T09:30:00+02:00","routine":"bravo-triage","run_id":"b-0"}'
        /bin/echo '{"ts":"'"$COST_D9"'T04:20:00+02:00","routine":"alpha-nightly","run_id":"a-9"}'
    } > "$COST_METRICS/sends.jsonl"
}

# One field of one group, straight out of --json. Asserting on the JSON rather
# than on table columns keeps these tests about the arithmetic: a later change
# to a column width must not be able to fail them.
_cost_field() {
    local group="$1" field="$2"
    shift 2
    METRICS_DIR="$COST_METRICS" "$COST_BIN" --json "$@" 2>/dev/null \
        | /usr/bin/python3 -c '
import json, sys
group, field = sys.argv[1], sys.argv[2]
for line in sys.stdin:
    row = json.loads(line)
    if row["group"] == group:
        value = row.get(field)
        print("-" if value is None else value)
        break
' "$group" "$field"
}

test_routine_cost_rolls_up_each_routine_over_the_default_week() {
    _cost_setup
    local rc=0 out
    _cost_write_ledger

    assert_equal "5" "$(_cost_field alpha-nightly runs)" \
        "four costed runs plus the watchdog kill" || rc=1
    assert_equal "10.0" "$(_cost_field alpha-nightly cost_usd)" \
        "the ten-day-old \$100 run is outside the week" || rc=1
    assert_equal "4.0" "$(_cost_field alpha-nightly max_usd)" || rc=1
    assert_equal "1" "$(_cost_field alpha-nightly timeouts)" \
        "the watchdog row is counted as a timeout" || rc=1
    assert_equal "0" "$(_cost_field alpha-nightly budget_hits)" || rc=1

    assert_equal "2" "$(_cost_field bravo-triage runs)" || rc=1
    assert_equal "5.5" "$(_cost_field bravo-triage cost_usd)" || rc=1
    assert_equal "1" "$(_cost_field bravo-triage budget_hits)" \
        "subtype error_max_budget_usd is a budget hit" || rc=1
    assert_equal "2" "$(_cost_field bravo-triage errors)" \
        "is_error on one row and api_error_status on the other" || rc=1
    assert_equal "0.8" "$(_cost_field bravo-triage cache_read_share)" \
        "800 of 1000 tokens were cache reads" || rc=1

    assert_equal "7" "$(_cost_field TOTAL runs)" "both routines, one TOTAL line" || rc=1
    assert_equal "15.5" "$(_cost_field TOTAL cost_usd)" || rc=1

    out=$(METRICS_DIR="$COST_METRICS" "$COST_BIN")
    assert_exit 0 $? "a populated ledger exits 0" || rc=1
    assert_contains "$out" "alpha-nightly" "the costliest routine is listed" || rc=1
    assert_contains "$out" "TOTAL" "and a TOTAL line closes the table" || rc=1
    assert_contains "$out" "cost columns cover 6 of 7 runs" \
        "the header says how many runs the cost figures actually cover" || rc=1
    _cost_teardown
    return $rc
}

test_routine_cost_leaves_null_cost_rows_out_of_median_and_p95() {
    _cost_setup
    local rc=0
    _cost_write_ledger

    # alpha's costed runs in the week are 1, 2, 3 and 4 dollars. Counting the
    # watchdog row as a fifth, $0 sample would make the median 2.0 — so 2.5 is
    # the assertion that the null row stayed out of the distribution.
    assert_equal "2.5" "$(_cost_field alpha-nightly median_usd)" \
        "median over the four costed runs, not the five rows" || rc=1
    assert_equal "4.0" "$(_cost_field alpha-nightly p95_usd)" \
        "p95 likewise ignores the uncosted row" || rc=1
    assert_equal "4" "$(_cost_field alpha-nightly cost_rows)" \
        "four of the five rows carry a cost" || rc=1
    # Same argument for turns: the watchdog row has no turns field at all, and
    # averaging it in as zero would report 20.0 instead of 25.0.
    assert_equal "25.0" "$(_cost_field alpha-nightly mean_turns)" \
        "mean turns skips the row that never reported any" || rc=1
    assert_equal "0.5" "$(_cost_field alpha-nightly cache_read_share)" || rc=1
    _cost_teardown
    return $rc
}

test_routine_cost_skips_invalid_utf8_and_a_truncated_last_line() {
    _cost_setup
    local rc=0 out
    _cost_write_ledger

    out=$(METRICS_DIR="$COST_METRICS" "$COST_BIN" 2>&1)
    assert_exit 0 $? "unreadable lines are skipped, not fatal" || rc=1
    assert_not_contains "$out" "garbage-utf8" \
        "the row behind two undecodable bytes names no routine" || rc=1
    assert_not_contains "$out" "garbage-trunc" \
        "nor does the half-written last line" || rc=1
    # The clincher: the discarded row claimed $77, so a total of 15.50 proves
    # it was skipped rather than merely unnamed.
    assert_equal "15.5" "$(_cost_field TOTAL cost_usd)" \
        "and neither row's cost reaches the total" || rc=1
    assert_equal "7" "$(_cost_field TOTAL runs)" "nor the run count" || rc=1
    _cost_teardown
    return $rc
}

test_routine_cost_since_widens_the_window_to_the_older_runs() {
    _cost_setup
    local rc=0
    _cost_write_ledger

    assert_equal "6" "$(_cost_field alpha-nightly runs --since "$COST_D9")" \
        "--since reaches the ten-day-old run the default week excluded" || rc=1
    assert_equal "110.0" "$(_cost_field alpha-nightly cost_usd --since "$COST_D9")" || rc=1
    assert_equal "100.0" "$(_cost_field alpha-nightly max_usd --since "$COST_D9")" || rc=1
    assert_equal "3.0" "$(_cost_field alpha-nightly median_usd --since "$COST_D9")" \
        "median over 1, 2, 3, 4 and 100" || rc=1
    # A valid window that happens to hold no rows is not an error. Day 5 is
    # the gap in the fixture: rows sit at 0, 1, 2, 3, 4, 9 and tomorrow.
    local out rc2=0
    out=$(METRICS_DIR="$COST_METRICS" "$COST_BIN" \
              --since "$COST_D5" --until "$COST_D5" 2>&1) || rc2=$?
    assert_exit 0 $rc2 "an empty window exits 0" || rc=1
    assert_contains "$out" "no runs in" "and says so in one line" || rc=1
    _cost_teardown
    return $rc
}

test_routine_cost_emits_one_parsable_json_object_per_routine() {
    _cost_setup
    local rc=0 count
    _cost_write_ledger

    # Every line must parse on its own — the point of JSON Lines is that a
    # consumer can stream it. `count` is only printed if all three parsed.
    count=$(METRICS_DIR="$COST_METRICS" "$COST_BIN" --json | /usr/bin/python3 -c '
import json, sys
groups = [json.loads(line)["group"] for line in sys.stdin if line.strip()]
print(len(groups), groups[-1])
')
    assert_equal "3 TOTAL" "$count" \
        "two routines plus TOTAL, each a whole JSON object, TOTAL last" || rc=1
    _cost_teardown
    return $rc
}

test_routine_cost_counts_sends_per_routine_for_the_same_window() {
    _cost_setup
    local rc=0 out
    _cost_write_ledger
    _cost_write_sends

    assert_equal "2" "$(_cost_field alpha-nightly sends --sends)" \
        "the ten-day-old send is outside the week, like its run" || rc=1
    assert_equal "1" "$(_cost_field bravo-triage sends --sends)" || rc=1
    assert_equal "3" "$(_cost_field TOTAL sends --sends)" || rc=1

    out=$(METRICS_DIR="$COST_METRICS" "$COST_BIN" --sends)
    assert_contains "$out" "sends" "the column is only added when asked for" || rc=1
    out=$(METRICS_DIR="$COST_METRICS" "$COST_BIN")
    assert_not_contains "$out" "sends" "and is absent otherwise" || rc=1
    # An absent sends ledger reads as zero sends, not as a crash.
    /bin/rm -f "$COST_METRICS/sends.jsonl"
    assert_equal "0" "$(_cost_field alpha-nightly sends --sends)" \
        "no sends ledger means no sends" || rc=1
    _cost_teardown
    return $rc
}

test_routine_cost_groups_by_model_when_asked() {
    _cost_setup
    local rc=0 out
    _cost_write_ledger

    assert_equal "4" "$(_cost_field claude-opus-4-8 runs --by-model)" \
        "alpha's four costed runs, without its model-less watchdog row" || rc=1
    assert_equal "10.0" "$(_cost_field claude-opus-4-8 cost_usd --by-model)" || rc=1
    assert_equal "2" "$(_cost_field claude-sonnet-4-8 runs --by-model)" || rc=1
    # The watchdog row records no models at all; it still has to be counted
    # somewhere, or the TOTAL stops matching the sum of the groups.
    assert_equal "1" "$(_cost_field - runs --by-model)" \
        "a row with no models lands in its own bucket" || rc=1
    assert_equal "7" "$(_cost_field TOTAL runs --by-model)" \
        "the groups still add up to the same seven runs" || rc=1

    out=$(METRICS_DIR="$COST_METRICS" "$COST_BIN" --by-model)
    assert_contains "$out" "models" "the first column is relabelled" || rc=1
    assert_not_contains "$out" "alpha-nightly" "and no longer names routines" || rc=1
    _cost_teardown
    return $rc
}

test_routine_cost_reports_a_missing_or_empty_ledger_in_one_line() {
    _cost_setup
    local rc=0 out

    out=$(METRICS_DIR="$TEST_TMP/never-created" "$COST_BIN" 2>&1)
    assert_exit 0 $? "an absent metrics dir is not an error" || rc=1
    assert_contains "$out" "no ledger found at" "it says which path it looked at" || rc=1
    assert_equal 1 "$(/bin/echo "$out" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" \
        "in exactly one line" || rc=1

    : > "$COST_METRICS/runs.jsonl"
    out=$(METRICS_DIR="$COST_METRICS" "$COST_BIN" 2>&1)
    assert_exit 0 $? "an empty ledger is not an error either" || rc=1
    assert_contains "$out" "no runs in" "a present but empty ledger reads as no runs" || rc=1
    assert_equal 1 "$(/bin/echo "$out" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" \
        "also one line" || rc=1

    # The messages go to stderr so that --json's stdout stays a parsable (here
    # empty) stream rather than a sentence a reader chokes on.
    out=$(METRICS_DIR="$COST_METRICS" "$COST_BIN" --json 2>/dev/null)
    assert_equal "" "$out" "--json prints no objects when there are none" || rc=1
    _cost_teardown
    return $rc
}

test_routine_cost_reads_every_runs_jsonl_sibling() {
    _cost_setup
    local rc=0 out
    _cost_write_ledger
    # A later import can drop a second ledger next to the live one; the rollup
    # has to see both, or a backfill silently halves the reported spend.
    /bin/echo '{"routine":"charlie-import","ts":"'"$COST_D1"' 12:00:00 CEST","run_id":"c-1","model_requested":"claude-opus-4-8","models":["claude-opus-4-8"],"cost_usd":6.0,"turns":8,"subtype":"success","is_error":false,"api_error_status":null}' \
        > "$COST_METRICS/runs.backfill.jsonl"

    assert_equal "1" "$(_cost_field charlie-import runs)" \
        "the backfill ledger is read too" || rc=1
    assert_equal "21.5" "$(_cost_field TOTAL cost_usd)" \
        "and its spend joins the total" || rc=1
    out=$(METRICS_DIR="$COST_METRICS" "$COST_BIN")
    assert_contains "$out" "2 ledger file(s)" "the header says how many it read" || rc=1
    _cost_teardown
    return $rc
}

test_routine_cost_bounds_the_window_at_both_ends() {
    _cost_setup
    local rc=0 out rc2=0
    _cost_write_ledger

    # The default window ends today, and the header says so. A row stamped
    # tomorrow must therefore be outside it: enforcing only the start date
    # would let a clock-skewed host inflate the figures under a header that
    # still claimed the window ended today.
    out=$(METRICS_DIR="$COST_METRICS" "$COST_BIN")
    assert_not_contains "$out" "future-skew" \
        "a future-dated row is outside a window that ends today" || rc=1
    assert_contains "$out" "$(/bin/date +%Y-%m-%d)" \
        "and the header prints the bound it actually enforced" || rc=1
    assert_equal "15.5" "$(_cost_field TOTAL cost_usd)" \
        "its \$42 does not reach the total" || rc=1
    assert_equal "7" "$(_cost_field TOTAL runs)" "nor the run count" || rc=1

    # Asked for explicitly, it is in scope like any other row.
    assert_equal "1" "$(_cost_field future-skew runs --until "$COST_TOMORROW")" \
        "--until reaches it when the caller says so" || rc=1
    assert_equal "42.0" "$(_cost_field future-skew cost_usd --until "$COST_TOMORROW")" || rc=1
    out=$(METRICS_DIR="$COST_METRICS" "$COST_BIN" --until "$COST_TOMORROW")
    assert_contains "$out" "$COST_TOMORROW" "the header moves with the bound" || rc=1

    # --days counts back from --until, so the two compose into one window
    # rather than the second clipping the first.
    assert_equal "2" "$(_cost_field alpha-nightly runs --days 2 --until "$COST_D3")" \
        "--days 2 --until D3 is D4 and D3, two of alpha's runs" || rc=1
    assert_equal "1" "$(_cost_field alpha-nightly runs --days 2 --until "$COST_D4")" \
        "shifting the end by a day drops one: D5 is empty, D4 is not" || rc=1

    # An inverted window is a typo, not an empty result.
    out=$(METRICS_DIR="$COST_METRICS" "$COST_BIN" \
              --since "$COST_D0" --until "$COST_D9" 2>&1) || rc2=$?
    assert_exit 2 $rc2 "--since after --until is a usage error" || rc=1
    assert_contains "$out" "is after" "which says which bound is wrong" || rc=1

    rc2=0
    out=$(METRICS_DIR="$COST_METRICS" "$COST_BIN" --until "not-a-date" 2>&1) || rc2=$?
    assert_exit 2 $rc2 "an unparsable --until is a usage error too" || rc=1
    assert_contains "$out" "--until expects YYYY-MM-DD" || rc=1
    _cost_teardown
    return $rc
}
