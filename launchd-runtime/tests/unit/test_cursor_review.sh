#!/bin/bash
# Tests for cursor-review — the non-Claude review lane.
#
# No network and no Cursor API: a mock cursor-agent on PATH serves a canned
# envelope, and the mock gh from test_pr_review_bundle.sh serves the bundle and
# the reviews endpoint. What these pin is the part that cannot be checked by
# reading the script — that a Claude model id never reaches cursor-agent or the
# bundler, that the API key travels in the environment and not in argv, that an
# answer the parser cannot read fails loudly instead of becoming a verdict, and
# that the findings still reach the pull request when GitHub refuses the inline
# anchors.
#
# The exports below need no restore: run_test invokes every test in its own
# subshell, which test_mock_gh_path_cannot_leak_between_tests pins.

# A well-formed answer narrates first and answers second, which is what the
# real CLI returned on 2026-09-08. Every fixture keeps the narration, because
# finding the object inside it is the parser's whole job.
_cr_envelope() {
    /usr/bin/python3 - "$MOCK_CURSOR_DIR/stdout.json" "$1" <<'PY'
import json, sys
path, verdict_json = sys.argv[1:3]
result = ("I'll read the diff and the criteria first.\n\n"
          "The change is small but one criterion is unproven.\n\n" + verdict_json)
json.dump({
    "type": "result", "subtype": "success", "is_error": False,
    "duration_ms": 41000, "duration_api_ms": 40000,
    "result": result,
    "session_id": "sess-fixture", "request_id": "req-abc123",
    "usage": {"inputTokens": 1234, "outputTokens": 56,
              "cacheReadTokens": 78, "cacheWriteTokens": 90},
}, open(path, "w"))
PY
}

_cr_prose_only() {
    /usr/bin/python3 - "$MOCK_CURSOR_DIR/stdout.json" <<'PY'
import json, sys
json.dump({
    "type": "result", "subtype": "success", "is_error": False,
    "duration_ms": 900, "duration_api_ms": 800,
    "result": "Looks good to me, the change should pass without issues.",
    "session_id": "sess-fixture", "request_id": "req-prose",
    "usage": {"inputTokens": 10, "outputTokens": 2,
              "cacheReadTokens": 0, "cacheWriteTokens": 0},
}, open(sys.argv[1], "w"))
PY
}

_cr_setup() {
    CR_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-cr.XXXXXX)
    export MOCK_GH_DIR="$CR_TMP/gh"
    export MOCK_CURSOR_DIR="$CR_TMP/cursor"
    export PATH="$FIXTURES_DIR/mock-cursor-agent:$FIXTURES_DIR/mock-gh:$PATH"
    export REPOS_CONF="$CR_TMP/repos.conf"
    export METRICS_DIR="$CR_TMP/metrics"
    export CURSOR_REVIEW_BUNDLE_DIR="$CR_TMP/bundle"
    export CURSOR_API_KEY_FILE="$CR_TMP/api-key"
    /bin/mkdir -p "$MOCK_GH_DIR" "$MOCK_CURSOR_DIR" "$METRICS_DIR"

    # A real key or model in the runner's environment must not reach a test.
    unset CURSOR_API_KEY
    unset CURSOR_REVIEW_MODEL
    CR_KEY="key_TESTSECRET_do_not_log"
    printf '%s\n' "$CR_KEY" > "$CURSOR_API_KEY_FILE"
    /bin/chmod 600 "$CURSOR_API_KEY_FILE"

    CR_REPO="$CR_TMP/checkout"
    /bin/mkdir -p "$CR_REPO/game"
    printf 'class Player {}\n' > "$CR_REPO/game/Player.cs"
    /usr/bin/git -C "$CR_REPO" init -q -b main
    /usr/bin/git -C "$CR_REPO" config user.email "test@example.com"
    /usr/bin/git -C "$CR_REPO" config user.name "test"
    /usr/bin/git -C "$CR_REPO" add game/Player.cs
    /usr/bin/git -C "$CR_REPO" -c commit.gpgsign=false commit -qm "fixture head"
    CR_SHA=$(/usr/bin/git -C "$CR_REPO" rev-parse HEAD)

    /bin/cat > "$REPOS_CONF" <<EOF
get_repo_path() {
    case "\$1" in
        acme/testrepo) echo "$CR_REPO" ;;
        *)               echo "" ;;
    esac
}
EOF

    /bin/cat > "$MOCK_GH_DIR/pr-view.json" <<EOF
{"number": 7, "state": "OPEN", "isDraft": true, "headRefName": "task/issue-12",
 "headRefOid": "$CR_SHA", "baseRefName": "main", "changedFiles": 1,
 "closingIssuesReferences": [{"number": 12}]}
EOF
    /bin/cat > "$MOCK_GH_DIR/diff.patch" <<'EOF'
diff --git a/game/Player.cs b/game/Player.cs
--- a/game/Player.cs
+++ b/game/Player.cs
@@ -1 +1,2 @@
 class Player {}
+// changed
EOF
    echo '[{"filename": "game/Player.cs", "status": "modified"}]' > "$MOCK_GH_DIR/files.json"
    printf '%s\n' game/Player.cs > "$MOCK_GH_DIR/tree-paths.txt"
    # A pull request nobody has reviewed yet answers with an empty array and
    # exit 0, which is what the real endpoint does. The mock exits non-zero when
    # this file is absent, and that is how a test says "the call did not
    # happen" — the two must not look alike to the caller, because one of them
    # means "safe to pay for a review" and the other means "no idea".
    echo '[]' > "$MOCK_GH_DIR/reviews.json"
    /usr/bin/python3 -c '
import json, sys
json.dump({"title": "Parse the manifest once",
           "body": "## Acceptance criteria\n- [ ] The manifest is parsed once at startup\n"},
          open(sys.argv[1], "w"))
' "$MOCK_GH_DIR/issue-12.json"

    _cr_envelope '{"repo": "wrong/repo", "pr": 999, "head_sha": "deadbeef", "round": 9,
 "model": "whatever-the-reviewer-thinks",
 "gate": {"outcome": "could-not-run", "command": null, "exit": null},
 "findings": [{"id": "f1", "severity": "blocker", "path": "game/Player.cs", "line": 2,
               "state": "new", "claim": "checklist 1: the criterion is unproven",
               "evidence": "no test touches the manifest path",
               "what-settles-it": "a test that parses a malformed manifest"}],
 "open": {"blocker": 1, "major": 0, "minor": 0},
 "verdict": "changes-needed", "reason": "one criterion is unproven"}'
}

_cr_teardown() {
    /bin/rm -rf "$CR_TMP"
}

# stdout is the caller's to capture; stderr always lands in a file, so a test
# can assert on both without the two being interleaved.
_cr_run() {
    "$RUNTIME_DIR/bin/cursor-review" acme/testrepo 7 "$@" 2>"$CR_TMP/stderr.txt"
}

_cr_err() {
    /bin/cat "$CR_TMP/stderr.txt" 2>/dev/null || true
}

test_cursor_review_records_a_parsed_verdict() {
    _cr_setup
    local rc=0 out

    out=$(_cr_run)
    assert_exit 0 $? "a well-formed answer exits 0" || rc=1

    assert_contains "$out" "CURSOR REVIEW: run=interactive repo=acme/testrepo pr=7 round=1" \
        "the line names the run, the repo and the round" || rc=1
    assert_contains "$out" "head=${CR_SHA:0:7} model=cursor-grok-4.6-high" \
        "and the head SHA and the model that actually ran" || rc=1
    assert_contains "$out" "verdict=changes-needed findings=1/0/0" \
        "and the verdict with its blocker/major/minor counts" || rc=1
    assert_contains "$out" "cost=unknown tokens=1234/56/78/90 req=req-abc123" \
        "cost is unknown by design; the token counts and request id stand in for it" || rc=1

    local verdict="$CURSOR_REVIEW_BUNDLE_DIR/verdict.json"
    assert_file_exists "$verdict" "the verdict lands in the bundle" || rc=1
    assert_equal "changes-needed" "$("$JQ_BIN" -r '.verdict' "$verdict")" "verdict recorded" || rc=1

    # The fixture reviewer reports a different repo, PR, SHA, round and model
    # than the ones under review. It is trusted for its judgement, not for its
    # bookkeeping.
    assert_equal "cursor-grok-4.6-high" "$("$JQ_BIN" -r '.model' "$verdict")" \
        "the model id is this run's, not the one the reviewer claimed" || rc=1
    assert_equal "acme/testrepo" "$("$JQ_BIN" -r '.repo' "$verdict")" "so is the repo" || rc=1
    assert_equal "7" "$("$JQ_BIN" -r '.pr' "$verdict")" "and the PR number" || rc=1
    assert_equal "$CR_SHA" "$("$JQ_BIN" -r '.head_sha' "$verdict")" "and the head SHA" || rc=1
    assert_equal "1" "$("$JQ_BIN" -r '.round' "$verdict")" "and the round" || rc=1

    assert_equal "1234" "$("$JQ_BIN" -r '.cursor.usage.inputTokens' "$verdict")" \
        "the envelope's token counts are kept" || rc=1
    assert_equal "req-abc123" "$("$JQ_BIN" -r '.cursor.request_id' "$verdict")" \
        "so is the request id, the only handle on what this cost" || rc=1
    assert_equal "null" "$("$JQ_BIN" -r '.cursor.cost_usd' "$verdict")" \
        "and cost stays null rather than being guessed from tokens" || rc=1
    assert_file_exists "$METRICS_DIR/review-acme-testrepo-7-cursor-r1.json" \
        "a copy lands where the metrics readers look" || rc=1

    # The key reaches the child through its environment and nowhere else.
    assert_equal "key=set" "$(/bin/cat "$MOCK_CURSOR_DIR/env.txt")" \
        "cursor-agent got the key from its environment" || rc=1
    assert_not_contains "$(/bin/cat "$MOCK_CURSOR_DIR/argv.txt")" "$CR_KEY" \
        "the key is never an argument" || rc=1
    assert_not_contains "$out$(_cr_err)" "$CR_KEY" "and never printed" || rc=1

    # A second run is the next round, not a repeat of the first.
    out=$(_cr_run)
    assert_contains "$out" "round=2" "a second run is round 2" || rc=1
    assert_file_exists "$METRICS_DIR/review-acme-testrepo-7-cursor-r2.json" \
        "and records its own verdict file" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_invocation_is_read_only() {
    _cr_setup
    local rc=0
    _cr_run > /dev/null

    local argv
    argv=$(/bin/cat "$MOCK_CURSOR_DIR/argv.txt")
    assert_contains "$argv" "--mode" "the mode is passed" || rc=1
    assert_contains "$argv" "ask" "and it is ask — the reviewer never edits" || rc=1
    # --trust is required: cursor-agent refuses to work in a directory it has
    # not seen before, and every bundle directory is new. Trust grants the
    # workspace, not the right to change it.
    assert_contains "$argv" "--trust" "the fresh bundle directory is trusted" || rc=1
    assert_not_contains "$argv" "--force" "but never --force" || rc=1
    assert_not_contains "$argv" "--yolo" "and never --yolo" || rc=1
    assert_contains "$argv" "--workspace" "the workspace is passed" || rc=1
    assert_contains "$argv" "$CURSOR_REVIEW_BUNDLE_DIR" "and it is this run's bundle" || rc=1
    assert_contains "$argv" "cursor-grok-4.6-high" "with the resolved model" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_fails_loudly_on_an_unreadable_answer() {
    _cr_setup
    _cr_prose_only

    local rc=0 out
    out=$(_cr_run)
    assert_exit 8 $? "an answer with no verdict object exits 8" || rc=1

    local err
    err=$(_cr_err)
    assert_contains "$err" "no verdict JSON in the reviewer's answer" "the reason is named" || rc=1
    assert_contains "$err" "Looks good to me" "and the raw answer is quoted back" || rc=1
    assert_contains "$out" "verdict=error findings=0/0/0" \
        "the line says error — prose containing the word pass is not a pass" || rc=1
    assert_equal "error" \
        "$("$JQ_BIN" -r '.verdict' "$CURSOR_REVIEW_BUNDLE_DIR/verdict.json")" \
        "and the recorded verdict says so too" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_refuses_an_anthropic_model() {
    _cr_setup
    local rc=0 model err

    for model in claude-fable-5-thinking-high claude-opus-5-high claude-sonnet-5 gpt-with-haiku; do
        _cr_run --model "$model" > /dev/null
        assert_exit 6 $? "$model is refused" || rc=1
        err=$(_cr_err)
        assert_contains "$err" "it names an Anthropic model" "$model: the refusal says why" || rc=1
    done

    CURSOR_REVIEW_MODEL=claude-opus-5-thinking _cr_run > /dev/null
    assert_exit 6 $? "the environment default is checked too" || rc=1

    if [[ -f "$MOCK_CURSOR_DIR/argv.txt" ]]; then
        echo "  FAIL: cursor-agent was invoked with a refused model"
        rc=1
    fi
    # The bundler is never reached either, which is what couples the model
    # check to --allow-pipeline: a Claude model cannot be handed a pipeline PR
    # because it never gets as far as the bundle.
    if [[ -e "$CURSOR_REVIEW_BUNDLE_DIR/diff.patch" ]]; then
        echo "  FAIL: the bundle was built before the model was checked"
        rc=1
    fi

    _cr_teardown
    return $rc
}

test_cursor_review_refuses_a_missing_key() {
    _cr_setup
    local rc=0 err
    export CURSOR_API_KEY_FILE="$CR_TMP/no-such-key"

    _cr_run > /dev/null
    assert_exit 5 $? "no key is a refusal" || rc=1
    err=$(_cr_err)
    assert_contains "$err" "no API key" "the refusal names the problem" || rc=1
    assert_contains "$err" "$CR_TMP/no-such-key" "and the path it looked in" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_refuses_a_world_readable_key_file() {
    _cr_setup
    local rc=0 err
    /bin/chmod 644 "$CURSOR_API_KEY_FILE"

    _cr_run > /dev/null
    assert_exit 5 $? "a key file anyone can read is a refusal" || rc=1
    err=$(_cr_err)
    assert_contains "$err" "mode 644" "the refusal quotes the mode" || rc=1
    assert_contains "$err" "chmod 600" "and says what to do about it" || rc=1

    /bin/chmod 640 "$CURSOR_API_KEY_FILE"
    _cr_run > /dev/null
    assert_exit 5 $? "group-readable is refused as well" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_dry_run_invokes_nothing() {
    _cr_setup
    local rc=0 out

    out=$(_cr_run --dry-run)
    assert_exit 0 $? "a dry run exits 0" || rc=1
    assert_contains "$out" "cursor-agent is not invoked" "and says so" || rc=1
    assert_contains "$out" "model:  cursor-grok-4.6-high" "it names the resolved model" || rc=1
    assert_contains "$out" "You are an independent code reviewer" \
        "and prints the head of the prompt it assembled" || rc=1

    if [[ -f "$MOCK_CURSOR_DIR/argv.txt" ]]; then
        echo "  FAIL: --dry-run invoked cursor-agent"
        rc=1
    fi
    if [[ -f "$CURSOR_REVIEW_BUNDLE_DIR/verdict.json" ]]; then
        echo "  FAIL: --dry-run wrote a verdict"
        rc=1
    fi
    if /bin/ls "$METRICS_DIR"/*.json > /dev/null 2>&1; then
        echo "  FAIL: --dry-run wrote a metrics file"
        rc=1
    fi
    assert_file_exists "$CURSOR_REVIEW_BUNDLE_DIR/src/game/Player.cs" \
        "a dry run keeps src/ so the bundle can be inspected" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_removes_the_source_tree_after_a_run() {
    _cr_setup
    local rc=0

    _cr_run > /dev/null
    assert_exit 0 $? "the run succeeds" || rc=1
    if [[ -e "$CURSOR_REVIEW_BUNDLE_DIR/src" ]]; then
        echo "  FAIL: src/ was left in the bundle after the run"
        rc=1
    fi
    assert_file_exists "$CURSOR_REVIEW_BUNDLE_DIR/verdict.json" \
        "the verdict stays, for --dry-run --post to render" || rc=1

    _cr_teardown
    return $rc
}

# ── The trail on the pull request ─────────────────────────────────────────

test_cursor_review_posts_one_comment_review_with_the_marker() {
    _cr_setup
    local rc=0 out

    out=$(_cr_run --post)
    assert_exit 0 $? "posting succeeds" || rc=1
    assert_contains "$out" "posted=inline" "the line records that it posted" || rc=1

    local posted="$MOCK_GH_DIR/review-post-1.json"
    assert_file_exists "$posted" "one review was posted" || rc=1
    assert_equal "COMMENT" "$("$JQ_BIN" -r '.event' "$posted")" \
        "as a COMMENT — GitHub rejects an approval on a PR this account authored," || rc=1

    local body
    body=$("$JQ_BIN" -r '.body' "$posted")
    assert_contains "$body" \
        "<!-- cursor-review repo=acme/testrepo pr=7 round=1 head=$CR_SHA model=cursor-grok-4.6-high verdict=changes-needed request_id=req-abc123 -->" \
        "the marker carries everything a reader needs to place this review" || rc=1
    assert_equal "<!-- cursor-review" \
        "$(printf '%s' "$body" | /usr/bin/head -1 | /usr/bin/cut -d' ' -f1-2)" \
        "and it is the first line of the body" || rc=1
    assert_contains "$body" "Independent review by Cursor" \
        "the heading names the reviewer in plain words" || rc=1
    assert_contains "$body" "cursor-grok-4.6-high" "including the model id" || rc=1
    assert_contains "$body" "not** a Claude review" "and that it is not a Claude review" || rc=1
    assert_contains "$body" "Verdict: changes-needed" "the verdict is stated in prose too" || rc=1
    assert_contains "$body" "script=cursor-review" "and the attribution marker closes it" || rc=1

    assert_equal "game/Player.cs" "$("$JQ_BIN" -r '.comments[0].path' "$posted")" \
        "the finding is anchored to its file" || rc=1
    assert_equal "2" "$("$JQ_BIN" -r '.comments[0].line' "$posted")" "and its line" || rc=1
    assert_equal "RIGHT" "$("$JQ_BIN" -r '.comments[0].side' "$posted")" "on the head side" || rc=1

    local inline
    inline=$("$JQ_BIN" -r '.comments[0].body' "$posted")
    assert_contains "$inline" "the criterion is unproven" "carrying the claim" || rc=1
    assert_contains "$inline" "no test touches the manifest path" "and its evidence" || rc=1
    # Byte-for-byte what iterate-on-pr/scripts/pr-feedback's FINDING_RE matches,
    # so the existing fixer consumes a Cursor finding with no change to it.
    assert_contains "$inline" "<!-- finding:f1 severity:blocker round:1 -->" \
        "and the tag the fixer already parses" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_keeps_the_findings_when_github_rejects_the_anchors() {
    _cr_setup
    /usr/bin/touch "$MOCK_GH_DIR/reviews-reject-inline"

    local rc=0 out
    out=$(_cr_run --post)
    assert_exit 0 $? "a 422 on the anchors is not a failure" || rc=1
    assert_contains "$out" "posted=body" "the line records the fallback" || rc=1
    assert_contains "$(_cr_err)" "422" "and stderr says why it fell back" || rc=1

    local second="$MOCK_GH_DIR/review-post-2.json"
    assert_file_exists "$second" "a second review went up" || rc=1
    assert_equal "null" "$("$JQ_BIN" -r '.comments' "$second")" \
        "with no inline comments this time" || rc=1

    local body
    body=$("$JQ_BIN" -r '.body' "$second")
    assert_contains "$body" "the criterion is unproven" \
        "the finding survives in the body rather than being dropped" || rc=1
    assert_contains "$body" "HTTP 422" "and the body says why it is not inline" || rc=1
    # No finding tag here, on purpose: pr-feedback classifies a review body
    # carrying one as `reviewer` and skips it as context for the threads. In
    # this path the body is the only copy, so it has to stay actionable.
    assert_not_contains "$body" "<!-- finding:" \
        "and carries no finding tag, so the fixer treats it as actionable" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_does_not_post_twice_for_one_head_sha() {
    _cr_setup
    local rc=0 out body

    out=$(_cr_run --post)
    body=$("$JQ_BIN" -r '.body' "$MOCK_GH_DIR/review-post-1.json")
    # The full object `GET /repos/{o}/{r}/pulls/{n}/reviews` returns, not a
    # `{"body": …}` stub. This endpoint is raw REST that `gh api` passes through
    # verbatim, so its shape is the same under gh 2.63 as under 2.92 — unlike
    # the `--json` field sets on `gh pr view`, which gh synthesises itself and
    # which DID gain fields between those releases. Pinning the real shape is
    # what makes that difference visible instead of assumed. Note `submitted_at`
    # is Z-suffixed: nothing on this path may parse it with a bare
    # `datetime.fromisoformat`, which rejects the `Z` before Python 3.11.
    /usr/bin/python3 - "$MOCK_GH_DIR/reviews.json" "$body" "$CR_SHA" <<'PY'
import json, sys
path, body, sha = sys.argv[1:4]
json.dump([{
    "id": 900001,
    "node_id": "PRR_kwDOFIXTURE4AAAAA",
    "user": {"login": "amarcu", "id": 1234567, "type": "User",
             "site_admin": False},
    "body": body,
    "state": "COMMENTED",
    "html_url": "https://github.com/acme/testrepo/pull/7#pullrequestreview-900001",
    "pull_request_url": "https://api.github.com/repos/acme/testrepo/pulls/7",
    "author_association": "OWNER",
    "_links": {"html": {"href": "https://github.com/acme/testrepo/pull/7"},
               "pull_request": {"href": "https://api.github.com/repos/acme/testrepo/pulls/7"}},
    "submitted_at": "2026-09-08T13:59:00Z",
    "commit_id": sha,
}], open(path, "w"))
PY
    /bin/rm -f "$MOCK_CURSOR_DIR/argv.txt"

    out=$(_cr_run --post)
    assert_exit 0 $? "a repeat run is not an error" || rc=1
    assert_contains "$out" "already-posted head=${CR_SHA:0:7}" \
        "it says this commit was already reviewed" || rc=1
    if [[ -f "$MOCK_GH_DIR/review-post-2.json" ]]; then
        echo "  FAIL: a second review was posted for the same head SHA"
        rc=1
    fi
    if [[ -f "$MOCK_CURSOR_DIR/argv.txt" ]]; then
        echo "  FAIL: the repeat run paid for a review it was not going to post"
        rc=1
    fi

    out=$(_cr_run --post --force)
    assert_exit 0 $? "--force runs anyway" || rc=1
    assert_file_exists "$MOCK_GH_DIR/review-post-2.json" "and posts a second review" || rc=1

    _cr_teardown
    return $rc
}

# The regression this file exists for after 2026-09-09. The idempotence test
# above passed on the workstation and failed on the pipeline host, and the
# reason was never in cursor-review's matching: the reviews call simply did not
# answer there, and an unanswered call and an unreviewed pull request are the
# same empty bytes. Reading them as one re-reviewed every commit, spending the
# Cursor allowance and posting a duplicate review each night. What decides is
# the exit status, and this pins that it is the exit status being read.
test_cursor_review_refuses_when_it_cannot_read_the_prior_reviews() {
    _cr_setup
    local rc=0 out status=0

    # No canned answer means the mock exits non-zero with empty stdout — the
    # same shape the host produced when the mock's `--jq` fell through to a jq
    # that PATH could not resolve.
    /bin/rm -f "$MOCK_GH_DIR/reviews.json"

    out=$(_cr_run --post) || status=$?
    assert_exit 2 "$status" "it refuses instead of reviewing blind" || rc=1
    assert_contains "$(_cr_err)" "could not read the reviews already on acme/testrepo#7" \
        "and stderr names the call it could not make" || rc=1
    assert_contains "$(_cr_err)" "Refusing to run" "in those words" || rc=1
    if [[ -f "$MOCK_CURSOR_DIR/argv.txt" ]]; then
        echo "  FAIL: it paid for a review before knowing whether one was needed"
        rc=1
    fi
    if [[ -f "$MOCK_GH_DIR/review-post-1.json" ]]; then
        echo "  FAIL: it posted a review it could not rule out as a duplicate"
        rc=1
    fi

    # --force already means "post regardless of what is on the PR", so the
    # unreadable answer gates nothing and the run goes ahead.
    out=$(_cr_run --post --force)
    assert_exit 0 $? "--force runs anyway" || rc=1
    assert_file_exists "$MOCK_GH_DIR/review-post-1.json" "and posts the review" || rc=1
    assert_contains "$(_cr_err)" "--force is set" "saying why it did not refuse" || rc=1

    _cr_teardown
    return $rc
}

# The other half, one level down: the mock itself must not paper over a jq it
# cannot resolve. Real gh runs --jq in its own embedded jq and has no way to
# fail like this, so a mock that silently substitutes a different jq — or
# answers nothing at all — is inventing a response the caller will never see in
# production, which is exactly how the host failure hid inside a green suite.
test_cursor_review_mock_gh_refuses_to_serve_jq_without_a_resolved_jq() {
    _cr_setup
    local rc=0 out status=0

    out=$(JQ_BIN="" PATH="$FIXTURES_DIR/mock-gh:/usr/bin:/bin" \
          gh api "repos/acme/testrepo/pulls/7/reviews" --jq '.[].body' 2>&1) || status=$?
    if [[ "$status" -eq 0 ]]; then
        echo "  FAIL: the mock answered a --jq call with no jq resolved"
        rc=1
    fi
    assert_contains "$out" "JQ_BIN is unset or not executable" \
        "it says what is missing rather than returning an empty result" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_dry_run_posts_nothing() {
    _cr_setup
    local rc=0 out

    out=$(_cr_run --post --dry-run)
    assert_exit 0 $? "a posting dry run exits 0" || rc=1
    assert_contains "$out" "nothing is posted" "and says nothing is posted" || rc=1
    assert_contains "$out" "no verdict exists for this bundle yet" \
        "with no verdict there is nothing to render, and it says which" || rc=1
    if [[ -f "$MOCK_GH_DIR/review-post-1.json" ]]; then
        echo "  FAIL: --dry-run posted a review"
        rc=1
    fi

    # Once a verdict exists, the dry run shows the exact review it would post.
    _cr_run > /dev/null
    out=$(_cr_run --post --dry-run)
    assert_contains "$out" "--- review body ---" "it renders the body it would post" || rc=1
    assert_contains "$out" "<!-- cursor-review repo=acme/testrepo" "with the marker" || rc=1
    assert_contains "$out" "--- inline comments (1) ---" "and lists the inline comments" || rc=1
    assert_contains "$out" "<!-- finding:f1 severity:blocker" "each with its tag" || rc=1
    if [[ -f "$MOCK_GH_DIR/review-post-1.json" ]]; then
        echo "  FAIL: rendering the preview posted a review"
        rc=1
    fi

    _cr_teardown
    return $rc
}

# ── The verify gate ───────────────────────────────────────────────────────
#
# The reviewer cannot run commands, so cursor-review runs the gate itself and
# hands over the result. Before that, every verdict was capped at
# changes-needed by an outcome of could-not-run — Grok's round-2 review of
# PR #35 marked all three findings fixed, raised nothing new, and still could
# not say pass. These pin the four outcomes and the dry run.

# Rewrite the fixture repo's CLAUDE.md, commit it, and move the PR's head to
# the new commit so the bundle exports the tree under test.
_cr_gate() {
    /bin/cat > "$CR_REPO/CLAUDE.md" <<CLAUDE
# Fixture — Claude Code Context

## Build / Verify

$1

## Something after it
Text that must not be mistaken for the gate.
CLAUDE
    /usr/bin/git -C "$CR_REPO" add CLAUDE.md
    /usr/bin/git -C "$CR_REPO" -c commit.gpgsign=false commit -qm "declare a gate"
    CR_SHA=$(/usr/bin/git -C "$CR_REPO" rev-parse HEAD)
    /usr/bin/python3 - "$MOCK_GH_DIR/pr-view.json" "$CR_SHA" <<'PY'
import json, sys
pr = json.load(open(sys.argv[1]))
pr["headRefOid"] = sys.argv[2]
json.dump(pr, open(sys.argv[1], "w"))
PY
}

test_cursor_review_runs_the_gate_and_hands_the_result_to_the_reviewer() {
    _cr_setup
    # `test -f game/Player.cs` passes only if the gate ran in the bundle's own
    # src/ tree, which is the whole point of running it there.
    _cr_gate '```
test -f game/Player.cs
```'

    local rc=0 out gate="$CURSOR_REVIEW_BUNDLE_DIR/gate.json"
    out=$(_cr_run)
    assert_exit 0 $? "the run succeeds" || rc=1

    assert_file_exists "$gate" "gate.json lands in the bundle" || rc=1
    assert_equal "passed" "$("$JQ_BIN" -r '.outcome' "$gate")" "the gate passed" || rc=1
    assert_equal "test -f game/Player.cs" "$("$JQ_BIN" -r '.command' "$gate")" \
        "the exact command is recorded, so what ran is never a question" || rc=1
    assert_equal "0" "$("$JQ_BIN" -r '.exit' "$gate")" "with its exit code" || rc=1
    assert_equal "true" "$("$JQ_BIN" -r '.ran' "$gate")" "and it really ran" || rc=1
    assert_contains "$(_cr_err)" "cursor-review: gate passed" "the run says so on stderr" || rc=1

    # The reviewer is told the outcome and told to treat it as authoritative.
    local prompt
    prompt=$(/bin/cat "$MOCK_CURSOR_DIR/argv.txt")
    assert_contains "$prompt" "Verify gate:  passed" "the prompt carries the outcome" || rc=1
    assert_contains "$prompt" "Treat gate.json as authoritative" \
        "and forbids the reviewer claiming it ran anything" || rc=1

    # Whatever the reviewer said about the gate, this script's result wins.
    assert_equal "passed" \
        "$("$JQ_BIN" -r '.gate.outcome' "$CURSOR_REVIEW_BUNDLE_DIR/verdict.json")" \
        "the verdict carries the gate that actually ran" || rc=1
    assert_equal "test -f game/Player.cs" \
        "$("$JQ_BIN" -r '.gate.command' "$CURSOR_REVIEW_BUNDLE_DIR/verdict.json")" \
        "not the reviewer's guess at one" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_gate_records_a_failure_and_its_first_error_line() {
    _cr_setup
    _cr_gate '```
echo "error CS0246: the type or namespace could not be found"
exit 1
```'

    local rc=0 gate="$CURSOR_REVIEW_BUNDLE_DIR/gate.json"
    _cr_run > /dev/null

    assert_equal "failed" "$("$JQ_BIN" -r '.outcome' "$gate")" "a non-zero exit is a failure" || rc=1
    assert_equal "1" "$("$JQ_BIN" -r '.exit' "$gate")" "with the exit code kept" || rc=1
    assert_contains "$("$JQ_BIN" -r '.first_error_line' "$gate")" "error CS0246" \
        "and the first error line captured, so a finding can quote it verbatim" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_gate_honours_a_repo_that_declares_no_gate() {
    _cr_setup
    _cr_gate 'NO GATE — verify by reading'

    local rc=0 gate="$CURSOR_REVIEW_BUNDLE_DIR/gate.json"
    _cr_run > /dev/null

    assert_equal "no-gate" "$("$JQ_BIN" -r '.outcome' "$gate")" \
        "the declared no-gate wording is honoured" || rc=1
    assert_equal "null" "$("$JQ_BIN" -r '.command' "$gate")" "and nothing was run" || rc=1
    assert_equal "false" "$("$JQ_BIN" -r '.ran' "$gate")" "which is not the same as passing" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_gate_is_could_not_run_when_the_tool_is_absent() {
    _cr_setup
    _cr_gate '```
definitely-not-a-real-tool-xyz --version
```'

    local rc=0 gate="$CURSOR_REVIEW_BUNDLE_DIR/gate.json"
    _cr_run > /dev/null

    assert_equal "could-not-run" "$("$JQ_BIN" -r '.outcome' "$gate")" \
        "a missing tool is could-not-run, never failed" || rc=1
    assert_equal "127" "$("$JQ_BIN" -r '.exit' "$gate")" "the shell's 127 is kept" || rc=1
    assert_equal "false" "$("$JQ_BIN" -r '.ran' "$gate")" "and the gate did not run" || rc=1
    assert_contains "$("$JQ_BIN" -r '.reason' "$gate")" "not present on this host" \
        "the reason says which of the four cases this is" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_dry_run_does_not_run_the_gate() {
    _cr_setup
    # A command that would leave a trace if it were ever executed.
    _cr_gate '```
touch '"$CR_TMP"'/gate-ran-marker
```'

    local rc=0 out
    out=$(_cr_run --dry-run)
    assert_exit 0 $? "the dry run exits 0" || rc=1
    assert_contains "$out" "gate:   not-run (dry run)" "and says the gate was not run" || rc=1

    if [[ -e "$CR_TMP/gate-ran-marker" ]]; then
        echo "  FAIL: --dry-run executed the repo's gate command"
        rc=1
    fi
    if [[ -f "$CURSOR_REVIEW_BUNDLE_DIR/gate.json" ]]; then
        echo "  FAIL: --dry-run wrote gate.json"
        rc=1
    fi

    _cr_teardown
    return $rc
}

test_cursor_review_gate_prefers_a_named_command_over_no_gate_prose() {
    # The regression that made this ordering explicit: a substring test for
    # "NO GATE" reported this repository as having none, because its own
    # Build / Verify section says the words while explaining that a missing jq
    # is a broken environment and NOT a NO GATE. StarBonk's section does the
    # same, naming a Unity command and then a NO GATE fallback for a host
    # without the CLI. A section that names a command has a gate.
    _cr_setup
    _cr_gate '```
test -f game/Player.cs
```

If the tool is missing the gate is `NO GATE — verify by reading`, which is a
broken environment and not a declaration.'

    local rc=0 gate="$CURSOR_REVIEW_BUNDLE_DIR/gate.json"
    _cr_run > /dev/null

    assert_equal "passed" "$("$JQ_BIN" -r '.outcome' "$gate")" \
        "the named command wins over NO GATE appearing in prose beside it" || rc=1
    assert_equal "test -f game/Player.cs" "$("$JQ_BIN" -r '.command' "$gate")" \
        "and it is the command that ran" || rc=1

    _cr_teardown
    return $rc
}

# ── The four findings from Grok's round 1 on PR #37 ───────────────────────

test_cursor_review_gate_cannot_see_the_cursor_credential() {
    # f1. The gate command comes from a repo's CLAUDE.md and is arbitrary
    # shell. The comment that used to sit above the subprocess claimed the key
    # was never in this environment, which held only when it came from the key
    # FILE — an operator who exports CURSOR_API_KEY handed it straight over.
    _cr_setup
    export CURSOR_API_KEY="$CR_KEY"
    _cr_gate '```
printenv CURSOR_API_KEY > '"$CR_TMP"'/gate-saw-key.txt || echo ABSENT > '"$CR_TMP"'/gate-saw-key.txt
printenv CURSOR_API_KEY_FILE >> '"$CR_TMP"'/gate-saw-key.txt || echo NOFILE >> '"$CR_TMP"'/gate-saw-key.txt
```'

    local rc=0 seen
    _cr_run > /dev/null

    assert_equal "passed" "$("$JQ_BIN" -r '.outcome' "$CURSOR_REVIEW_BUNDLE_DIR/gate.json")" \
        "the gate ran" || rc=1
    seen=$(/bin/cat "$CR_TMP/gate-saw-key.txt")
    assert_not_contains "$seen" "$CR_KEY" \
        "the gate could not read the credential out of its environment" || rc=1
    assert_contains "$seen" "ABSENT" "CURSOR_API_KEY is unset for the child" || rc=1
    assert_contains "$seen" "NOFILE" "and so is the path pointing at it" || rc=1

    # The key still has to reach the reviewer, or the run would not work.
    assert_equal "key=set" "$(/bin/cat "$MOCK_CURSOR_DIR/env.txt")" \
        "while cursor-agent still gets it" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_pins_each_review_to_the_sha_it_reviewed() {
    # f2. With no commit_id, GitHub attaches the review to the PR's latest
    # commit at post time — so a head that moves during the run produces a
    # review of a commit nobody read.
    _cr_setup
    local rc=0 first_sha

    _cr_run --post > /dev/null
    first_sha="$CR_SHA"
    assert_equal "$first_sha" "$("$JQ_BIN" -r '.commit_id' "$MOCK_GH_DIR/review-post-1.json")" \
        "the review names the SHA that was bundled" || rc=1

    # The head moves. The next round reviews the new commit and says so, and
    # the first review still points at the commit it actually read.
    _cr_gate '```
true
```'
    _cr_run --post > /dev/null
    assert_equal "$CR_SHA" "$("$JQ_BIN" -r '.commit_id' "$MOCK_GH_DIR/review-post-2.json")" \
        "the second review names the new head" || rc=1
    assert_equal "$first_sha" "$("$JQ_BIN" -r '.commit_id' "$MOCK_GH_DIR/review-post-1.json")" \
        "and the first is still pinned to the old one" || rc=1
    if [[ "$first_sha" == "$CR_SHA" ]]; then
        echo "  FAIL: the fixture head did not move, so this proved nothing"
        rc=1
    fi

    _cr_teardown
    return $rc
}

# A reviewer that answers `pass` no matter what the gate did.
_cr_claims_pass() {
    _cr_envelope '{"repo": "acme/testrepo", "pr": 7, "head_sha": "x", "round": 1,
 "model": "x", "gate": {"outcome": "passed", "command": "make test", "exit": 0},
 "findings": [], "open": {"blocker": 0, "major": 0, "minor": 0},
 "verdict": "pass", "reason": "looks clean to me"}'
}

test_cursor_review_caps_a_pass_the_gate_does_not_support() {
    # f3. The protocol says a gate that did not report success can never
    # verdict pass. That was written down and not enforced: the gate block was
    # overwritten from gate.json while the reviewer's own pass went out intact.
    _cr_setup
    local rc=0 out verdict="$CURSOR_REVIEW_BUNDLE_DIR/verdict.json"

    # Each case below is an independent scenario against the same fixture PR,
    # so the round counter is cleared between them — four rounds on one PR
    # would hit REVIEW_ROUND_MAX and refuse before producing a verdict, and the
    # assertions would then read the previous case's file.
    _cr_reset_rounds() { /bin/rm -f "$METRICS_DIR"/*.json; }

    # 1. The gate ran and failed.
    _cr_gate '```
echo "error: broken"
exit 1
```'
    _cr_claims_pass
    out=$(_cr_run)
    assert_equal "changes-needed" "$("$JQ_BIN" -r '.verdict' "$verdict")" \
        "a failing gate caps the reviewer's pass" || rc=1
    assert_contains "$out" "verdict=changes-needed" "and the line says so" || rc=1
    assert_equal "pass" "$("$JQ_BIN" -r '.verdict_capped.from' "$verdict")" \
        "the original answer is recorded, not erased" || rc=1
    assert_contains "$("$JQ_BIN" -r '.verdict_capped.because' "$verdict")" "reported failed" \
        "with the reason" || rc=1
    assert_contains "$("$JQ_BIN" -r '.verdict_capped.reviewer_reason' "$verdict")" "looks clean" \
        "and what the reviewer had said" || rc=1

    _cr_reset_rounds
    # 2. The repo declares no gate.
    _cr_gate 'NO GATE — verify by reading'
    _cr_claims_pass
    _cr_run > /dev/null
    assert_equal "changes-needed" "$("$JQ_BIN" -r '.verdict' "$verdict")" \
        "no-gate caps it too — reading is not verifying" || rc=1

    _cr_reset_rounds
    # 3. The gate could not run at all.
    _cr_gate '```
definitely-not-a-real-tool-xyz
```'
    _cr_claims_pass
    _cr_run > /dev/null
    assert_equal "changes-needed" "$("$JQ_BIN" -r '.verdict' "$verdict")" \
        "and so does could-not-run" || rc=1

    _cr_reset_rounds
    # 4. The gate passed, so the reviewer's pass stands untouched.
    _cr_gate '```
true
```'
    _cr_claims_pass
    out=$(_cr_run)
    assert_equal "pass" "$("$JQ_BIN" -r '.verdict' "$verdict")" \
        "a pass over a passing gate is left alone" || rc=1
    assert_equal "null" "$("$JQ_BIN" -r '.verdict_capped' "$verdict")" \
        "and nothing is recorded as capped" || rc=1
    assert_contains "$out" "verdict=pass" "which is the outcome this lane exists to be able to give" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_posted_body_says_when_a_verdict_was_capped() {
    _cr_setup
    _cr_gate '```
exit 1
```'
    _cr_claims_pass

    local rc=0 body
    _cr_run --post > /dev/null
    body=$("$JQ_BIN" -r '.body' "$MOCK_GH_DIR/review-post-1.json")
    assert_contains "$body" "Verdict: changes-needed" "the posted verdict is the capped one" || rc=1
    assert_contains "$body" "was **capped**" "and the body says a cap was applied" || rc=1
    assert_contains "$body" "reported failed" "naming the gate outcome that caused it" || rc=1

    _cr_teardown
    return $rc
}

# A round-3 reviewer that concedes its only major and answers `pass`, as Grok
# did on StarBonk #60.
_cr_claims_pass_with_conceded_major() {
    _cr_envelope '{"repo": "x", "pr": 1, "head_sha": "x", "round": 3, "model": "x",
 "gate": {"outcome": "passed", "command": "true", "exit": 0},
 "findings": [{"id": "f1", "severity": "major", "path": "game/Player.cs", "line": 2,
               "state": "contested", "claim": "the meta is incomplete",
               "evidence": "the reply showed the editor writes it so", "what-settles-it": "accepted"}],
 "open": {"blocker": 0, "major": 0, "minor": 0},
 "verdict": "pass", "reason": "f1 is contested and nothing else is open"}'
}

test_cursor_review_does_not_cap_a_pass_over_a_conceded_finding() {
    _cr_setup
    _cr_gate '```
true
```'
    local rc=0 out verdict="$CURSOR_REVIEW_BUNDLE_DIR/verdict.json"

    _cr_claims_pass_with_conceded_major
    out=$(_cr_run)
    assert_equal "pass" "$("$JQ_BIN" -r '.verdict' "$verdict")" \
        "a contested finding is one the reviewer accepted was wrong" || rc=1
    assert_equal "null" "$("$JQ_BIN" -r '.verdict_capped' "$verdict")" \
        "so nothing caps the pass" || rc=1
    assert_contains "$out" "verdict=pass findings=0/0/0" "the line agrees" || rc=1

    _cr_teardown
    return $rc
}

# ── The two findings from Grok's round 2 on PR #37 ────────────────────────

# A reviewer that answers `pass` while its own findings list still carries an
# unfixed blocker — the contradiction f6 is about.
_cr_claims_pass_with_open_blocker() {
    _cr_envelope '{"repo": "x", "pr": 1, "head_sha": "x", "round": 1, "model": "x",
 "gate": {"outcome": "passed", "command": "true", "exit": 0},
 "findings": [{"id": "f1", "severity": "blocker", "path": "game/Player.cs", "line": 2,
               "state": "still-open", "claim": "checklist 2: the test was weakened",
               "evidence": "the assertion is gone", "what-settles-it": "restore it"}],
 "open": {"blocker": 1, "major": 0, "minor": 0},
 "verdict": "pass", "reason": "close enough"}'
}

test_cursor_review_caps_a_pass_that_contradicts_its_own_findings() {
    # f6. The gate cap alone was not the protocol's rule: pass requires a
    # passing gate AND no open blocker or major. Whether a verdict contradicts
    # the list the reviewer just wrote is arithmetic, not judgement, so it is
    # checked here rather than trusted.
    _cr_setup
    _cr_gate '```
true
```'
    local rc=0 out verdict="$CURSOR_REVIEW_BUNDLE_DIR/verdict.json"

    _cr_claims_pass_with_open_blocker
    out=$(_cr_run)
    assert_equal "passed" "$("$JQ_BIN" -r '.gate.outcome' "$verdict")" \
        "the gate itself passed, so only the findings can cap this" || rc=1
    assert_equal "changes-needed" "$("$JQ_BIN" -r '.verdict' "$verdict")" \
        "a pass over an unfixed blocker is capped" || rc=1
    assert_contains "$("$JQ_BIN" -r '.verdict_capped.because' "$verdict")" "f1 (blocker)" \
        "and the reason names the finding that caused it" || rc=1
    assert_contains "$("$JQ_BIN" -r '.verdict_capped.because' "$verdict")" "still open" \
        "in so many words" || rc=1
    assert_equal "pass" "$("$JQ_BIN" -r '.verdict_capped.from' "$verdict")" \
        "with the reviewer's own answer kept" || rc=1
    assert_contains "$out" "verdict=changes-needed findings=1/0/0" "the line agrees" || rc=1

    # A finding the reviewer adjudicated as fixed does not block anything.
    /bin/rm -f "$METRICS_DIR"/*.json
    _cr_envelope '{"repo": "x", "pr": 1, "head_sha": "x", "round": 1, "model": "x",
 "gate": {"outcome": "passed", "command": "true", "exit": 0},
 "findings": [{"id": "f1", "severity": "blocker", "path": "game/Player.cs", "line": 2,
               "state": "fixed", "claim": "checklist 2: the test was weakened",
               "evidence": "the assertion is back", "what-settles-it": "-"}],
 "open": {"blocker": 0, "major": 0, "minor": 0},
 "verdict": "pass", "reason": "the blocker was addressed"}'
    out=$(_cr_run)
    assert_equal "pass" "$("$JQ_BIN" -r '.verdict' "$verdict")" \
        "a blocker marked fixed leaves the pass standing" || rc=1
    assert_equal "null" "$("$JQ_BIN" -r '.verdict_capped' "$verdict")" "and caps nothing" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_capped_body_names_the_open_finding() {
    _cr_setup
    _cr_gate '```
true
```'
    _cr_claims_pass_with_open_blocker

    local rc=0 body
    _cr_run --post > /dev/null
    body=$("$JQ_BIN" -r '.body' "$MOCK_GH_DIR/review-post-1.json")
    assert_contains "$body" "was **capped**" "the posted body says a cap was applied" || rc=1
    assert_contains "$body" "f1 (blocker)" "and which open finding caused it" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_round_two_adjudicates_the_prior_findings() {
    # f5. The protocol requires round 2 to adjudicate each prior finding
    # fixed, still-open or contested. The prompt carried neither the prior
    # findings nor the replies, so the reviewer could only re-review from
    # scratch and any "fixed" was inference from the diff.
    _cr_setup
    local rc=0 prompt

    _cr_run --post > /dev/null
    prompt=$(/bin/cat "$MOCK_CURSOR_DIR/argv.txt")
    assert_not_contains "$prompt" "Prior rounds on this pull request" \
        "round 1 has nothing to adjudicate" || rc=1

    # The thread the first round opened, and the worker's reply on it.
    /usr/bin/python3 - "$MOCK_GH_DIR/review-post-1.json" "$MOCK_GH_DIR/review-comments.json" <<'PY'
import json, sys
posted = json.load(open(sys.argv[1]))
root = posted["comments"][0]
json.dump([[
    {"id": 101, "path": root["path"], "line": root["line"], "body": root["body"],
     "user": {"login": "amarcu"}, "in_reply_to_id": None},
    {"id": 102, "path": root["path"], "line": root["line"],
     "body": "Addressed in DECOY_REPLY_SHA. The manifest is parsed once now.",
     "user": {"login": "amarcu"}, "in_reply_to_id": 101},
]], open(sys.argv[2], "w"))
PY

    _cr_run --post > /dev/null
    prompt=$(/bin/cat "$MOCK_CURSOR_DIR/argv.txt")
    assert_contains "$prompt" "Prior rounds on this pull request" \
        "round 2 carries the prior context" || rc=1
    assert_contains "$prompt" "### f1 - blocker - round 1" \
        "naming the finding, its severity and the round it came from" || rc=1
    assert_contains "$prompt" "game/Player.cs:2" "and where it was anchored" || rc=1
    assert_contains "$prompt" "the criterion is unproven" "with the claim it made" || rc=1
    assert_contains "$prompt" "DECOY_REPLY_SHA" "and the reply left on its thread" || rc=1
    assert_contains "$prompt" "Adjudicate every finding listed above" \
        "and the instruction to adjudicate it" || rc=1
    assert_contains "$prompt" "caps" "with the budget rule spelled out" || rc=1
    assert_contains "$prompt" "NEW findings only" \
        "so adjudication is never squeezed out by the per-round cap" || rc=1
    assert_contains "$(_cr_err)" "prior rounds: 1 prior finding(s), 1 with replies" \
        "and the run says what it found" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_round_two_context_survives_without_posted_threads() {
    # The replies come from the PR, but the findings come from this lane's own
    # verdict files — so a run that never posted still adjudicates.
    _cr_setup
    local rc=0 prompt

    _cr_run > /dev/null
    _cr_run > /dev/null
    prompt=$(/bin/cat "$MOCK_CURSOR_DIR/argv.txt")

    assert_contains "$prompt" "Prior rounds on this pull request" \
        "the prior round is still carried" || rc=1
    assert_contains "$prompt" "### f1 - blocker - round 1" "from the local verdict file" || rc=1
    assert_contains "$prompt" "No reply on this thread." \
        "and it says plainly that there is no reply, rather than implying one" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_posts_the_findings_it_could_not_anchor_as_a_tagged_comment() {
    # Since PR #36, pr-feedback classifies EVERY lane summary as `reviewer` and
    # skips it as `reviewer-summary` context, so a finding stated only in that
    # body is never acted on. An unanchorable finding therefore goes up as its
    # own comment carrying its tag, which pr-feedback keeps actionable.
    # (Grok, PR #43 f1.)
    _cr_setup
    _cr_envelope '{"repo": "acme/testrepo", "pr": 7, "head_sha": "deadbeef", "round": 1,
 "model": "m", "gate": {"outcome": "passed", "command": "make test", "exit": 0},
 "findings": [{"id": "f1", "severity": "major", "path": "game/Player.cs", "line": 2,
               "state": "new", "claim": "ANCHORED the criterion is unproven",
               "evidence": "no test touches it"},
              {"id": "f2", "severity": "major", "state": "new",
               "claim": "UNANCHORED the deleted file is still imported",
               "evidence": "the import outlives the delete"}],
 "open": {"blocker": 0, "major": 2, "minor": 0},
 "verdict": "changes-needed", "reason": "two majors"}'

    local rc=0 out body
    out=$(_cr_run --post)
    assert_exit 0 $? "the run itself is fine" || rc=1
    assert_contains "$out" "unanchored=1" \
        "the line says one finding reached the PR as a comment" || rc=1
    assert_file_exists "$MOCK_GH_DIR/issue-comment-post-1.json" \
        "the unanchorable finding went up as its own comment" || rc=1
    body=$("$JQ_BIN" -r '.body' "$MOCK_GH_DIR/issue-comment-post-1.json" 2>/dev/null)
    assert_contains "$body" "UNANCHORED the deleted file is still imported" \
        "carrying the finding in full" || rc=1
    assert_contains "$body" "<!-- finding:f2 severity:major round:" \
        "and its tag, which is what keeps it actionable for pr-feedback" || rc=1
    assert_not_contains "$body" "ANCHORED the criterion is unproven" \
        "the finding that did anchor is a thread, not repeated here" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_makes_the_422_fallback_findings_actionable_too() {
    # The fallback body is the only copy of the findings, and it is a lane
    # summary, so pr-feedback skips it. The same findings go up as a comment.
    _cr_setup
    /usr/bin/touch "$MOCK_GH_DIR/reviews-reject-inline"

    local rc=0 out body
    out=$(_cr_run --post)
    assert_exit 0 $? "a 422 on the anchors is not a failure" || rc=1
    assert_contains "$out" "posted=body" "the review itself fell back to the body" || rc=1
    assert_contains "$out" "unanchored=1" "and the finding is counted as commented" || rc=1
    assert_file_exists "$MOCK_GH_DIR/issue-comment-post-1.json" \
        "the findings went up as a tagged comment as well" || rc=1
    body=$("$JQ_BIN" -r '.body' "$MOCK_GH_DIR/issue-comment-post-1.json" 2>/dev/null)
    assert_contains "$body" "the criterion is unproven" "carrying the finding" || rc=1
    assert_contains "$body" "<!-- finding:f1 severity:blocker round:" "with its tag" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_posts_no_extra_comment_when_every_finding_anchors() {
    # The threads are the findings. A second copy in a comment would be a
    # duplicate the fixer answers twice.
    _cr_setup

    local rc=0 out
    out=$(_cr_run --post)
    assert_exit 0 $? "the run is fine" || rc=1
    assert_contains "$out" "unanchored=0" "nothing needed a comment" || rc=1
    if [[ -f "$MOCK_GH_DIR/issue-comment-post-1.json" ]]; then
        echo "  FAIL: a comment went up although every finding anchored inline"
        rc=1
    fi

    _cr_teardown
    return $rc
}

# A later round's verdict, as the reviewer returns it: one finding of each state.
_cr_adjudicated() {
    _cr_envelope '{"repo": "acme/testrepo", "pr": 7, "head_sha": "deadbeef", "round": 2,
 "model": "m", "gate": {"outcome": "passed", "command": "make test", "exit": 0},
 "findings": [{"id": "f1", "severity": "major", "path": "game/Player.cs", "line": 2,
               "state": "fixed", "claim": "FIXED_CLAIM the manifest is parsed twice",
               "evidence": "FIXED_EVIDENCE"},
              {"id": "f2", "severity": "major", "path": "game/Player.cs", "line": 2,
               "state": "still-open", "claim": "STILL_OPEN_CLAIM no test covers it",
               "evidence": "no test touches the manifest path"},
              {"id": "f3", "severity": "minor", "state": "contested",
               "claim": "CONTESTED_CLAIM the log line is noisy",
               "evidence": "it prints on every start"},
              {"id": "f4", "severity": "major", "path": "game/Player.cs", "line": 2,
               "state": "new", "claim": "NEW_CLAIM the comment is misleading",
               "evidence": "it says changed"}],
 "open": {"blocker": 0, "major": 2, "minor": 1},
 "verdict": "changes-needed", "reason": "two majors and a minor open"}'
}

test_cursor_review_posts_no_thread_for_a_finding_the_reviewer_marked_fixed() {
    # Issue #57. On PR #54 round 2 the verdict ruled f1-f5 fixed and counted one
    # open major, and all six went up as new "major" threads — five of them
    # unanswered work for pr-feedback that had already been done.
    _cr_setup
    _cr_adjudicated

    local rc=0 out posted body inline
    out=$(_cr_run --post)
    assert_exit 0 $? "the run is fine" || rc=1
    posted="$MOCK_GH_DIR/review-post-1.json"

    assert_equal "f2 f4" \
        "$("$JQ_BIN" -r '[.comments[].body | capture("finding:(?<id>f[0-9]+)").id] | join(" ")' "$posted")" \
        "only the findings still open become threads" || rc=1
    inline=$("$JQ_BIN" -r '.comments[].body' "$posted")
    assert_not_contains "$inline" "FIXED_CLAIM" "the fixed finding is not re-posted as a thread" || rc=1
    assert_contains "$inline" "**f2 — major — still open**" \
        "a still-open finding says so in its thread" || rc=1
    assert_contains "$inline" "**f4 — major**" "a new finding reads as it always did" || rc=1
    assert_contains "$inline" "<!-- finding:f2 severity:major round:" \
        "and each open thread keeps the tag pr-feedback parses" || rc=1

    body=$("$JQ_BIN" -r '.body' "$posted")
    assert_contains "$body" "- Open findings: 0 blocker, 2 major, 1 minor" "the counts" || rc=1
    assert_equal "3" "$(printf '%s\n' "$body" | /usr/bin/sed '/^### Earlier findings/,$d' \
                        | /usr/bin/grep -cE '^(- `f[0-9]+` \*\*|\*\*f[0-9]+ — )')" \
        "and the open findings the body names agree with them: two threads, one unanchored" || rc=1
    assert_contains "$body" "- \`f2\` **major** — still open — \`game/Player.cs:2\`" \
        "the index gives a still-open finding its state" || rc=1
    assert_contains "$body" "**f3 — minor — contested**" "and a contested one its state" || rc=1
    assert_contains "$body" "### Earlier findings the reviewer marked fixed" \
        "the fixed finding is recorded in the body" || rc=1
    assert_contains "$body" "- \`f1\` **major** — \`game/Player.cs:2\`" "by id, severity and place" || rc=1
    assert_not_contains "$body" "FIXED_EVIDENCE" "and not restated as something to act on" || rc=1
    assert_not_contains "$body" "finding:f1 " "and carrying no tag" || rc=1

    assert_contains "$out" "unanchored=1" "the contested finding needed its own comment" || rc=1
    body=$("$JQ_BIN" -r '.body' "$MOCK_GH_DIR/issue-comment-post-1.json" 2>/dev/null)
    assert_contains "$body" "CONTESTED_CLAIM" "and got one" || rc=1
    assert_not_contains "$body" "FIXED_CLAIM" "which does not carry the fixed finding" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_422_fallback_leaves_out_a_finding_marked_fixed() {
    _cr_setup
    _cr_adjudicated
    /usr/bin/touch "$MOCK_GH_DIR/reviews-reject-inline"

    local rc=0 out body
    out=$(_cr_run --post)
    assert_exit 0 $? "a 422 on the anchors is not a failure" || rc=1
    assert_contains "$out" "posted=body" "the review fell back to the body" || rc=1
    assert_contains "$out" "unanchored=3" "and the three open findings went up as a comment" || rc=1
    body=$("$JQ_BIN" -r '.body' "$MOCK_GH_DIR/issue-comment-post-1.json" 2>/dev/null)
    assert_contains "$body" "STILL_OPEN_CLAIM" "the still-open finding is actionable" || rc=1
    assert_contains "$body" "NEW_CLAIM" "and the new one" || rc=1
    assert_not_contains "$body" "FIXED_CLAIM" "the fixed one is not" || rc=1
    assert_not_contains "$(/bin/cat "$MOCK_GH_DIR/review-post-2.json")" "FIXED_CLAIM" \
        "nor is it restated in the fallback body" || rc=1

    _cr_teardown
    return $rc
}

test_cursor_review_posts_no_thread_when_every_finding_is_fixed() {
    _cr_setup
    _cr_envelope '{"repo": "acme/testrepo", "pr": 7, "head_sha": "deadbeef", "round": 2,
 "model": "m", "gate": {"outcome": "passed", "command": "make test", "exit": 0},
 "findings": [{"id": "f1", "severity": "blocker", "path": "game/Player.cs", "line": 2,
               "state": "fixed", "claim": "FIXED_CLAIM", "evidence": "e"}],
 "open": {"blocker": 0, "major": 0, "minor": 0},
 "verdict": "pass", "reason": "the one finding is fixed"}'

    local rc=0 out posted
    out=$(_cr_run --post)
    assert_exit 0 $? "the run is fine" || rc=1
    posted="$MOCK_GH_DIR/review-post-1.json"
    assert_equal "0" "$("$JQ_BIN" -r '.comments // [] | length' "$posted")" "no thread goes up" || rc=1
    assert_contains "$("$JQ_BIN" -r '.body' "$posted")" "No open findings." \
        "the body says nothing is open" || rc=1
    assert_contains "$out" "unanchored=0" "and no comment was needed" || rc=1
    if [[ -f "$MOCK_GH_DIR/issue-comment-post-1.json" ]]; then
        echo "  FAIL: a comment went up for a finding the reviewer marked fixed"
        rc=1
    fi

    _cr_teardown
    return $rc
}

test_cursor_review_gate_survives_output_that_is_not_utf8() {
    # 2026-09-13: PR #49's gate passed, and the lane recorded could-not-run.
    # The gate's output was read with text=True, a strict UTF-8 decode, and a
    # runner test had printed an awk warning quoting a byte from `ioreg -l`
    # that is not UTF-8. One stray byte capped the verdict. Octal escapes:
    # /usr/bin/printf on macOS has no \x.
    _cr_setup
    local rc=0 gate="$CURSOR_REVIEW_BUNDLE_DIR/gate.json"
    _cr_gate '```
/usr/bin/printf '"'"'awk: towc: multibyte conversion failure on: \211\n'"'"'
exit 0
```'
    _cr_run > /dev/null
    assert_equal "passed" "$("$JQ_BIN" -r '.outcome' "$gate")" \
        "a passing gate that printed a stray byte still passed" || rc=1
    _cr_teardown
    return $rc
}

test_cursor_review_gate_failure_with_output_that_is_not_utf8_is_still_a_failure() {
    _cr_setup
    local rc=0 gate="$CURSOR_REVIEW_BUNDLE_DIR/gate.json"
    _cr_gate '```
/usr/bin/printf '"'"'error CS0246 near \211\n'"'"'
exit 1
```'
    _cr_run > /dev/null
    assert_equal "failed" "$("$JQ_BIN" -r '.outcome' "$gate")" \
        "a failing gate is a failure, not could-not-run" || rc=1
    assert_equal "1" "$("$JQ_BIN" -r '.exit' "$gate")" "with its exit code kept" || rc=1
    assert_contains "$("$JQ_BIN" -r '.first_error_line' "$gate")" "error CS0246" \
        "and its first error line still captured" || rc=1
    _cr_teardown
    return $rc
}
