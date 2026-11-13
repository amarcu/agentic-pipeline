#!/bin/bash
# Tests for review-pr/scripts/post-review — how a review-pr review reaches the PR.
#
# The model used to compose the POST itself, and a long body pushed it to
# `gh api … -F body=@file`, which the headless deny-net refuses. The review-pr
# eval of 2026-09-27 caught one run posting and the next refused twice. The
# script posts from the bundle, so the outcome no longer depends on phrasing,
# and it reads nothing outside a review bundle.

_rp_setup() {
    RP_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-reviewpost.XXXXXX)
    RP_BUNDLE=$(/usr/bin/mktemp -d /tmp/review-test.XXXXXX)
    export MOCK_GH_DIR="$RP_TMP/gh"
    export PATH="$FIXTURES_DIR/mock-gh:$PATH"
    export JQ_BIN
    /bin/mkdir -p "$MOCK_GH_DIR" "$RP_BUNDLE/review"
    echo '[]' > "$MOCK_GH_DIR/reviews.json"
    RP_SCRIPT="$REPO_ROOT/skills/review-pr/scripts/post-review"
    /bin/cat > "$RP_BUNDLE/review/summary.md" <<'MD'
<!-- review-pr repo=acme/game pr=7 round=1 head=abc1234 model=m verdict=changes-needed gate=passed -->
One major: the cap refuses a charge that lands exactly on it.
<!-- agentic-skills: skill=review-pr repo=acme/game pr=7 routine=pr-review-night run=r1 model=m -->
MD
    /usr/bin/python3 -c '
import json, sys
json.dump([{"path": "src/ledger.py", "line": 15,
            "body": "`>=` refuses a charge exactly at the cap.\n\n<!-- finding:f1 severity:major round:1 -->"}],
          open(sys.argv[1], "w"))
' "$RP_BUNDLE/review/findings.json"
}

_rp_teardown() {
    /bin/rm -rf "$RP_TMP" "$RP_BUNDLE"
}

test_review_post_posts_the_body_and_its_inline_findings() {
    _rp_setup
    local rc=0 out posted
    out=$("$RP_SCRIPT" acme/game 7 "$RP_BUNDLE" 2>&1)
    assert_exit 0 $? "the review posts" || rc=1
    assert_contains "$out" "POSTED: review=" "and says so" || rc=1
    assert_contains "$out" "mode=inline" "with its findings as threads" || rc=1
    posted="$MOCK_GH_DIR/review-post-1.json"
    assert_equal "COMMENT" "$("$JQ_BIN" -r .event "$posted")" "as a COMMENT review" || rc=1
    assert_contains "$("$JQ_BIN" -r .body "$posted")" "<!-- review-pr repo=acme/game" "carrying the verdict marker" || rc=1
    assert_equal "src/ledger.py:15:RIGHT" "$("$JQ_BIN" -r '.comments[0] | "\(.path):\(.line):\(.side)"' "$posted")" \
        "the finding anchored to its line" || rc=1
    _rp_teardown
    return $rc
}

test_review_post_keeps_every_finding_when_github_rejects_the_anchors() {
    _rp_setup
    local rc=0 out body
    /usr/bin/touch "$MOCK_GH_DIR/reviews-reject-inline"
    out=$("$RP_SCRIPT" acme/game 7 "$RP_BUNDLE" 2>&1)
    assert_exit 0 $? "a 422 on the anchors still posts" || rc=1
    assert_contains "$out" "mode=body" "as a body-only review" || rc=1
    body=$("$JQ_BIN" -r .body "$MOCK_GH_DIR/review-post-2.json")
    assert_contains "$body" "refuses a charge exactly at the cap" "with the finding spelled out" || rc=1
    assert_contains "$body" "<!-- finding:f1 severity:major round:1 -->" "and its tag" || rc=1
    assert_equal "<!-- agentic-skills: skill=review-pr" "$(printf '%s\n' "$body" | /usr/bin/tail -1 | /usr/bin/cut -c1-36)" \
        "and the attribution marker still last" || rc=1
    # iterate-on-pr skips a review body as reviewer context, so the findings
    # must also arrive as a tagged comment it acts on (Grok, PR #69 f1).
    assert_file_exists "$MOCK_GH_DIR/issue-comment-post-1.json" "the findings also go up as an issue comment" || rc=1
    body=$("$JQ_BIN" -r .body "$MOCK_GH_DIR/issue-comment-post-1.json" 2>/dev/null)
    assert_contains "$body" "<!-- finding:f1 severity:major round:1 -->" "carrying the tag iterate-on-pr keys on" || rc=1
    assert_contains "$body" "<!-- review-pr repo=acme/game" "and the review marker that names the lane" || rc=1
    _rp_teardown
    return $rc
}

test_review_post_reads_nothing_outside_a_review_bundle() {
    # The deny-net refuses file bodies so a run cannot read an arbitrary local
    # file into an API call. The script keeps that: bundles only.
    _rp_setup
    local rc=0 status=0
    /bin/mkdir -p "$RP_TMP/elsewhere/review"
    /bin/cp "$RP_BUNDLE/review/"* "$RP_TMP/elsewhere/review/"
    "$RP_SCRIPT" acme/game 7 "$RP_TMP/elsewhere" >/dev/null 2>&1 || status=$?
    assert_equal "2" "$status" "a directory outside /tmp/review-* is refused" || rc=1
    if [[ -f "$MOCK_GH_DIR/review-post-1.json" ]]; then
        echo "  FAIL: something was posted from outside a bundle"; rc=1
    fi
    _rp_teardown
    return $rc
}

test_review_post_refuses_a_review_the_next_round_cannot_read() {
    _rp_setup
    local rc=0 status=0
    printf 'A summary with no verdict marker\n' > "$RP_BUNDLE/review/summary.md"
    "$RP_SCRIPT" acme/game 7 "$RP_BUNDLE" >/dev/null 2>&1 || status=$?
    assert_equal "2" "$status" "no verdict marker, no post" || rc=1
    _rp_teardown
    _rp_setup
    /usr/bin/python3 -c 'import json,sys; json.dump([{"path":"a.py","line":1,"body":"no tag"}], open(sys.argv[1],"w"))' \
        "$RP_BUNDLE/review/findings.json"
    status=0; "$RP_SCRIPT" acme/game 7 "$RP_BUNDLE" >/dev/null 2>&1 || status=$?
    assert_equal "2" "$status" "a finding without its tag is refused, because iterate-on-pr keys on it" || rc=1
    if [[ -f "$MOCK_GH_DIR/review-post-1.json" ]]; then
        echo "  FAIL: a malformed review was posted"; rc=1
    fi
    _rp_teardown
    return $rc
}

test_review_post_is_how_review_pr_posts() {
    local rc=0
    if ! /usr/bin/grep -q 'scripts/post-review "$REPO" "$PR" "$BUNDLE"' "$REPO_ROOT/skills/review-pr/SKILL.md"; then
        echo "  FAIL: review-pr/SKILL.md no longer posts through scripts/post-review"; rc=1
    fi
    if /usr/bin/grep -qE 'gh api "repos/\$REPO/pulls/\$PR/reviews" -X POST' "$REPO_ROOT/skills/review-pr/SKILL.md"; then
        echo "  FAIL: review-pr/SKILL.md shows a raw gh api POST again"; rc=1
    fi
    return $rc
}

test_review_post_a_script_posted_review_is_graded_by_the_eval() {
    # End to end: the real script posts through the eval's recording gh, and the
    # eval's grader scores it. A review the grader could not read would score
    # every run of the fixed skill as "posted nothing" (Grok, PR #69 f2).
    _rp_setup
    local rc=0 run="$RP_TMP/run" grade
    /bin/mkdir -p "$run/case"
    /bin/cat > "$run/case/diff.patch" <<'EOF'
diff --git a/src/ledger.py b/src/ledger.py
--- a/src/ledger.py
+++ b/src/ledger.py
@@ -13,6 +13,8 @@ class Ledger:
     def charge(self, amount):
         """Add `amount` to the day's spend, or refuse it."""
+        if self.spent + amount >= self.cap:
+            raise CapExceeded("%.2f would pass the cap" % amount)
         self.spent += amount
         return self.spent
EOF
    printf 'api repos/.*/reviews.*(-X|--method) POST\t0\t-\napi repos/.*/issues/.*/comments\t0\t-\n' > "$run/routes.tsv"
    echo '[]' > "$run/reviews.json"
    printf 'REVIEW: run=eval repo=acme/game pr=7 round=1 head=abc1234 verdict=changes-needed gate=passed findings=0/1/0\n' \
        > "$run/result.txt"
    PATH="$RUNTIME_DIR/tests/evals/bin:$PATH" EVAL_GH_LOG="$run/gh.log" EVAL_GH_ROUTES="$run/routes.tsv" \
        EVAL_REVIEWS_FILE="$run/reviews.json" "$RP_SCRIPT" acme/game 7 "$RP_BUNDLE" >/dev/null 2>&1
    grade=$(/usr/bin/python3 "$RUNTIME_DIR/tests/evals/review-pr/grade.py" "$run" defect --json)
    assert_equal "catch" "$(printf '%s' "$grade" | "$JQ_BIN" -r .outcome)" \
        "a finding the script posted on the planted line grades as a catch" || rc=1
    _rp_teardown
    return $rc
}
