#!/bin/bash
# Tests for the review-pr eval harness: its graders and its recording gh.
#
# The eval itself spends real API calls and is not part of `make test`. What is
# tested here is everything that decides what a run MEANS, against recorded
# runs: a grader that passes a miss is worse than no measurement, because it
# reports a number nobody checks (issue #46).

_re_setup() {
    RE_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-revieweval.XXXXXX)
    RE_DIR="$RUNTIME_DIR/tests/evals"
    RE_GRADE="$RE_DIR/review-pr/grade.py"
    RE_GH="$RE_DIR/bin/gh"
    RUN="$RE_TMP/run"
    /bin/mkdir -p "$RUN/case" "$RUN/gh.log.d"
    # The diff the case under review adds. In this synthetic hunk the planted
    # comparison lands on line 14 of src/ledger.py, which is the line a finding
    # must anchor to; the real fixture computes its own.
    /bin/cat > "$RUN/case/diff.patch" <<'EOF'
diff --git a/src/ledger.py b/src/ledger.py
--- a/src/ledger.py
+++ b/src/ledger.py
@@ -12,6 +12,8 @@ class Ledger:
     def charge(self, amount):
         """Add `amount` to the day's spend, or refuse it."""
+        if self.spent + amount >= self.cap:
+            raise CapExceeded("%.2f would pass the cap" % amount)
         self.spent += amount
         return self.spent
EOF
}

_re_teardown() {
    /bin/rm -rf "$RE_TMP"
}

# Records one gh call as the recording gh does: NUL-separated, so a multi-line
# finding body stays one argument.
_re_call() {
    local n=$1; shift
    /usr/bin/printf '%s\0' "$@" > "$RUN/gh.log.d/$n.argv"
}

# A posted review: the summary, then one inline comment per finding triple.
_re_post_review() {  # $1 = summary, then path line body … in threes
    local summary="$1"; shift
    local -a argv=(api "repos/acme/evalrepo/pulls/7/reviews" -X POST -f "event=COMMENT" -f "body=$summary")
    while [[ $# -ge 3 ]]; do
        argv+=(-F "comments[][path]=$1" -F "comments[][line]=$2" -F "comments[][body]=$3")
        shift 3
    done
    _re_call 002 "${argv[@]}"
}

_re_result() {  # $1 = the final message
    printf '%s\n' "$1" > "$RUN/result.txt"
}

_re_grade() {  # $1 = case
    /usr/bin/python3 "$RE_GRADE" "$RUN" "$1" --json
}

_RE_REVIEW_OK="REVIEW: run=eval repo=acme/evalrepo pr=7 round=1 head=abc1234 verdict=changes-needed gate=passed findings=0/1/0"
_RE_REVIEW_PASS="REVIEW: run=eval repo=acme/evalrepo pr=7 round=1 head=abc1234 verdict=pass gate=passed findings=0/0/0"

test_review_eval_grades_a_caught_defect_as_a_catch() {
    _re_setup
    local rc=0 out
    _re_result "Reviewed. One major.

$_RE_REVIEW_OK"
    _re_post_review "<!-- review-pr repo=acme/evalrepo pr=7 round=1 head=abc verdict=changes-needed gate=passed -->" \
        "src/ledger.py" "14" "**f1 — major**

\`>=\` refuses a charge landing exactly on the cap, which criterion 2 requires to be allowed.

<!-- finding:f1 severity:major round:1 -->"
    out=$(_re_grade defect)
    assert_equal "catch" "$(printf '%s' "$out" | "$JQ_BIN" -r .outcome)" \
        "a finding on the planted line naming the comparison is a catch" || rc=1
    assert_equal "14" "$(printf '%s' "$out" | "$JQ_BIN" -r '.planted_line | tostring')" \
        "and the planted line is read from the case's own diff" || rc=1
    _re_teardown
    return $rc
}

test_review_eval_grades_the_right_file_but_the_wrong_line_as_a_miss() {
    # Naming the file is not finding the defect.
    _re_setup
    local rc=0 out
    _re_result "$_RE_REVIEW_OK"
    _re_post_review "summary" "src/ledger.py" "18" "**f1 — major**

This method could use a docstring.

<!-- finding:f1 severity:major round:1 -->"
    out=$(_re_grade defect)
    assert_equal "miss" "$(printf '%s' "$out" | "$JQ_BIN" -r .outcome)" "wrong line is a miss" || rc=1
    _re_teardown
    return $rc
}

test_review_eval_grades_a_vague_finding_on_the_right_line_as_a_miss() {
    _re_setup
    local rc=0 out
    _re_result "$_RE_REVIEW_OK"
    _re_post_review "summary" "src/ledger.py" "14" "**f1 — major**

This guard looks risky and should be reconsidered.

<!-- finding:f1 severity:major round:1 -->"
    out=$(_re_grade defect)
    assert_equal "miss" "$(printf '%s' "$out" | "$JQ_BIN" -r .outcome)" \
        "a finding that names nothing specific is a miss" || rc=1
    _re_teardown
    return $rc
}

test_review_eval_grades_a_pass_verdict_as_a_miss_even_with_the_finding() {
    _re_setup
    local rc=0 out
    _re_result "$_RE_REVIEW_PASS"
    _re_post_review "summary" "src/ledger.py" "14" "**f1 — minor**

\`>=\` refuses a charge at the cap.

<!-- finding:f1 severity:minor round:1 -->"
    out=$(_re_grade defect)
    assert_equal "miss" "$(printf '%s' "$out" | "$JQ_BIN" -r .outcome)" \
        "a pass verdict on a PR that breaks a criterion is a miss" || rc=1
    _re_teardown
    return $rc
}

test_review_eval_grades_a_quiet_clean_run_as_clean() {
    _re_setup
    local rc=0 out
    _re_result "REVIEW: run=eval repo=acme/evalrepo pr=7 round=1 head=abc1234 verdict=pass gate=passed findings=0/0/0"
    _re_post_review "<!-- review-pr … -->"
    out=$(_re_grade clean)
    assert_equal "clean" "$(printf '%s' "$out" | "$JQ_BIN" -r .outcome)" \
        "no blocker and no major is a clean run" || rc=1
    _re_teardown
    return $rc
}

test_review_eval_grades_an_invented_major_as_a_false_finding() {
    _re_setup
    local rc=0 out
    _re_result "REVIEW: run=eval repo=acme/evalrepo pr=7 round=1 head=abc1234 verdict=changes-needed gate=passed findings=0/1/0"
    _re_post_review "summary" "src/ledger.py" "15" "**f1 — major**

The guard should also log.

<!-- finding:f1 severity:major round:1 -->"
    out=$(_re_grade clean)
    assert_equal "false-finding" "$(printf '%s' "$out" | "$JQ_BIN" -r .outcome)" \
        "a major on a PR that meets its criteria is a false finding" || rc=1
    assert_contains "$(printf '%s' "$out" | "$JQ_BIN" -r '.failures[0]')" "raised a major" \
        "and the failure names it" || rc=1
    _re_teardown
    return $rc
}

test_review_eval_catches_counts_that_no_finding_backs() {
    # A REVIEW: line claiming a major with nothing posted is still noise a
    # human has to read.
    _re_setup
    local rc=0 out
    _re_result "REVIEW: run=eval repo=acme/evalrepo pr=7 round=1 head=abc1234 verdict=changes-needed gate=passed findings=1/0/0"
    _re_post_review "summary"
    out=$(_re_grade clean)
    assert_equal "false-finding" "$(printf '%s' "$out" | "$JQ_BIN" -r .outcome)" \
        "counts with no posted finding fail the clean case" || rc=1
    _re_teardown
    return $rc
}

test_review_eval_fails_a_run_that_posted_nothing() {
    _re_setup
    local rc=0 out
    _re_result "$_RE_REVIEW_OK"
    _re_call 001 pr view 7 --repo acme/evalrepo --json state
    out=$(_re_grade defect)
    assert_equal "fail" "$(printf '%s' "$out" | "$JQ_BIN" -r .outcome)" \
        "a review nobody can see is not a review" || rc=1
    _re_teardown
    return $rc
}

test_review_eval_fails_a_run_with_no_contract_line() {
    _re_setup
    local rc=0 out
    _re_result "I reviewed the pull request and it looks good to me."
    _re_post_review "summary"
    out=$(_re_grade defect)
    assert_equal "no-contract-line" "$(printf '%s' "$out" | "$JQ_BIN" -r .outcome)" \
        "prose instead of the REVIEW: line is its own outcome" || rc=1
    _re_teardown
    return $rc
}

test_review_eval_reports_a_fixture_gap_as_a_harness_gap() {
    # The fixture owing the skill an answer must never be scored as the skill
    # missing a defect. The real recording gh writes the gap, so the grader is
    # driven by what that call actually leaves behind, not by a hand-planted
    # token (Grok, PR #64 f2).
    _re_setup
    local rc=0 out
    _re_result "$_RE_REVIEW_OK"
    printf 'pr view\t0\t-\n' > "$RE_TMP/routes.tsv"
    EVAL_GH_LOG="$RUN/gh.log" EVAL_GH_ROUTES="$RE_TMP/routes.tsv" \
        "$RE_GH" api "repos/acme/evalrepo/commits" >/dev/null 2>&1
    out=$(_re_grade defect)
    assert_equal "harness-gap" "$(printf '%s' "$out" | "$JQ_BIN" -r .outcome)" \
        "an unanswered gh call is a harness gap" || rc=1
    assert_contains "$(printf '%s' "$out" | "$JQ_BIN" -r '.failures[0]')" "commits" \
        "and the failure names the call the fixture could not answer" || rc=1
    _re_teardown
    return $rc
}

test_review_eval_gh_applies_the_jq_the_skill_verifies_with() {
    # review-pr Step 6 reads its own post back with `--jq '.[-1].body'`. A mock
    # that ignores --jq answers with the whole array and fails the skill on the
    # harness's behalf (Grok, PR #64 f1).
    _re_setup
    local rc=0 body
    export EVAL_GH_LOG="$RE_TMP/gh.log"
    export EVAL_GH_ROUTES="$RE_TMP/routes.tsv"
    export EVAL_REVIEWS_FILE="$RE_TMP/reviews.json"
    export EVAL_JQ="$JQ_BIN"
    echo '[]' > "$EVAL_REVIEWS_FILE"
    printf 'api repos/.*/reviews.*(-X|--method) POST\t0\tposted.json\napi repos/.*/reviews\t0\treviews.json\n' \
        > "$EVAL_GH_ROUTES"
    echo '{"id": 1}' > "$RE_TMP/posted.json"

    "$RE_GH" api "repos/acme/evalrepo/pulls/7/reviews" -X POST -f event=COMMENT \
        -f "body=<!-- review-pr repo=acme/evalrepo pr=7 round=1 head=abc -->
Verdict: changes-needed" > /dev/null
    body=$("$RE_GH" api "repos/acme/evalrepo/pulls/7/reviews" --jq '.[-1].body')
    assert_equal "<!-- review-pr repo=acme/evalrepo pr=7 round=1 head=abc -->" \
        "$(printf '%s' "$body" | /usr/bin/head -1)" \
        "the verify reads the body itself, not the JSON wrapper" || rc=1
    unset EVAL_GH_LOG EVAL_GH_ROUTES EVAL_REVIEWS_FILE EVAL_JQ
    _re_teardown
    return $rc
}

test_review_eval_gh_remembers_a_posted_review_for_the_verify_that_follows() {
    # review-pr Step 6 reads the review back. Serving a static empty list would
    # fail its own verify and teach the skill to trust an unseen POST.
    _re_setup
    local rc=0 body
    export EVAL_GH_LOG="$RE_TMP/gh.log"
    export EVAL_GH_ROUTES="$RE_TMP/routes.tsv"
    export EVAL_REVIEWS_FILE="$RE_TMP/reviews.json"
    echo '[]' > "$EVAL_REVIEWS_FILE"
    printf 'api repos/.*/reviews.*(-X|--method) POST\t0\tposted.json\napi repos/.*/reviews\t0\treviews.json\n' \
        > "$EVAL_GH_ROUTES"
    echo '{"id": 1}' > "$RE_TMP/posted.json"

    "$RE_GH" api "repos/acme/evalrepo/pulls/7/reviews" -X POST -f event=COMMENT \
        -f "body=<!-- review-pr repo=acme/evalrepo pr=7 round=1 head=abc -->
Verdict: changes-needed" > /dev/null
    body=$("$RE_GH" api "repos/acme/evalrepo/pulls/7/reviews")
    assert_contains "$body" "review-pr repo=acme/evalrepo" \
        "the GET after the POST serves what was posted" || rc=1
    assert_contains "$body" "Verdict: changes-needed" "in full, newlines included" || rc=1
    assert_file_exists "$RE_TMP/gh.log.d/001.argv" "and each call's argv is recorded" || rc=1
    unset EVAL_GH_LOG EVAL_GH_ROUTES EVAL_REVIEWS_FILE
    _re_teardown
    return $rc
}

test_review_eval_gh_refuses_a_call_no_route_answers() {
    _re_setup
    local rc=0 out status=0
    export EVAL_GH_LOG="$RE_TMP/gh.log"
    export EVAL_GH_ROUTES="$RE_TMP/routes.tsv"
    printf 'pr view\t0\t-\n' > "$EVAL_GH_ROUTES"
    out=$("$RE_GH" api "repos/acme/evalrepo/commits" 2>&1) || status=$?
    assert_equal "97" "$status" "an unrouted call exits 97, not 0" || rc=1
    assert_contains "$out" "no route for" "and says so" || rc=1
    assert_contains "$(/bin/cat "$EVAL_GH_LOG")" "UNHANDLED" "the log records it for the grader" || rc=1
    unset EVAL_GH_LOG EVAL_GH_ROUTES
    _re_teardown
    return $rc
}

# One graded run on disk, the way the runner leaves it.
_re_recorded_run() {  # $1 = out dir, $2 = name, $3 = case, $4 = outcome, $5 = failure, $6 = result line
    local dir="$1/$2"
    /bin/mkdir -p "$dir"
    printf '%s\n' "$6" > "$dir/result.txt"
    /usr/bin/python3 - "$dir/grade.json" "$3" "$4" "$5" <<'PY'
import json, sys
path, case, outcome, failure = sys.argv[1:5]
json.dump({"case": case, "outcome": outcome,
           "failures": [failure] if failure else []}, open(path, "w"))
PY
}

test_review_eval_report_quotes_a_transcript_line_for_every_failed_run() {
    # met=1/3 tells a reader the skill is unreliable and nothing about what the
    # other two runs did. A score nobody can trace is a number nobody acts on
    # (Grok, PR #64 f3).
    _re_setup
    local rc=0 out
    local dir="$RE_TMP/out"
    _re_recorded_run "$dir" "defect-1" defect catch "" "$_RE_REVIEW_OK"
    _re_recorded_run "$dir" "defect-2" defect miss "no finding anchored to src/ledger.py:14" \
        "REVIEW: run=eval repo=acme/evalrepo pr=7 round=1 head=deadbee verdict=pass gate=passed findings=0/0/0"
    _re_recorded_run "$dir" "clean-1" clean clean "" "$_RE_REVIEW_PASS"
    _re_recorded_run "$dir" "clean-2" clean false-finding "raised a major on src/ledger.py:14" \
        "REVIEW: run=eval repo=acme/evalrepo pr=7 round=1 head=cafe123 verdict=changes-needed gate=passed findings=0/1/0"

    out=$(/usr/bin/python3 "$RE_DIR/review-pr/report.py" "$dir")
    assert_exit 1 $? "a report with a failed run exits non-zero" || rc=1
    assert_contains "$out" "case=defect catches=1/2" "catches are counted per case" || rc=1
    assert_contains "$out" "case=clean clean runs=1/2" "and clean runs likewise" || rc=1
    assert_contains "$out" "false-finding runs=1" "with the false findings named as such" || rc=1
    assert_contains "$out" "no finding anchored to src/ledger.py:14" "each failure carries its reason" || rc=1
    assert_contains "$out" "transcript: REVIEW: run=eval repo=acme/evalrepo pr=7 round=1 head=deadbee" \
        "and a line quoted from that run's own transcript" || rc=1
    assert_contains "$out" "head=cafe123" "for the clean case's failure too" || rc=1
    assert_not_contains "$out" "defect-1" "a run that met the bar needs no quoting" || rc=1
    _re_teardown
    return $rc
}

test_review_eval_report_keeps_harness_gaps_out_of_the_score() {
    _re_setup
    local rc=0 out
    local dir="$RE_TMP/out"
    _re_recorded_run "$dir" "defect-1" defect catch "" "$_RE_REVIEW_OK"
    _re_recorded_run "$dir" "defect-2" defect harness-gap "the fixture had no answer for: api repos/x/commits" \
        "REVIEW: run=eval repo=acme/evalrepo pr=7 round=1 head=abc verdict=escalate gate=could-not-run findings=0/0/0"
    out=$(/usr/bin/python3 "$RE_DIR/review-pr/report.py" "$dir")
    assert_contains "$out" "case=defect catches=1/1 harness-gaps=1" \
        "a gap is counted apart and never scored against the skill" || rc=1
    assert_contains "$out" "api repos/x/commits" "and is still named, because the fixture owes it" || rc=1
    _re_teardown
    return $rc
}

test_review_eval_gh_answers_the_bundles_tree_call() {
    # pr-review-bundle reads the tree with a --jq filter, and the mock applies
    # it, so the route must hold what GitHub serves and not a pre-filtered list
    # (Grok, PR #64 f5).
    _re_setup
    local rc=0 out status=0
    export EVAL_GH_LOG="$RE_TMP/gh.log"
    export EVAL_GH_ROUTES="$RE_TMP/case/routes.tsv"
    export EVAL_JQ="$JQ_BIN"
    /bin/mkdir -p "$RE_TMP/repo" "$RE_TMP/case"
    "$RE_DIR/review-pr/seed-repo.sh" "$RE_TMP/repo" > "$RE_TMP/shas.txt"
    local base head
    base=$(/usr/bin/awk '{print $1}' "$RE_TMP/shas.txt")
    head=$(/usr/bin/awk '{print $2}' "$RE_TMP/shas.txt")
    /usr/bin/python3 "$RE_DIR/review-pr/render-case.py" "$RE_TMP/case" "$RE_TMP/repo" \
        task/issue-7-cap-charge "$base" "$head" > /dev/null

    out=$("$RE_GH" api "repos/acme/evalrepo/git/trees/$head?recursive=1" \
        --jq '.tree[] | select(.type=="blob") | .path') || status=$?
    assert_exit 0 "$status" "the bundle's own trees call succeeds" || rc=1
    assert_contains "$out" "src/ledger.py" "and yields the paths it filters for" || rc=1
    assert_not_contains "$out" '"type"' "filtered, not the raw tree object" || rc=1
    unset EVAL_GH_LOG EVAL_GH_ROUTES EVAL_JQ
    _re_teardown
    return $rc
}

test_review_eval_gh_fails_a_filter_it_cannot_apply() {
    # A filter that cannot read its file must not look like an endpoint that
    # returned nothing — that is how a wrong route file hides.
    _re_setup
    local rc=0 status=0
    export EVAL_GH_LOG="$RE_TMP/gh.log"
    export EVAL_GH_ROUTES="$RE_TMP/routes.tsv"
    export EVAL_JQ="$JQ_BIN"
    printf 'api repos/.*/git/trees/\t0\tnot-json.txt\n' > "$EVAL_GH_ROUTES"
    printf 'src/ledger.py\n' > "$RE_TMP/not-json.txt"
    "$RE_GH" api "repos/acme/evalrepo/git/trees/abc" --jq '.tree[].path' >/dev/null 2>&1 || status=$?
    if [[ "$status" -eq 0 ]]; then
        echo "  FAIL: a --jq that could not parse its route file still exited 0"
        rc=1
    fi
    unset EVAL_GH_LOG EVAL_GH_ROUTES EVAL_JQ
    _re_teardown
    return $rc
}

test_review_eval_gh_reads_a_field_from_a_file_as_gh_does() {
    # `-F body=@file` is how a skill posts a long body, and the file lives under a
    # bundle the next run overwrites. Recording the path would leave the grader
    # nothing; the content is what was posted.
    _re_setup
    local rc=0
    export EVAL_GH_LOG="$RE_TMP/gh.log" EVAL_GH_ROUTES="$RE_TMP/routes.tsv" EVAL_REVIEWS_FILE="$RE_TMP/reviews.json"
    echo '[]' > "$EVAL_REVIEWS_FILE"
    printf 'api repos/.*/reviews.*(-X|--method) POST\t0\t-\n' > "$EVAL_GH_ROUTES"
    printf 'FINDING_FROM_FILE on line 14\n<!-- finding:f1 severity:major round:1 -->' > "$RE_TMP/f1.md"
    printf 'SUMMARY_FROM_FILE' > "$RE_TMP/summary.md"
    "$RE_GH" api "repos/acme/evalrepo/pulls/7/reviews" -X POST -f event=COMMENT \
        -F "body=@$RE_TMP/summary.md" -F "comments[][path]=src/ledger.py" \
        -F "comments[][line]=14" -F "comments[][body]=@$RE_TMP/f1.md" >/dev/null
    local argv
    argv=$(/usr/bin/tr '\0' '\n' < "$RE_TMP/gh.log.d/001.argv")
    assert_contains "$argv" "body=SUMMARY_FROM_FILE" "the body is recorded as content" || rc=1
    assert_contains "$argv" "FINDING_FROM_FILE" "and so is each finding" || rc=1
    assert_not_contains "$argv" "=@$RE_TMP" "never as a path" || rc=1
    assert_contains "$(/bin/cat "$EVAL_REVIEWS_FILE")" "SUMMARY_FROM_FILE" "the remembered review holds it too" || rc=1
    unset EVAL_GH_LOG EVAL_GH_ROUTES EVAL_REVIEWS_FILE
    _re_teardown
    return $rc
}

test_review_eval_gh_serves_back_the_inline_comments_it_was_posted() {
    # review-pr reads its own threads back after posting; an unanswered
    # read-back scored a run as a harness gap on 2026-09-27.
    _re_setup
    local rc=0 out
    export EVAL_GH_LOG="$RE_TMP/gh.log" EVAL_GH_ROUTES="$RE_TMP/routes.tsv" \
        EVAL_REVIEWS_FILE="$RE_TMP/reviews.json" EVAL_COMMENTS_FILE="$RE_TMP/comments.json" EVAL_JQ="$JQ_BIN"
    echo '[]' > "$EVAL_REVIEWS_FILE"; echo '[]' > "$EVAL_COMMENTS_FILE"
    printf 'api repos/.*/reviews.*(-X|--method) POST\t0\t-\napi repos/.*/pulls/7/comments\t0\tcomments.json\n' > "$EVAL_GH_ROUTES"
    "$RE_GH" api "repos/acme/evalrepo/pulls/7/reviews" -X POST -f event=COMMENT -f "body=s" \
        -F "comments[][path]=src/ledger.py" -F "comments[][line]=14" -F "comments[][body]=THREAD_ONE" \
        -F "comments[][path]=src/ledger.py" -F "comments[][line]=16" -F "comments[][body]=THREAD_TWO" >/dev/null
    out=$("$RE_GH" api "repos/acme/evalrepo/pulls/7/comments" --jq '.[] | "\(.path):\(.line) \(.body)"')
    assert_contains "$out" "src/ledger.py:14 THREAD_ONE" "the first thread comes back" || rc=1
    assert_contains "$out" "src/ledger.py:16 THREAD_TWO" "and the second" || rc=1
    unset EVAL_GH_LOG EVAL_GH_ROUTES EVAL_REVIEWS_FILE EVAL_COMMENTS_FILE EVAL_JQ
    _re_teardown
    return $rc
}

test_review_eval_grades_a_review_posted_as_an_input_payload() {
    # review-pr posts through scripts/post-review, which sends one JSON body
    # with --input and deletes the file after. The recording gh keeps its
    # content, and the grader reads findings from it like any other post.
    _re_setup
    local rc=0 out
    export EVAL_GH_LOG="$RUN/gh.log" EVAL_GH_ROUTES="$RE_TMP/routes.tsv" \
        EVAL_REVIEWS_FILE="$RE_TMP/reviews.json" EVAL_COMMENTS_FILE="$RE_TMP/comments.json"
    echo '[]' > "$EVAL_REVIEWS_FILE"; echo '[]' > "$EVAL_COMMENTS_FILE"
    printf 'api repos/.*/reviews.*(-X|--method) POST\t0\t-\n' > "$EVAL_GH_ROUTES"
    /usr/bin/python3 -c '
import json, sys
json.dump({"event": "COMMENT", "body": "<!-- review-pr repo=acme/evalrepo pr=7 round=1 head=abc verdict=changes-needed gate=passed -->",
           "comments": [{"path": "src/ledger.py", "line": 14, "side": "RIGHT",
                         "body": "`>=` refuses a charge exactly at the cap.\n<!-- finding:f1 severity:major round:1 -->"}]},
          open(sys.argv[1], "w"))
' "$RE_TMP/payload.json"
    "$RE_GH" api "repos/acme/evalrepo/pulls/7/reviews" --method POST --input "$RE_TMP/payload.json" >/dev/null
    /bin/rm -f "$RE_TMP/payload.json"
    _re_result "$_RE_REVIEW_OK"
    out=$(_re_grade defect)
    assert_equal "catch" "$(printf '%s' "$out" | "$JQ_BIN" -r .outcome)" \
        "a finding sent in an --input payload is graded like any other" || rc=1
    assert_contains "$(/bin/cat "$EVAL_COMMENTS_FILE")" "src/ledger.py" "and served back as a thread" || rc=1
    unset EVAL_GH_LOG EVAL_GH_ROUTES EVAL_REVIEWS_FILE EVAL_COMMENTS_FILE
    _re_teardown
    return $rc
}
