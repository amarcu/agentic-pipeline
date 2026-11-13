#!/bin/bash
# Tests for launchd-runtime/bin/review-rollup — how many review rounds each
# agent pull request took, and what the rounds found.
#
# The rollup reads the markers both review lanes post on the pull request
# itself, so every case here is a set of reviews and comments as GitHub returns
# them. The figures that matter are the ones a wrong count would hide: a PR
# whose merged commit no reviewer passed, a PR that used every round a lane was
# allowed, and a pass from one lane that the other lane overturned.

_rr_setup() {
    RR_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-rollup.XXXXXX)
    export MOCK_GH_DIR="$RR_TMP/gh"
    export PATH="$FIXTURES_DIR/mock-gh:$PATH"
    export JQ_BIN
    RR_BIN="$RUNTIME_DIR/bin/review-rollup"
    RR_CONF="$RR_TMP/repos.conf"
    /bin/mkdir -p "$MOCK_GH_DIR"
    printf '%s\n' 'REVIEW_ROUND_MAX=3' 'REPOS_BY_PRIORITY=(' '    "acme/game"' ')' > "$RR_CONF"
    export REPOS_CONF="$RR_CONF"
    # 10: passed on round 1, merged on that commit.
    # 11: two rounds, three findings, passed — then a commit landed and it merged.
    # 12: three rounds in one lane, never passed, open.
    # 13: agent PR older than the markers, merged.
    # 14: the human's own branch, reviewed — not an agent PR.
    # 15: review-pr passed, cursor-review did not, then did; merged on that commit.
    /bin/cat > "$MOCK_GH_DIR/pulls.json" <<'JSON'
[
 {"number": 10, "head": {"ref": "task/issue-1-hud",    "sha": "aaaaaaa0000000000000000000000000000000aa"}, "state": "closed", "merged_at": "2026-10-02T08:00:00Z", "created_at": "2026-10-01T04:20:00Z"},
 {"number": 11, "head": {"ref": "task/issue-2-pickup", "sha": "bbbbbb30000000000000000000000000000000bb"}, "state": "closed", "merged_at": "2026-10-05T08:00:00Z", "created_at": "2026-10-03T04:20:00Z"},
 {"number": 12, "head": {"ref": "task/issue-3-boss",   "sha": "cccccc30000000000000000000000000000000cc"}, "state": "open",   "merged_at": null,                   "created_at": "2026-10-06T04:20:00Z"},
 {"number": 13, "head": {"ref": "worktree-issue-4",    "sha": "ddddddd0000000000000000000000000000000dd"}, "state": "closed", "merged_at": "2026-09-20T08:00:00Z", "created_at": "2026-09-19T04:20:00Z"},
 {"number": 14, "head": {"ref": "tools/my-own-branch", "sha": "eeeeeee0000000000000000000000000000000ee"}, "state": "open",   "merged_at": null,                   "created_at": "2026-10-07T04:20:00Z"},
 {"number": 15, "head": {"ref": "task/issue-5-shop",   "sha": "ffffff20000000000000000000000000000000ff"}, "state": "closed", "merged_at": "2026-10-10T08:00:00Z", "created_at": "2026-10-08T04:20:00Z"}
]
JSON
    _rr_review 10 101 cursor-review 1 pass           2026-10-01T05:00:00Z aaaaaaa0000000000000000000000000000000aa
    _rr_review 11 111 cursor-review 1 changes-needed 2026-10-03T05:00:00Z bbbbbb1
    _rr_review 11 112 cursor-review 2 pass           2026-10-04T05:00:00Z bbbbbb2
    _rr_review 12 121 review-pr     1 changes-needed 2026-10-06T05:00:00Z cccccc1
    _rr_review 12 122 review-pr     2 changes-needed 2026-10-07T05:00:00Z cccccc2
    _rr_review 12 123 review-pr     3 escalate       2026-10-08T05:00:00Z cccccc3
    _rr_review 14 141 cursor-review 1 pass           2026-10-07T05:00:00Z eeeeeee
    _rr_review 15 151 review-pr     1 pass           2026-10-08T05:00:00Z ffffff1
    _rr_review 15 152 cursor-review 1 changes-needed 2026-10-08T06:00:00Z ffffff1
    _rr_review 15 153 cursor-review 2 pass           2026-10-09T06:00:00Z ffffff2
    # 11: two inline findings in round 1, one more in an unanchored comment.
    _rr_inline 11 111 f1 major 1
    _rr_inline 11 111 f2 minor 1
    /bin/cat > "$MOCK_GH_DIR/issue-comments-11.json" <<'JSON'
[{"body": "<!-- cursor-review repo=acme/game pr=11 round=1 head=abc1234 model=grok verdict=changes-needed request_id=r -->\n\n### Round 1 findings that are not inline threads\n\ntext\n<!-- finding:f3 severity:blocker round:1 -->\n"},
 {"body": "A human's comment that quotes `<!-- finding:f9 severity:major round:1 -->` carries no lane marker."}]
JSON
    # 12: one finding, and a reply that quotes its tag — a reply is not a finding.
    _rr_inline 12 121 f1 major 1
    _rr_reply  12 f1 major 1
}

_rr_teardown() {
    /bin/rm -rf "$RR_TMP"
}

# _rr_review <pr> <review id> <lane> <round> <verdict> <submitted_at> <head>
_rr_review() {
    local f="$MOCK_GH_DIR/reviews-$1.json"
    [[ -f "$f" ]] || echo '[]' > "$f"
    "$JQ_BIN" --argjson id "$2" --arg at "$6" \
        --arg body "<!-- $3 repo=acme/game pr=$1 round=$4 head=$7 model=some-model verdict=$5 gate=passed -->
## Review" \
        '. + [{id: $id, body: $body, submitted_at: $at}]' "$f" > "$f.new" && /bin/mv "$f.new" "$f"
}

# _rr_inline <pr> <review id> <finding id> <severity> <round>
_rr_inline() {
    local f="$MOCK_GH_DIR/review-comments-$1.json"
    [[ -f "$f" ]] || echo '[]' > "$f"
    "$JQ_BIN" --argjson rid "$2" \
        --arg body "**$3**

text

<!-- finding:$3 severity:$4 round:$5 -->" \
        '. + [{pull_request_review_id: $rid, body: $body}]' "$f" > "$f.new" && /bin/mv "$f.new" "$f"
}

# _rr_reply <pr> <finding id> <severity> <round> — a reply posted outside any marked review
_rr_reply() {
    local f="$MOCK_GH_DIR/review-comments-$1.json"
    "$JQ_BIN" --arg body "Fixed. > <!-- finding:$2 severity:$3 round:$4 -->" \
        '. + [{pull_request_review_id: 999, in_reply_to_id: 1, body: $body}]' "$f" > "$f.new" && /bin/mv "$f.new" "$f"
}

test_review_rollup_counts_rounds_and_findings_per_pull_request() {
    _rr_setup
    local rc=0 out
    out=$("$RR_BIN" --json)
    assert_exit 0 $? "the rollup succeeds" || rc=1
    assert_equal "1 pass 0" "$(echo "$out" | "$JQ_BIN" -r '.repos[0].prs[] | select(.number==10) | "\(.rounds) \(.final_verdict) \(.findings.total)"')" \
        "a PR that passed first time is one round and no findings" || rc=1
    assert_equal "2 pass 1/1/1" "$(echo "$out" | "$JQ_BIN" -r '.repos[0].prs[] | select(.number==11) | "\(.rounds) \(.final_verdict) \(.findings.blocker)/\(.findings.major)/\(.findings.minor)"')" \
        "inline findings and the unanchored comment's finding are all counted, once each" || rc=1
    assert_equal "3 escalate 1" "$(echo "$out" | "$JQ_BIN" -r '.repos[0].prs[] | select(.number==12) | "\(.rounds) \(.final_verdict) \(.findings.total)"')" \
        "a reply that quotes a finding's tag is not a second finding" || rc=1
    _rr_teardown
    return $rc
}

test_review_rollup_reads_a_review_pr_marker_that_names_no_model() {
    # post-review accepts a marker that stops at head= and carries no model=,
    # and older review-pr reviews were posted that way (test_pr_feedback.sh
    # stores one). A reader that insists on model= counts those PRs as having
    # no review at all.
    _rr_setup
    local rc=0 out
    /bin/cat > "$MOCK_GH_DIR/reviews-13.json" <<'JSON'
[{"id": 131, "submitted_at": "2026-09-19T05:00:00Z",
  "body": "<!-- review-pr repo=acme/game pr=13 round=1 head=ddddddd verdict=changes-needed gate=passed -->\n## Review"}]
JSON
    out=$("$RR_BIN" --json)
    assert_equal "1 changes-needed 0" "$(echo "$out" | "$JQ_BIN" -r '.repos[0].prs[] | select(.number==13) | "\(.rounds) \(.final_verdict) \(.models | length)"')" \
        "the review counts, with its round and verdict, and no model is invented" || rc=1
    assert_equal "0" "$(echo "$out" | "$JQ_BIN" -r '.total.unmarked')" \
        "so the PR is no longer unmarked" || rc=1
    _rr_teardown
    return $rc
}

test_review_rollup_leaves_the_humans_own_pull_requests_out() {
    _rr_setup
    local rc=0 out
    out=$("$RR_BIN" --json)
    assert_equal "10 11 12 13 15" "$(echo "$out" | "$JQ_BIN" -r '[.repos[0].prs[].number] | sort | map(tostring) | join(" ")')" \
        "only agent branches are rolled up by default" || rc=1
    out=$("$RR_BIN" --json --all)
    assert_equal "6" "$(echo "$out" | "$JQ_BIN" -r '.repos[0].prs | length')" \
        "--all takes every pull request" || rc=1
    _rr_teardown
    return $rc
}

test_review_rollup_never_sums_the_two_lanes_or_takes_an_overturned_pass_as_clean() {
    _rr_setup
    local rc=0 out
    out=$("$RR_BIN" --json)
    assert_equal "2 1/2 false" "$(echo "$out" | "$JQ_BIN" -r '.repos[0].prs[] | select(.number==15) | "\(.rounds) \(.rounds_by_lane["review-pr"])/\(.rounds_by_lane["cursor-review"]) \(.clean)"')" \
        "three reviews over two lanes are two rounds, and one lane's pass is not a clean PR" || rc=1
    assert_equal "true false" "$(echo "$out" | "$JQ_BIN" -r '[.repos[0].prs[] | select(.number==12 or .number==15) | .at_round_cap] | map(tostring) | join(" ")')" \
        "the cap is per lane: only the PR with three rounds in one lane is at it" || rc=1
    _rr_teardown
    return $rc
}

test_review_rollup_names_a_merge_whose_commit_no_reviewer_passed() {
    _rr_setup
    local rc=0 out
    out=$("$RR_BIN" --json)
    assert_equal "11" "$(echo "$out" | "$JQ_BIN" -r '[.repos[0].prs[] | select(.merged_head_unpassed) | .number] | map(tostring) | join(" ")')" \
        "a pass on an earlier commit does not cover the commit that merged" || rc=1
    assert_equal "false false" "$(echo "$out" | "$JQ_BIN" -r '[.repos[0].prs[] | select(.number==10 or .number==13) | .merged_head_unpassed] | map(tostring) | join(" ")')" \
        "a pass on the merged commit clears it, and a PR with no marker is counted as unmarked instead" || rc=1
    _rr_teardown
    return $rc
}

test_review_rollup_summarises_the_figures_a_wrong_count_would_hide() {
    _rr_setup
    local rc=0 out
    out=$("$RR_BIN" --json)
    assert_equal "5 4 1" "$(echo "$out" | "$JQ_BIN" -r '.total | "\(.agent_prs) \(.reviewed) \(.unmarked)"')" \
        "an agent PR with no marked review is counted, not dropped" || rc=1
    assert_equal "1 1 1" "$(echo "$out" | "$JQ_BIN" -r '.total | "\(.clean) \(.at_round_cap) \(.merged_head_unpassed)"')" \
        "clean PRs, PRs at the round cap, and merges on an unpassed commit" || rc=1
    assert_equal "2.0 4" "$(echo "$out" | "$JQ_BIN" -r '.total | "\(.median_rounds) \(.findings.total)"')" \
        "median rounds over reviewed PRs, and findings in all" || rc=1
    _rr_teardown
    return $rc
}

test_review_rollup_narrows_to_pull_requests_opened_since_a_date() {
    _rr_setup
    local rc=0 out
    out=$("$RR_BIN" --json --since 2026-10-03)
    assert_equal "11 12 15" "$(echo "$out" | "$JQ_BIN" -r '[.repos[0].prs[].number] | sort | map(tostring) | join(" ")')" \
        "the window is the PR's opening date, both ends whole days" || rc=1
    out=$("$RR_BIN" --json --since 2026-10-03 --until 2026-10-06)
    assert_equal "11 12" "$(echo "$out" | "$JQ_BIN" -r '[.repos[0].prs[].number] | sort | map(tostring) | join(" ")')" \
        "--until closes the other end, on the day it names" || rc=1
    out=$("$RR_BIN" --until 06/10/2026 2>&1)
    assert_exit 2 $? "and takes the same date form" || rc=1
    _rr_teardown
    return $rc
}

test_review_rollup_prints_a_table_and_fails_loudly_on_a_failed_query() {
    _rr_setup
    local rc=0 out
    out=$("$RR_BIN")
    assert_contains "$out" "acme/game" "the table names the repo" || rc=1
    assert_contains "$out" "TOTAL" "and ends in a total row" || rc=1
    /bin/rm "$MOCK_GH_DIR/pulls.json"
    out=$("$RR_BIN" 2>&1)
    assert_exit 1 $? "a repo that cannot be read is a failure, not an empty rollup" || rc=1
    assert_contains "$out" "acme/game" "and the error names the repo" || rc=1
    printf '%s\n' 'REVIEW_ROUND_MAX=3' 'REPOS_BY_PRIORITY=(' '    "acme/gone"' '    "acme/game"' ')' > "$RR_CONF"
    /bin/mkdir -p "$MOCK_GH_DIR/acme-gone" "$MOCK_GH_DIR/acme-game"
    echo '[]' > "$MOCK_GH_DIR/acme-game/pulls.json"
    out=$("$RR_BIN" --json --keep-going 2>/dev/null)
    assert_exit 0 $? "--keep-going reports the repos it could read" || rc=1
    assert_equal "acme/gone:true acme/game:false" "$(echo "$out" | "$JQ_BIN" -r '[.repos[] | "\(.repo):\(has("error"))"] | join(" ")')" \
        "and the one it could not is a row with an error, not a missing row" || rc=1
    /bin/rm "$MOCK_GH_DIR/acme-game/pulls.json"
    out=$("$RR_BIN" --json --keep-going 2>/dev/null)
    assert_exit 0 $? "with --keep-going even a roster that all failed is an answer" || rc=1
    assert_equal "true true 0" "$(echo "$out" | "$JQ_BIN" -r '"\(.repos[0] | has("error")) \(.repos[1] | has("error")) \(.total.agent_prs)"')" \
        "every row says it failed, so the caller cannot read the zero as a quiet week" || rc=1
    printf '%s\n' 'ACTIVE_REPOS=(' '    "acme/game"   # the pilot' ')' 'REPOS_BY_PRIORITY=(' '    "acme/game"' '    "acme/gone"' ')' > "$RR_CONF"
    echo '[]' > "$MOCK_GH_DIR/acme-game/pulls.json"
    out=$("$RR_BIN" --json --active 2>&1)
    assert_exit 0 $? "--active never asks a dormant repo, so one that is gone cannot fail it" || rc=1
    assert_equal "acme/game" "$(echo "$out" | "$JQ_BIN" -r '[.repos[].repo] | join(" ")')" \
        "and rolls up ACTIVE_REPOS only" || rc=1
    out=$("$RR_BIN" --since yesterday 2>&1)
    assert_exit 2 $? "a date that is not YYYY-MM-DD is a usage error" || rc=1
    _rr_teardown
    return $rc
}
