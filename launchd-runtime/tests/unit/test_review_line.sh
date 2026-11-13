#!/bin/bash
# Tests for daily-summary's review-line — the week's review rounds as one line
# of the evening digest.
#
# It runs inside the digest, so what these pin hardest is silence: a week with
# nothing reviewed, a GitHub that does not answer and a rollup that is not
# there all print nothing and exit 0, because the digest must still go out and
# a line that guessed would be worse than no line. The one thing it names PR by
# PR is a merge on a commit no reviewer passed.
#
# The rollup is the real one, reading the gh mock, so the line is tested
# against what review-rollup actually prints and not against a copy of it.

_rl_setup() {
    RL_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-reviewline.XXXXXX)
    export MOCK_GH_DIR="$RL_TMP/gh"
    export PATH="$FIXTURES_DIR/mock-gh:$PATH"
    export JQ_BIN
    RL_BIN="$REPO_ROOT/skills/daily-summary/scripts/review-line"
    /bin/mkdir -p "$MOCK_GH_DIR"
    # acme/dormant is on the roster and not active: the digest does not survey it.
    printf '%s\n' 'REVIEW_ROUND_MAX=3' 'ACTIVE_REPOS=(' '    "acme/game"' ')' \
        'REPOS_BY_PRIORITY=(' '    "acme/game"' '    "acme/dormant"' ')' > "$RL_TMP/repos.conf"
    export REPOS_CONF="$RL_TMP/repos.conf"
    # The merge date is the host's local date; the fixtures are written in UTC.
    export TZ=UTC
    # 20: passed first time, merged on that commit.
    # 21: three rounds, last one changes-needed, merged anyway.
    # 22: opened before the window.
    /bin/cat > "$MOCK_GH_DIR/pulls.json" <<'JSON'
[
 {"number": 20, "head": {"ref": "task/issue-1-hud",  "sha": "aaaaaaa0000000000000000000000000000000aa"}, "state": "closed", "merged_at": "2026-11-10T08:00:00Z", "created_at": "2026-11-09T04:20:00Z"},
 {"number": 21, "head": {"ref": "task/issue-2-boss", "sha": "bbbbbb30000000000000000000000000000000bb"}, "state": "closed", "merged_at": "2026-11-11T08:00:00Z", "created_at": "2026-11-08T04:20:00Z"},
 {"number": 22, "head": {"ref": "task/issue-3-old",  "sha": "ccccccc0000000000000000000000000000000cc"}, "state": "closed", "merged_at": "2026-10-02T08:00:00Z", "created_at": "2026-10-01T04:20:00Z"}
]
JSON
    _rl_review 20 201 1 pass           2026-11-09T05:00:00Z aaaaaaa
    _rl_review 21 211 1 changes-needed 2026-11-08T05:00:00Z bbbbbb1
    _rl_review 21 212 2 changes-needed 2026-11-09T05:00:00Z bbbbbb2
    _rl_review 21 213 3 changes-needed 2026-11-10T05:00:00Z bbbbbb3
    _rl_review 22 221 1 changes-needed 2026-10-01T05:00:00Z ccccccc
}

_rl_teardown() {
    /bin/rm -rf "$RL_TMP"
}

# _rl_review <pr> <review id> <round> <verdict> <submitted_at> <head>
_rl_review() {
    local f="$MOCK_GH_DIR/reviews-$1.json"
    [[ -f "$f" ]] || echo '[]' > "$f"
    "$JQ_BIN" --argjson id "$2" --arg at "$5" \
        --arg body "<!-- cursor-review repo=acme/game pr=$1 round=$3 head=$6 model=m verdict=$4 request_id=r -->" \
        '. + [{id: $id, body: $body, submitted_at: $at}]' "$f" > "$f.new" && /bin/mv "$f.new" "$f"
}

test_review_line_says_what_review_cost_the_weeks_pull_requests() {
    _rl_setup
    local rc=0 out
    out=$("$RL_BIN" 2026-11-12)
    assert_exit 0 $? "the line prints" || rc=1
    assert_equal "REVIEW: 2 reviewed of 2 agent PRs opened in 7 days — 1 clean, median 2 rounds, 1 at the round cap" \
        "$out" "counts for the window; #21 merged yesterday, so it is not named today" || rc=1
    out=$("$RL_BIN" 2026-11-11)
    assert_contains "$out" "merged today on an unpassed commit: acme/game#21" \
        "on the evening it merged, the PR that merged without a pass is named" || rc=1
    assert_not_contains "$out" "#20" "a PR that merged on a passed commit is never named" || rc=1
    _rl_teardown
    return $rc
}

test_review_line_counts_the_digests_roster_and_no_other_repo() {
    # daily-summary surveys ACTIVE_REPOS, "those repos and no others". The
    # rollup's own default is the whole roster, so without --active the line
    # counted dormant repos too, and one of them failing dropped the line
    # (Cursor review, PR #97 f1). A dormant repo that would answer 404 here
    # must neither be counted nor be asked.
    _rl_setup
    local rc=0 out
    export MOCK_GH_LOG="$RL_TMP/gh.log"
    out=$("$RL_BIN" 2026-11-12 2>&1)
    assert_contains "$out" "REVIEW: 2 reviewed of 2 agent PRs" "the active repo's PRs are the whole count" || rc=1
    assert_not_contains "$out" "(error)" "and the dormant repo is not reported as a failure" || rc=1
    assert_not_contains "$(/bin/cat "$MOCK_GH_LOG")" "acme/dormant" "because it was never asked" || rc=1
    unset MOCK_GH_LOG
    _rl_teardown
    return $rc
}

test_review_line_drops_the_segments_that_are_zero() {
    _rl_setup
    local rc=0 out
    /bin/rm "$MOCK_GH_DIR/reviews-21.json"
    out=$("$RL_BIN" 2026-11-12)
    assert_equal "REVIEW: 1 reviewed of 2 agent PRs opened in 7 days — 1 clean, median 1 rounds" "$out" \
        "no cap and no unpassed merge means neither is mentioned" || rc=1
    _rl_teardown
    return $rc
}

test_review_line_is_silent_when_there_is_nothing_true_to_say() {
    _rl_setup
    local rc=0 out
    out=$("$RL_BIN" 2026-10-20 2>&1)
    assert_exit 0 $? "a week with no agent PR is not an error" || rc=1
    assert_equal "" "$out" "and prints nothing" || rc=1
    printf '%s\n' '#!/bin/bash' 'echo "not json"' > "$RL_TMP/garbled-rollup"
    /bin/chmod +x "$RL_TMP/garbled-rollup"
    out=$(REVIEW_ROLLUP_BIN="$RL_TMP/garbled-rollup" "$RL_BIN" 2026-11-12 2>&1)
    assert_exit 0 $? "a rollup that prints something unreadable must not stop the digest" || rc=1
    assert_equal "" "$out" "and is not passed on as a line" || rc=1
    out=$(REVIEW_ROLLUP_BIN="$RL_TMP/not-installed" "$RL_BIN" 2026-11-12 2>&1)
    assert_exit 0 $? "nor a rollup that is not there" || rc=1
    assert_equal "" "$out" "which is silence too" || rc=1
    _rl_teardown
    return $rc
}

test_review_line_gives_up_quietly_on_a_rollup_that_hangs() {
    # The skill runs this through a Bash tool call with its own time limit. A
    # script the harness kills prints a tool error into the digest's turn; one
    # that gives up first prints nothing, which is the contract.
    _rl_setup
    local rc=0 out started
    printf '%s\n' '#!/bin/bash' '/bin/sleep 20' > "$RL_TMP/slow-rollup"
    /bin/chmod +x "$RL_TMP/slow-rollup"
    started=$(/bin/date +%s)
    out=$(REVIEW_ROLLUP_BIN="$RL_TMP/slow-rollup" REVIEW_LINE_TIMEOUT_S=1 "$RL_BIN" 2026-11-12 2>&1)
    assert_exit 0 $? "a hung rollup is not an error" || rc=1
    assert_equal "" "$out" "and prints nothing" || rc=1
    [[ $(( $(/bin/date +%s) - started )) -lt 10 ]] || { echo "  FAIL: it waited for the hung rollup"; rc=1; }
    _rl_teardown
    return $rc
}

test_review_line_names_a_repo_it_could_not_read() {
    _rl_setup
    local rc=0 out
    printf '%s\n' 'REVIEW_ROUND_MAX=3' 'ACTIVE_REPOS=(' '    "acme/game"' '    "acme/gone"' ')' > "$RL_TMP/repos.conf"
    /bin/mkdir -p "$MOCK_GH_DIR/acme-gone"
    out=$("$RL_BIN" 2026-11-12 2>/dev/null)
    assert_contains "$out" "REVIEW: 2 reviewed of 2 agent PRs" "the repos that answered are still reported" || rc=1
    assert_contains "$out" "· (error) acme/gone" "and the one that did not is named, not dropped" || rc=1
    _rl_teardown
    return $rc
}

test_review_line_never_reads_an_unanswered_repo_as_a_quiet_week() {
    # (error) exists so that a repo GitHub would not answer for is not taken
    # for a week with nothing to review. The first version returned early when
    # nothing was reviewed, before it looked at which repos had failed, so the
    # one case the segment is for printed nothing (Cursor review, PR #97 f2).
    _rl_setup
    local rc=0 out
    printf '%s\n' 'REVIEW_ROUND_MAX=3' 'ACTIVE_REPOS=(' '    "acme/game"' '    "acme/gone"' ')' > "$RL_TMP/repos.conf"
    /bin/mkdir -p "$MOCK_GH_DIR/acme-gone"
    out=$("$RL_BIN" 2026-10-20 2>/dev/null)
    assert_exit 0 $? "the line prints" || rc=1
    assert_equal "REVIEW: no review read in 7 days · (error) acme/gone" "$out" \
        "a quiet week in one repo and no answer from another is not silence" || rc=1
    /bin/rm "$MOCK_GH_DIR/pulls.json"
    printf '%s\n' 'REVIEW_ROUND_MAX=3' 'ACTIVE_REPOS=(' '    "acme/game"' ')' > "$RL_TMP/repos.conf"
    out=$("$RL_BIN" 2026-11-12 2>/dev/null)
    assert_equal "REVIEW: no review read in 7 days · (error) acme/game" "$out" \
        "nor is the only active repo failing, which is the live roster today" || rc=1
    _rl_teardown
    return $rc
}

test_review_line_rejects_a_date_it_cannot_read() {
    _rl_setup
    local rc=0 out
    out=$("$RL_BIN" yesterday 2>&1)
    assert_exit 2 $? "a date that is not YYYY-MM-DD is a usage error" || rc=1
    out=$("$RL_BIN" 2>&1)
    assert_exit 2 $? "and so is no date" || rc=1
    _rl_teardown
    return $rc
}
