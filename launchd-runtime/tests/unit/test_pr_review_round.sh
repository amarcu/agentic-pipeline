#!/bin/bash
# Tests for pr-review-round — the loop that drives a PR's Copilot review rounds.
#
# The failure this script exists to prevent is a silent green. A gh call that
# breaks, a PR with no review on it at all, a review whose findings live only in
# the summary body — each of those produces an empty list of inline comments,
# and an empty list reads exactly like "nothing left to answer". So the
# assertions below check the EXIT CODE on every not-green shape, not just the
# happy path: exit 0 from this script is what a caller will treat as approval.
#
# The second thing they pin is that `request` verifies. `-f reviewers[]=Copilot`
# returns success and creates nothing; only the bot login works. The mock gh
# therefore lets a test choose whether the POST changes anything, by supplying
# (or withholding) the `-after` fixtures it promotes.

# The head under test, and the commit an earlier round already reviewed. Both
# are real shapes from amarcu/agentic-pipeline#35, where head 44b68d8 carried only
# a quota notice and 363c892 carried the last actual verdict.
PRR_HEAD_SHA=44b68d8096389e45b079c1efece451b408df9771
PRR_OLD_SHA=363c89220695f0e2a1b3c4d5e6f7a8b9c0d1e2f3

_prr_setup() {
    PRR_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-prr.XXXXXX)
    export MOCK_GH_DIR="$PRR_TMP/gh"
    /bin/mkdir -p "$MOCK_GH_DIR/bin"

    # Defaults: no request pending, two past requests, no reviews, no comments.
    _prr_requests no
    _prr_timeline 2
    _prr_reviews
    _prr_comments
    _prr_head "$PRR_HEAD_SHA"

    # A gh that answers only the five call shapes pr-review-round makes and
    # exits 1 for everything else — an unexpected call must fail loudly rather
    # than return nothing, which is the very thing this script guards against.
    /bin/cat > "$MOCK_GH_DIR/bin/gh" <<'EOF'
#!/bin/bash
set -u
dir="${MOCK_GH_DIR:?}"
serve() { [[ -f "$1" ]] || exit 1; /bin/cat "$1"; exit 0; }
if [[ "${1:-}" == "api" ]]; then
    case "$*" in
        *requested_reviewers*)
            printf '%s\n' "$*" >> "$dir/posted.log"
            # A request that actually lands promotes the "-after" fixtures. A
            # test that omits them is testing the POST that does nothing.
            [[ -f "$dir/requests-after.json" ]] && /bin/mv "$dir/requests-after.json" "$dir/requests.json"
            [[ -f "$dir/timeline-after.json" ]] && /bin/mv "$dir/timeline-after.json" "$dir/timeline.json"
            echo '{}'
            exit "${MOCK_GH_POST_RC:-0}"
            ;;
        *graphql*)            serve "$dir/requests.json" ;;
        */issues/*/timeline*) serve "$dir/timeline.json" ;;
        */pulls/*/reviews*)   serve "$dir/reviews.json" ;;
        */pulls/*/comments*)  serve "$dir/comments.json" ;;
        */pulls/*)            serve "$dir/pr.json" ;;
    esac
fi
echo "mock gh: unhandled call: $*" >&2
exit 1
EOF
    /bin/chmod +x "$MOCK_GH_DIR/bin/gh"
    export PATH="$MOCK_GH_DIR/bin:$PATH"
}

_prr_teardown() {
    /bin/rm -rf "$PRR_TMP"
}

_prr_run() {
    "$RUNTIME_DIR/bin/pr-review-round" "$@" acme/testrepo 7
}

# The reviewRequests GraphQL page. Args: yes|no — is Copilot's request pending?
# The `[bot]`-suffixed User node is deliberate noise: only the Bot typename counts.
_prr_requests() {
    local file="${2:-$MOCK_GH_DIR/requests.json}" nodes
    if [[ "$1" == yes ]]; then
        nodes='[{"requestedReviewer": {"__typename": "Bot", "login": "copilot-pull-request-reviewer"}}]'
    else
        nodes='[{"requestedReviewer": {"__typename": "User", "login": "copilot-impersonator"}}]'
    fi
    /bin/cat > "$file" <<EOF
{"data": {"repository": {"pullRequest": {"reviewRequests": {"nodes": $nodes}}}}}
EOF
}

# N `review_requested` timeline events naming Copilot, plus one unrelated event.
_prr_timeline() {
    local count="$1" file="${2:-$MOCK_GH_DIR/timeline.json}"
    /usr/bin/python3 -c '
import json, sys
count = int(sys.argv[2])
events = [{"event": "commented"}]
events += [{"event": "review_requested",
            "requested_reviewer": {"login": "Copilot", "id": 175728472}}
           for _ in range(count)]
json.dump([events], open(sys.argv[1], "w"))
' "$file" "$count"
}

# The PR payload `request` reads the head SHA from. Args: sha.
_prr_head() {
    printf '{"number": 7, "head": {"sha": "%s"}}\n' "$1" > "$MOCK_GH_DIR/pr.json"
}

# The reviews page. Args: [submitted_at body commit_id …]; no args means the PR
# has never been reviewed by anyone.
_prr_reviews() {
    /usr/bin/python3 -c '
import json, sys
path = sys.argv[1]
out = []
for i in range(2, len(sys.argv), 3):
    out.append({"id": 900 + i, "state": "COMMENTED",
                "user": {"login": "Copilot", "id": 175728472},
                "submitted_at": sys.argv[i], "body": sys.argv[i + 1],
                "commit_id": sys.argv[i + 2],
                "html_url": "https://github.com/acme/testrepo/pull/7#r%d" % (900 + i)})
json.dump([out], open(path, "w"))
' "$MOCK_GH_DIR/reviews.json" "$@"
}

# The review comments page. Args: triples of id, in_reply_to_id ("-" for a
# root) and body. No args means the review left no inline comment at all.
_prr_comments() {
    /usr/bin/python3 -c '
import json, sys
path = sys.argv[1]
out = []
for i in range(2, len(sys.argv), 3):
    ident, parent, body = sys.argv[i], sys.argv[i + 1], sys.argv[i + 2]
    out.append({"id": int(ident),
                "in_reply_to_id": None if parent == "-" else int(parent),
                "path": "src/loader.ts", "line": 88, "original_line": 88,
                "user": {"login": "Copilot"}, "body": body,
                "html_url": "https://github.com/acme/testrepo/pull/7#d%s" % ident})
json.dump([out], open(path, "w"))
' "$MOCK_GH_DIR/comments.json" "$@"
}

GREEN_BODY='### 🟢 Approval recommended

Everything reads clean.'

CHANGES_BODY='### 🟡 Changes recommended

- The manifest is parsed on every frame.'

# Verbatim, from the review Copilot posted on amarcu/agentic-pipeline#35 on
# 2026-09-08 after four rounds in one day. No verdict line, no findings, and
# nothing about it says "the round did not happen" to a parser looking for 🟢.
QUOTA_BODY='Copilot was unable to review this pull request because the user who requested the review has reached their quota limit.'

test_pr_review_round_requests_a_review_when_none_is_pending() {
    _prr_setup
    # The POST lands: the timeline moves 2 → 3, which is the only proof there is.
    _prr_timeline 3 "$MOCK_GH_DIR/timeline-after.json"

    local out rc=0
    out=$(_prr_run request 2>&1)
    assert_exit 0 $? "a request that lands exits 0" || rc=1
    assert_contains "$out" "ROUND: acme/testrepo#7 requested" "prints the requested line" || rc=1
    assert_contains "$(/bin/cat "$MOCK_GH_DIR/posted.log")" \
        "reviewers[]=copilot-pull-request-reviewer[bot]" \
        "posts the bot login, not the plain Copilot form that silently does nothing" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_does_not_re_request_while_one_is_pending() {
    _prr_setup
    _prr_requests yes

    local out rc=0
    out=$(_prr_run request 2>&1)
    assert_exit 0 $? "an already-pending request is not a failure" || rc=1
    assert_contains "$out" "ROUND: acme/testrepo#7 already-pending" "says so" || rc=1
    if [[ -f "$MOCK_GH_DIR/posted.log" ]]; then
        echo "  FAIL: posted a second request while one was pending — GitHub may ignore it"
        rc=1
    fi

    _prr_teardown
    return $rc
}

test_pr_review_round_exits_3_when_the_request_silently_fails() {
    _prr_setup
    # No `-after` fixtures: the POST returns success and changes nothing, which
    # is exactly what `-f reviewers[]=Copilot` does on the real API.

    local out rc=0
    out=$(_prr_run request 2>&1)
    assert_exit 3 $? "a request that created nothing exits 3" || rc=1
    assert_contains "$out" "no review request was created" "names the failure" || rc=1
    assert_contains "$out" "the review_requested count did not move" \
        "and says how it knows — the HTTP status said success" || rc=1
    assert_not_contains "$out" "ROUND: acme/testrepo#7 requested" \
        "never claims a request it could not verify" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_wait_returns_the_verdict_of_a_new_review() {
    _prr_setup
    _prr_reviews "2026-09-08T13:00:00Z" "$GREEN_BODY" "$PRR_HEAD_SHA"

    local out rc=0
    out=$(_prr_run wait --since 2026-09-08T12:00:00Z --timeout-mins 0 2>&1)
    assert_exit 0 $? "a review after --since exits 0" || rc=1
    assert_equal "ROUND: acme/testrepo#7 review 2026-09-08T13:00:00Z green" "$out" \
        "one line: the stamp and the verdict" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_wait_exits_4_on_timeout_and_says_it_is_not_green() {
    _prr_setup
    # A review exists, but it predates the round we are waiting on — the shape
    # that would otherwise let a stale approval answer for a new push.
    _prr_reviews "2026-09-08T09:00:00Z" "$GREEN_BODY" "$PRR_OLD_SHA"

    local out rc=0
    out=$(_prr_run wait --since 2026-09-08T12:00:00Z --timeout-mins 0 --poll-secs 1 2>&1)
    assert_exit 4 $? "a timeout exits 4" || rc=1
    assert_contains "$out" "timeout after 0m" "prints the timeout line" || rc=1
    assert_contains "$out" "A timeout is NOT a green light" \
        "and says plainly that nothing was approved" || rc=1
    assert_not_contains "$out" "review 2026-09-08T09:00:00Z" \
        "the older review is not reported as this round's" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_status_is_green_only_with_nothing_unanswered() {
    _prr_setup
    _prr_reviews "2026-09-08T13:00:00Z" "$GREEN_BODY" "$PRR_HEAD_SHA"
    _prr_comments 501 - "Guard the parse" 502 501 "Fixed in abc1234"

    local out rc=0
    out=$(_prr_run status 2>&1)
    assert_exit 0 $? "green with every finding answered exits 0" || rc=1
    assert_equal "ROUND: acme/testrepo#7 status green unanswered=0" "$out" \
        "the whole output is the status line" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_status_is_not_green_with_an_unanswered_comment() {
    _prr_setup
    _prr_reviews "2026-09-08T13:00:00Z" "$GREEN_BODY" "$PRR_HEAD_SHA"
    _prr_comments 501 - "Guard the parse" 502 501 "Fixed in abc1234" \
                  503 - "This cast can throw"

    local out rc=0
    out=$(_prr_run status 2>&1)
    assert_exit 1 $? "an approved review with an unanswered finding is NOT green" || rc=1
    assert_contains "$out" "status green unanswered=1" "reports the verdict and the count" || rc=1
    assert_contains "$out" "503 src/loader.ts:88 This cast can throw" \
        "names the unanswered finding, id first" || rc=1
    assert_not_contains "$out" "501 src/loader.ts" "an answered root is not listed" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_status_reports_a_changes_verdict() {
    _prr_setup
    _prr_reviews "2026-09-08T13:00:00Z" "$CHANGES_BODY" "$PRR_HEAD_SHA"
    _prr_comments 501 - "Guard the parse" 502 501 "Fixed in abc1234"

    local out rc=0
    out=$(_prr_run status 2>&1)
    assert_exit 1 $? "changes recommended is not green, answered findings or not" || rc=1
    assert_contains "$out" "status changes unanswered=0" "verdict, not comment count" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_status_is_not_green_when_findings_are_body_only() {
    _prr_setup
    # The dangerous shape: real findings, and not one inline comment carrying
    # them. Counting unanswered comments alone would call this settled.
    _prr_reviews "2026-09-08T13:00:00Z" "$CHANGES_BODY" "$PRR_HEAD_SHA"
    _prr_comments

    local out rc=0
    out=$(_prr_run status 2>&1)
    assert_exit 1 $? "findings that live only in the summary body are still findings" || rc=1
    assert_contains "$out" "status changes unanswered=0" \
        "zero unanswered comments, and still not green" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_status_never_calls_an_unreviewed_pr_green() {
    _prr_setup

    local out rc=0
    out=$(_prr_run status 2>&1)
    assert_exit 1 $? "a PR with no Copilot review exits 1" || rc=1
    assert_contains "$out" "status no-review unanswered=0" "the verdict is no-review" || rc=1
    assert_contains "$out" "not an approval, it is the absence of one" \
        "and says why that is not the same thing" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_status_json_carries_the_same_verdict() {
    _prr_setup
    _prr_reviews "2026-09-08T13:00:00Z" "$GREEN_BODY" "$PRR_HEAD_SHA"
    _prr_comments 503 - "This cast can throw"

    local out rc=0
    out=$(_prr_run status --json 2>/dev/null)
    assert_exit 1 $? "--json changes the format, not the verdict" || rc=1
    assert_equal "false" "$(printf '%s' "$out" | "$JQ_BIN" -r '.green')" \
        "green is false" || rc=1
    assert_equal "1" "$(printf '%s' "$out" | "$JQ_BIN" -r '.unanswered_count')" \
        "one finding unanswered" || rc=1
    assert_equal "503" "$(printf '%s' "$out" | "$JQ_BIN" -r '.unanswered[0].id')" \
        "and it is named" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_fails_loudly_when_gh_does() {
    _prr_setup
    _prr_reviews "2026-09-08T13:00:00Z" "$GREEN_BODY" "$PRR_HEAD_SHA"
    # The comments page is gone: the mock exits 1, as gh would on a bad token.
    /bin/mv "$MOCK_GH_DIR/comments.json" "$PRR_TMP/comments.parked"

    local out rc=0
    out=$(_prr_run status 2>&1)
    assert_exit 2 $? "a failed gh call is exit 2, never a green status" || rc=1
    assert_contains "$out" "pr-review-round: gh api" "the failing call is named" || rc=1
    assert_not_contains "$out" "unanswered=0" \
        "an unreadable comments page must never print as nothing-to-answer" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_status_reports_an_exhausted_quota_as_its_own_outcome() {
    _prr_setup
    # The trap: a body with no verdict line and no findings. Read as a verdict
    # it is silence; read as a comment count it is zero unanswered. Neither is
    # true — the round never happened.
    _prr_reviews "2026-09-08T12:57:21Z" "$QUOTA_BODY" "$PRR_HEAD_SHA"

    local out rc=0
    out=$(_prr_run status 2>&1)
    assert_exit 5 $? "an exhausted quota is exit 5, not 0 and not a plain 1" || rc=1
    assert_contains "$out" "status quota-exhausted unanswered=0" \
        "the verdict names the outcome" || rc=1
    assert_contains "$out" "the round did not happen" "and says what it means" || rc=1
    assert_not_contains "$out" "status green" "never a verdict" || rc=1
    assert_not_contains "$out" "status unknown" \
        "and not folded into the catch-all either — a caller must not retry this" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_wait_stops_on_an_exhausted_quota() {
    _prr_setup
    _prr_reviews "2026-09-08T12:57:21Z" "$QUOTA_BODY" "$PRR_HEAD_SHA"

    local out rc=0
    out=$(_prr_run wait --since 2026-09-08T12:00:00Z --timeout-mins 0 2>&1)
    assert_exit 5 $? "a quota notice arriving as this round's review exits 5" || rc=1
    assert_contains "$out" "ROUND: acme/testrepo#7 quota-exhausted" "prints its own line" || rc=1
    assert_not_contains "$out" "review 2026-09-08T12:57:21Z" \
        "never reported as a review with a verdict" || rc=1
    assert_contains "$out" "wait for quota" \
        "and hands the decision to a human" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_refuses_to_re_request_on_an_already_reviewed_sha() {
    _prr_setup
    # The head has already been reviewed. GitHub bills every review to the
    # requester and de-duplicates nothing, so asking again buys a second copy of
    # a verdict that is already on the PR — #35 has two against 01ba178b.
    _prr_reviews "2026-09-08T13:00:00Z" "$CHANGES_BODY" "$PRR_HEAD_SHA"
    _prr_timeline 3 "$MOCK_GH_DIR/timeline-after.json"

    local out rc=0
    out=$(_prr_run request 2>&1)
    assert_exit 6 $? "a re-request on a reviewed head SHA exits 6" || rc=1
    assert_contains "$out" "ROUND: acme/testrepo#7 already-reviewed-at 44b68d8" \
        "names the SHA, short form" || rc=1
    assert_contains "$out" "GitHub bills every review" "and says why it refused" || rc=1
    if [[ -f "$MOCK_GH_DIR/posted.log" ]]; then
        echo "  FAIL: posted a request anyway — that is the charge this guard exists to avoid"
        rc=1
    fi

    _prr_teardown
    return $rc
}

test_pr_review_round_requests_when_the_head_sha_is_new() {
    _prr_setup
    # A verdict exists, but against the commit before this push. There is
    # something new to review, so the charge buys something.
    _prr_reviews "2026-09-08T13:00:00Z" "$CHANGES_BODY" "$PRR_OLD_SHA"
    _prr_timeline 3 "$MOCK_GH_DIR/timeline-after.json"

    local out rc=0
    out=$(_prr_run request 2>&1)
    assert_exit 0 $? "a new head SHA is requestable" || rc=1
    assert_contains "$out" "ROUND: acme/testrepo#7 requested" "and is requested" || rc=1
    assert_not_contains "$out" "already-reviewed-at" "the guard does not fire" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_force_overrides_the_already_reviewed_guard() {
    _prr_setup
    _prr_reviews "2026-09-08T13:00:00Z" "$CHANGES_BODY" "$PRR_HEAD_SHA"
    _prr_timeline 3 "$MOCK_GH_DIR/timeline-after.json"

    local out rc=0
    out=$(_prr_run request --force 2>&1)
    assert_exit 0 $? "--force buys the second review deliberately" || rc=1
    assert_contains "$out" "ROUND: acme/testrepo#7 requested" "and says so" || rc=1
    assert_contains "$(/bin/cat "$MOCK_GH_DIR/posted.log")" "requested_reviewers" \
        "the POST really happened" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_a_quota_notice_does_not_count_as_having_reviewed_the_head() {
    _prr_setup
    # Exactly amarcu/agentic-pipeline#35: the last verdict is against an older
    # commit, and the only review at head is the quota notice. The head has not
    # been reviewed, so the guard must not refuse the request that would.
    _prr_reviews "2026-09-08T12:56:25Z" "$CHANGES_BODY" "$PRR_OLD_SHA" \
                 "2026-09-08T12:57:21Z" "$QUOTA_BODY"    "$PRR_HEAD_SHA"
    _prr_timeline 3 "$MOCK_GH_DIR/timeline-after.json"

    local out rc=0
    out=$(_prr_run request 2>&1)
    assert_exit 0 $? "a quota notice at head is not a review of it" || rc=1
    assert_contains "$out" "ROUND: acme/testrepo#7 requested" "so the request proceeds" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_wait_ignores_a_late_review_of_an_older_commit() {
    _prr_setup
    # The f1 shape. A review of the PREVIOUS head, submitted after the wait
    # began — Copilot does answer two requests against one commit minutes apart
    # (#35, 01ba178b) — must not satisfy a round opened for the new push. If it
    # did, `status` would go on to report a verdict on code nobody reviewed.
    _prr_reviews "2026-09-08T13:00:00Z" "$GREEN_BODY" "$PRR_OLD_SHA"

    local out rc=0
    out=$(_prr_run wait --since 2026-09-08T12:00:00Z --timeout-mins 0 2>&1)
    assert_exit 4 $? "a review of another commit leaves the round unanswered" || rc=1
    assert_contains "$out" "no Copilot review of 44b68d8" "the timeout names the head" || rc=1
    assert_contains "$out" "A review of some other commit does not count" \
        "and says why the one on the PR did not end the wait" || rc=1
    assert_not_contains "$out" "review 2026-09-08T13:00:00Z" \
        "the older commit's verdict is never reported as this round's" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_wait_prefers_the_head_review_over_a_newer_stale_one() {
    _prr_setup
    # The head's verdict first, a stale review of the old commit after it. Taking
    # "the newest review, if it is of the head" would find the stale one and wait
    # forever for a verdict that is already in.
    _prr_reviews "2026-09-08T13:00:00Z" "$CHANGES_BODY" "$PRR_HEAD_SHA" \
                 "2026-09-08T13:05:00Z" "$GREEN_BODY"   "$PRR_OLD_SHA"

    local out rc=0
    out=$(_prr_run wait --since 2026-09-08T12:00:00Z --timeout-mins 0 2>&1)
    assert_exit 0 $? "the head's review ends the wait" || rc=1
    assert_equal "ROUND: acme/testrepo#7 review 2026-09-08T13:00:00Z changes" "$out" \
        "and it is the head's verdict that is reported, not the newer stale one" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_wait_needs_no_timestamp_from_its_caller() {
    _prr_setup
    # The f2 shape. `iterate-on-pr` grants no `date`, so the loop cannot compute
    # a `--since`; it runs `request` then `wait`, and `wait` defaults the bound
    # to the moment it starts. A review that predates the wait is therefore not
    # this round's, and the round times out rather than adopting it.
    _prr_reviews "2026-09-08T13:00:00Z" "$GREEN_BODY" "$PRR_HEAD_SHA"

    local out rc=0
    out=$(_prr_run wait --timeout-mins 0 2>&1)
    assert_exit 4 $? "with no --since, a review from before the wait is not this round's" || rc=1
    assert_contains "$out" "no Copilot review of 44b68d8 since" "the bound it used is printed" || rc=1

    # The same fixture, with the bound named explicitly, is accepted — so the
    # default is a default and not a second rule.
    out=$(_prr_run wait --since 2026-09-08T12:00:00Z --timeout-mins 0 2>&1)
    assert_exit 0 $? "an explicit --since still works" || rc=1
    assert_contains "$out" "review 2026-09-08T13:00:00Z green" "and returns the verdict" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_status_never_goes_green_on_a_review_of_another_commit() {
    _prr_setup
    # A 🟢 against the commit before this push, and nothing unanswered. `status`
    # exit 0 is the loop's "stop, we are green" signal, so returning 0 here would
    # stop the loop on a verdict about code nobody has reviewed — the silent
    # green this script exists to refuse. The exit code is the assertion that
    # matters; an earlier version of this test checked only the wording.
    _prr_reviews "2026-09-08T13:00:00Z" "$GREEN_BODY" "$PRR_OLD_SHA"

    local out rc=0
    out=$(_prr_run status 2>&1)
    assert_exit 1 $? "a green review of another commit is not this commit's green" || rc=1
    assert_contains "$out" "status no-review unanswered=0" "the head has no verdict" || rc=1
    assert_contains "$out" "no Copilot review of 44b68d8, the head" "and the note says so" || rc=1
    assert_contains "$out" "newest verdict is against 363c892" \
        "naming what there is instead, so the reader is not left guessing" || rc=1
    assert_not_contains "$out" "status green" "never green" || rc=1

    assert_equal "44b68d8096389e45b079c1efece451b408df9771" \
        "$(_prr_run status --json 2>/dev/null | "$JQ_BIN" -r '.head')" \
        "--json names the head it compared against" || rc=1
    assert_equal "null" "$(_prr_run status --json 2>/dev/null | "$JQ_BIN" -r '.review')" \
        "and carries no review for it" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_status_and_wait_answer_the_same_question() {
    _prr_setup
    # The fixture that split them: the head's verdict, then a late review of the
    # previous commit. `wait` read the head's; `status` read the newest and would
    # have gone green on it. Both now ask one function, so they cannot disagree.
    _prr_reviews "2026-09-08T13:00:00Z" "$CHANGES_BODY" "$PRR_HEAD_SHA" \
                 "2026-09-08T13:05:00Z" "$GREEN_BODY"   "$PRR_OLD_SHA"

    local out rc=0
    out=$(_prr_run wait --since 2026-09-08T12:00:00Z --timeout-mins 0 2>&1)
    assert_exit 0 $? "wait ends on the head's review" || rc=1
    assert_contains "$out" "review 2026-09-08T13:00:00Z changes" "reporting its verdict" || rc=1

    out=$(_prr_run status 2>&1)
    assert_exit 1 $? "and status does not go green on the stale one behind it" || rc=1
    assert_contains "$out" "status changes unanswered=0" \
        "it reports the same verdict wait did, from the same commit" || rc=1

    _prr_teardown
    return $rc
}

test_pr_review_round_refuses_a_re_request_behind_a_late_review_of_an_older_commit() {
    _prr_setup
    # The head already has a verdict, and a late review of the previous commit
    # landed after it. Asking "what was reviewed most recently" answers the old
    # commit, the guard misses, and GitHub bills a second review of a commit that
    # already has one — the exact spend the guard exists to prevent.
    _prr_reviews "2026-09-08T13:00:00Z" "$CHANGES_BODY" "$PRR_HEAD_SHA" \
                 "2026-09-08T13:05:00Z" "$GREEN_BODY"   "$PRR_OLD_SHA"
    _prr_timeline 3 "$MOCK_GH_DIR/timeline-after.json"

    local out rc=0
    out=$(_prr_run request 2>&1)
    assert_exit 6 $? "the head is reviewed, whatever arrived after it" || rc=1
    assert_contains "$out" "already-reviewed-at 44b68d8" "and the guard names the head" || rc=1
    if [[ -f "$MOCK_GH_DIR/posted.log" ]]; then
        echo "  FAIL: posted a billed re-request for a commit that already has a verdict"
        rc=1
    fi

    _prr_teardown
    return $rc
}

test_pr_review_round_loop_needs_no_tool_the_skill_does_not_grant() {
    # f2's root cause, kept from coming back. A deny-closed headless run can
    # execute only what `allowed-tools` names, so a command the round loop
    # documents but the skill does not grant is a step the loop can never take —
    # and nothing fails loudly when it cannot, the round just never happens.
    local skill="$REPO_ROOT/skills/iterate-on-pr/SKILL.md"
    local ref="$REPO_ROOT/skills/iterate-on-pr/references/summary-comment.md"
    local tools cmd rc=0
    tools=$(/usr/bin/grep -m1 '^allowed-tools:' "$skill")

    while IFS= read -r cmd; do
        [[ -n "$cmd" ]] || continue
        if [[ "$tools" != *"$cmd"* ]]; then
            echo "  FAIL: summary-comment.md tells the worker to run '$cmd',"
            echo "        which iterate-on-pr's allowed-tools does not grant"
            rc=1
        fi
    done <<< "$(/usr/bin/sed -n '/^```bash$/,/^```$/p' "$ref" \
                | /usr/bin/grep -vE '^```|^\s*#|^\s*$' \
                | /usr/bin/awk '{print $1}' | /usr/bin/sort -u)"

    # And the loop asks for no timestamp at all: `wait` bounds itself.
    if /usr/bin/sed -n '/^```bash$/,/^```$/p' "$ref" | /usr/bin/grep -q -- '--since'; then
        echo "  FAIL: the round loop still passes --since, which needs a clock the skill cannot run"
        rc=1
    fi
    return $rc
}
