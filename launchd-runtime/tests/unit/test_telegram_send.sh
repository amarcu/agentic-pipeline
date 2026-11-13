#!/bin/bash
# Unit tests for telegram-send's ledger.
#
# Until 2026-09-03 a send left no durable record anywhere: the only evidence
# that a routine had told the human about a PR was the human's Telegram
# scrollback, so "did the 04:10 run notify me about #12?" was unanswerable
# after the fact. Every accepted send now appends a row to
# $METRICS_DIR/sends.jsonl. These tests pin the three things that make the row
# worth having — it exists, it names the run, it names what the message
# referenced — and the two that make it safe: no row for a send that never
# landed, and a ledger failure that never fails a delivered message.
#
# The mock Telegram server from helpers.sh stands in for the API, exactly as
# the _run.sh tests use it.

_tgs_setup() {
    export TEST_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-tgs.XXXXXX)
    export METRICS_DIR="$TEST_TMP/metrics"
    export TELEGRAM_BOT_TOKEN="test-token"
    export TELEGRAM_CHAT_ID="424242"
    TGS_MSG="$TEST_TMP/message.txt"
    TGS_SENDER="$RUNTIME_DIR/bin/telegram-send"
    start_mock_telegram
}

# Mirrors _prb_teardown in test_pr_review_bundle.sh: the directory being
# removed is the one this file's mktemp -d just created.
_tgs_teardown() {
    stop_mock_telegram
    /bin/rm -rf "$TEST_TMP"
}

_tgs_ledger_lines() {
    /usr/bin/wc -l < "$METRICS_DIR/sends.jsonl" 2>/dev/null | /usr/bin/tr -d ' '
}

_tgs_last_row() {
    /usr/bin/tail -1 "$METRICS_DIR/sends.jsonl" 2>/dev/null
}

_tgs_field() {
    echo "$1" | "$JQ_BIN" -r "$2"
}

test_telegram_send_records_one_ledger_row_per_delivered_message() {
    _tgs_setup
    local msg="Nightly digest: nothing to report"
    printf '%s\n' "$msg" > "$TGS_MSG"

    local rc=0 out
    out=$("$TGS_SENDER" "$TGS_MSG" 2>&1)
    assert_exit 0 $? "a delivered send exits 0" || rc=1
    assert_contains "$out" "sent message_id=1000" "stdout still reports the message id" || rc=1

    assert_equal 1 "$(_tgs_ledger_lines)" "one row per send" || rc=1

    local row
    row=$(_tgs_last_row)
    assert_equal "interactive" "$(_tgs_field "$row" .routine)" \
        "a send outside a routine is recorded as interactive" || rc=1
    assert_equal "null" "$(_tgs_field "$row" .run_id)" "with no run id" || rc=1
    assert_equal "1000" "$(_tgs_field "$row" .message_id)" "the id Telegram returned" || rc=1
    assert_equal "${#msg}" "$(_tgs_field "$row" .chars)" "the length of the sent text" || rc=1
    assert_equal "[]" "$(echo "$row" | "$JQ_BIN" -c .refs)" "no refs in a message naming none" || rc=1

    # The hash is over the stripped text the sender actually posted, so it
    # matches across the trailing newline the heredoc leaves behind.
    local want
    want=$(printf '%s' "$msg" | /usr/bin/shasum -a 256 | /usr/bin/cut -d' ' -f1)
    assert_equal "$want" "$(_tgs_field "$row" .sha256)" "sha256 of the sent text" || rc=1

    # Appends, never truncates: two sends leave two rows.
    "$TGS_SENDER" "$TGS_MSG" > /dev/null 2>&1
    assert_equal 2 "$(_tgs_ledger_lines)" "a second send appends" || rc=1

    _tgs_teardown
    return $rc
}

test_telegram_send_ledger_row_names_the_routine_run_that_sent_it() {
    _tgs_setup
    # Both exported by _run.sh; the run id is what joins this row to runs.jsonl.
    export ROUTINE="dispatch-tasks"
    export ROUTINE_RUN_ID="dispatch-tasks-1757000000-4711"
    printf 'Dispatched 2 issues\n' > "$TGS_MSG"

    local rc=0
    "$TGS_SENDER" "$TGS_MSG" > /dev/null 2>&1
    assert_exit 0 $? "send under a routine exits 0" || rc=1

    local row
    row=$(_tgs_last_row)
    assert_equal "dispatch-tasks" "$(_tgs_field "$row" .routine)" "routine is recorded" || rc=1
    assert_equal "dispatch-tasks-1757000000-4711" "$(_tgs_field "$row" .run_id)" \
        "run id is recorded verbatim" || rc=1

    _tgs_teardown
    return $rc
}

test_telegram_send_ledger_records_every_github_ref_the_message_names() {
    _tgs_setup
    # One PR URL, one issue URL, one bare shorthand, one repeat of the first,
    # and two decoys: a non-GitHub URL of the same shape, and a bare `#N` with
    # no repo. Order is the order the message names them; the repeat is dropped.
    /bin/cat > "$TGS_MSG" <<'EOF'
Opened https://github.com/amarcu/agentic-pipeline/pull/15 (closes #15).
Blocked: https://github.com/amarcu/StarBonk/issues/7
Follow-up filed as acme/strategy-game#3
Same PR again: https://github.com/amarcu/agentic-pipeline/pull/15
Ignore https://example.com/amarcu/agentic-pipeline/pull/99
EOF

    local rc=0
    "$TGS_SENDER" "$TGS_MSG" > /dev/null 2>&1
    assert_exit 0 $? "send exits 0" || rc=1

    local refs
    refs=$(_tgs_last_row | "$JQ_BIN" -c .refs)
    assert_equal '["amarcu/agentic-pipeline#15","amarcu/StarBonk#7","acme/strategy-game#3"]' \
        "$refs" "refs are the deduped owner/repo#N in message order" || rc=1

    _tgs_teardown
    return $rc
}

test_telegram_send_writes_no_ledger_row_when_the_send_never_landed() {
    _tgs_setup
    printf 'This never reaches Telegram\n' > "$TGS_MSG"
    # Kill the mock but keep pointing at its port: the connection is refused,
    # which is the failure a caller must not mistake for a delivered message.
    stop_mock_telegram

    local rc=0
    "$TGS_SENDER" "$TGS_MSG" > /dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        echo "  FAIL: sender exited 0 with no Telegram API to talk to"
        rc=1
    fi
    if [[ -e "$METRICS_DIR/sends.jsonl" ]]; then
        echo "  FAIL: a failed send wrote a ledger row:"
        /bin/cat "$METRICS_DIR/sends.jsonl" | /usr/bin/sed 's/^/      /'
        rc=1
    fi

    /bin/rm -rf "$TEST_TMP"
    return $rc
}

test_telegram_send_still_succeeds_when_the_ledger_cannot_be_written() {
    _tgs_setup
    printf 'Delivered but unrecordable\n' > "$TGS_MSG"
    # A metrics dir whose parent is a regular file: mkdir fails, and the send
    # has already happened. Failing here would hand the caller a nonzero exit
    # on a message Telegram accepted — the exact shape that breeds duplicates.
    printf 'not a directory\n' > "$TEST_TMP/blocker"
    export METRICS_DIR="$TEST_TMP/blocker/metrics"

    local rc=0 out
    out=$("$TGS_SENDER" "$TGS_MSG" 2>&1)
    assert_exit 0 $? "a ledger failure does not fail the send" || rc=1
    assert_contains "$out" "sent message_id=" "the message id is still reported" || rc=1
    assert_contains "$out" "send not recorded in sends.jsonl" "and the failure is surfaced" || rc=1
    assert_equal 1 "$(telegram_count)" "the message was posted exactly once" || rc=1

    _tgs_teardown
    return $rc
}

test_telegram_send_treats_a_200_carrying_ok_false_as_a_failed_send() {
    # Telegram answers an unknown chat, or a bot the user has blocked, with
    # HTTP 200 and {"ok": false, "description": ...}. Reading the status code
    # as the outcome would print `sent message_id=None` and leave a ledger row
    # claiming a message the human never received.
    export MOCK_TG_NOT_OK="Bad Request: chat not found"
    _tgs_setup
    printf 'Nobody will read this\n' > "$TGS_MSG"

    local rc=0 out
    out=$("$TGS_SENDER" "$TGS_MSG" 2>&1)
    if [[ $? -eq 0 ]]; then
        echo "  FAIL: sender exited 0 on a message Telegram rejected"
        rc=1
    fi
    assert_contains "$out" "Bad Request: chat not found" \
        "the rejection reason is surfaced" || rc=1
    assert_not_contains "$out" "sent message_id=" \
        "nothing claims the message was sent" || rc=1
    if [[ -e "$METRICS_DIR/sends.jsonl" ]]; then
        echo "  FAIL: a rejected message wrote a ledger row:"
        /usr/bin/sed 's/^/      /' "$METRICS_DIR/sends.jsonl"
        rc=1
    fi
    assert_equal 1 "$(telegram_count)" "the request was made exactly once" || rc=1

    _tgs_teardown
    return $rc
}
