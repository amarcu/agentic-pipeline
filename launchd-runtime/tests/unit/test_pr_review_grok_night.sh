#!/bin/bash
# Tests for launchd-runtime/bin/pr-review-grok-night — pr-review-night's precheck, which has Grok
# review the merge-lane repos at 05:00 so pr-iterate-night answers the findings the same night.
# What these pin: oldest first, at most the cap, one REVIEW: line per PR; a review that prints no
# result is an error, not a silent pass; and the model starts only for a repo outside the lane.

_prg_setup() {
    PRG_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-prgrok.XXXXXX)
    /bin/mkdir -p "$PRG_TMP/fake"
    : > "$PRG_TMP/calls.log"
    export REPOS_CONF="$PRG_TMP/repos.conf"
    _prg_conf '"acme/game"' '"acme/game"'
    /bin/cat > "$PRG_TMP/fake/agent-prs" <<'SH'
#!/bin/bash
printf '3\ttask/issue-1-a\tdraft\t2026-10-15T00:00:00Z\n4\ttask/issue-2-b\tdraft\t2026-10-16T00:00:00Z\n5\ttask/issue-3-c\tdraft\t2026-10-17T00:00:00Z\n'
SH
    /bin/cat > "$PRG_TMP/fake/cursor-review" <<'SH'
#!/bin/bash
echo "cursor-review $*" >> "$PRG_TMP/calls.log"
echo "bundle noise on stderr" >&2
[ "$2" = "${PRG_SILENT_PR:-}" ] && exit 2
if [ "$2" = "${PRG_POST_FAILS_PR:-}" ]; then
    echo "CURSOR REVIEW: run=x repo=$1 pr=$2 round=1 head=abc1234 model=m verdict=changes-needed findings=0/1/0 posted=failed unanchored=0"
    exit 9
fi
echo "CURSOR REVIEW: run=x repo=$1 pr=$2 round=1 head=abc1234 model=m verdict=pass findings=0/0/0 posted=inline unanchored=0"
SH
    /bin/chmod +x "$PRG_TMP/fake/"*
    export PRG_TMP AGENT_PRS_BIN="$PRG_TMP/fake/agent-prs" CURSOR_REVIEW_BIN="$PRG_TMP/fake/cursor-review"
}

# _prg_conf <active repos> <merge-lane repos>
_prg_conf() {
    /bin/cat > "$REPOS_CONF" <<EOF
ACTIVE_REPOS=( $1 )
MERGE_LANE_REPOS=( $2 )
EOF
}

_prg_teardown() {
    /bin/rm -rf "$PRG_TMP"
    unset PRG_TMP AGENT_PRS_BIN CURSOR_REVIEW_BIN REPOS_CONF PR_REVIEW_GROK_MAX PRG_SILENT_PR \
        PRG_POST_FAILS_PR PR_REVIEW_GROK_BUDGET_SECONDS PR_REVIEW_GROK_REVIEW_SECONDS
}

test_pr_review_grok_night_reviews_oldest_first_up_to_the_cap() {
    _prg_setup
    local rc=0 out code
    out=$(PR_REVIEW_GROK_MAX=2 "$RUNTIME_DIR/bin/pr-review-grok-night"); code=$?
    assert_equal "10" "$code" "every active repo is in the lane, so no model starts" || rc=1
    assert_contains "$(echo "$out" | /usr/bin/head -1)" "REVIEW: grok reviewed=2 errors=0 seconds=" "the first line is the summary" || rc=1
    assert_equal "cursor-review acme/game 3 --post
cursor-review acme/game 4 --post" "$(/bin/cat "$PRG_TMP/calls.log")" "oldest first, posted, two of three" || rc=1
    assert_contains "$out" "REVIEW: run=x repo=acme/game pr=3 round=1 head=abc1234" "one REVIEW: line per PR" || rc=1
    assert_contains "$out" "REVIEW: repo=acme/game pr=5 result=deferred reason=cap 2 reached" "the third waits" || rc=1
    if [[ "$out" == *"bundle noise"* ]]; then
        echo "  FAIL: cursor-review's stderr flooded the routine output"; rc=1
    fi
    _prg_teardown
    return $rc
}

test_pr_review_grok_night_reports_a_review_that_printed_no_result() {
    _prg_setup
    local rc=0 out
    out=$(PRG_SILENT_PR=4 "$RUNTIME_DIR/bin/pr-review-grok-night")
    assert_contains "$out" "REVIEW: grok reviewed=2 errors=1" "the summary counts it" || rc=1
    assert_contains "$out" "pr=4 result=error reason=cursor-review exit 2" "and names the PR" || rc=1
    assert_contains "$out" "    bundle noise on stderr" "with the tail of its stderr" || rc=1
    _prg_teardown
    return $rc
}

test_pr_review_grok_night_starts_the_model_for_a_repo_outside_the_lane() {
    _prg_setup
    local rc=0 code
    _prg_conf '"acme/game" "acme/other"' '"acme/game"'
    "$RUNTIME_DIR/bin/pr-review-grok-night" > /dev/null; code=$?
    assert_equal "0" "$code" "acme/other still needs /review-pr" || rc=1
    _prg_teardown
    return $rc
}

test_pr_review_grok_night_counts_a_review_that_failed_to_post_as_an_error() {
    _prg_setup
    local rc=0 out
    out=$(PRG_POST_FAILS_PR=3 "$RUNTIME_DIR/bin/pr-review-grok-night")
    assert_contains "$out" "pr=3 result=error reason=cursor-review exit 9, posted=failed" "posted=failed is not a review iterate can answer" || rc=1
    assert_contains "$out" "REVIEW: grok reviewed=2 errors=1" "and it does not count as reviewed" || rc=1
    _prg_teardown
    return $rc
}

test_pr_review_grok_night_starts_no_review_after_its_time_budget() {
    _prg_setup
    local rc=0 out
    out=$(PR_REVIEW_GROK_BUDGET_SECONDS=0 "$RUNTIME_DIR/bin/pr-review-grok-night")
    assert_contains "$out" "pr=3 result=deferred reason=time budget 0s spent" "past the budget, the PR waits for tomorrow" || rc=1
    assert_equal "" "$(/bin/cat "$PRG_TMP/calls.log")" "and no review starts" || rc=1
    _prg_teardown
    return $rc
}

test_pr_review_grok_night_caps_each_reviews_gate() {
    _prg_setup
    local rc=0
    /bin/cat > "$PRG_TMP/fake/cursor-review" <<'SH'
#!/bin/bash
echo "gate-cap=$CURSOR_REVIEW_GATE_TIMEOUT" >> "$PRG_TMP/calls.log"
echo "CURSOR REVIEW: run=x repo=$1 pr=$2 round=1 head=abc1234 model=m verdict=pass findings=0/0/0 posted=inline unanchored=0"
SH
    "$RUNTIME_DIR/bin/pr-review-grok-night" > /dev/null
    assert_contains "$(/bin/cat "$PRG_TMP/calls.log")" "gate-cap=600" "a hung gate cannot eat the night" || rc=1
    _prg_teardown
    return $rc
}

test_pr_review_grok_night_kills_a_review_that_hangs_and_its_children() {
    _prg_setup
    local rc=0 out
    /bin/cat > "$PRG_TMP/fake/cursor-review" <<'SH'
#!/bin/bash
# A hung cursor-agent: a child that never returns.
/bin/sleep 300 &
echo $! > "$PRG_TMP/child.pid"
wait
SH
    out=$(PR_REVIEW_GROK_MAX=1 PR_REVIEW_GROK_REVIEW_SECONDS=2 "$RUNTIME_DIR/bin/pr-review-grok-night")
    assert_contains "$out" "pr=3 result=error reason=review killed at its 2s cap" "a hang is cut off at the cap" || rc=1
    /bin/sleep 1
    if kill -0 "$(/bin/cat "$PRG_TMP/child.pid")" 2>/dev/null; then
        echo "  FAIL: the hung review's child outlived the cap"
        kill "$(/bin/cat "$PRG_TMP/child.pid")" 2>/dev/null
        rc=1
    fi
    _prg_teardown
    return $rc
}
