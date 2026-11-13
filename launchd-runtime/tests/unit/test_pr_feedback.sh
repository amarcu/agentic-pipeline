#!/bin/bash
# Tests for iterate-on-pr/scripts/pr-feedback — the feedback classifier.
#
# The bugs these lock in are the two that made a second iterate-on-pr run act
# on work the first one had already done: authorship cannot separate the human,
# review-pr and the worker (one GitHub login posts all three), and nothing
# marked a thread as answered, so every addressed thread came back as fresh
# feedback. The classifier's whole job is the markers, so the assertions below
# check `kind` and `skip` per item rather than that the script ran.

_prf_setup() {
    PRF_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-prf.XXXXXX)
    export MOCK_GH_DIR="$PRF_TMP/gh"
    /bin/mkdir -p "$MOCK_GH_DIR/bin"
    printf 'amarcu\n' > "$MOCK_GH_DIR/login.txt"
    echo '[[]]' > "$MOCK_GH_DIR/issue-comments.json"
    echo '[[]]' > "$MOCK_GH_DIR/reviews.json"
    # Only read when a review body carries a lane marker: it is how an inline
    # finding is attributed to the lane that raised it, through its review.
    echo '[[]]' > "$MOCK_GH_DIR/pr-comments.json"
    _prf_threads "false" ""

    # A gh that answers only the four call shapes pr-feedback makes, and exits
    # 1 for anything else — an unexpected call must fail loudly, not silently
    # return nothing.
    /bin/cat > "$MOCK_GH_DIR/bin/gh" <<'EOF'
#!/bin/bash
set -u
dir="${MOCK_GH_DIR:?}"
serve() { [[ -f "$1" ]] || exit 1; /bin/cat "$1"; exit 0; }
if [[ "${1:-}" == "api" ]]; then
    case "$*" in
        *graphql*cursor=*)      serve "$dir/threads-page2.json" ;;
        *graphql*)              serve "$dir/threads.json" ;;
        *"api user"*)           serve "$dir/login.txt" ;;
        */issues/*/comments*)   serve "$dir/issue-comments.json" ;;
        */pulls/*/reviews*)     serve "$dir/reviews.json" ;;
        */pulls/*/comments*)    serve "$dir/pr-comments.json" ;;
    esac
fi
echo "mock gh: unhandled call: $*" >&2
exit 1
EOF
    /bin/chmod +x "$MOCK_GH_DIR/bin/gh"
    export PATH="$MOCK_GH_DIR/bin:$PATH"
}

_prf_teardown() {
    /bin/rm -rf "$PRF_TMP"
}

# threads.json from a JSON array of thread nodes, plus the page flag.
_prf_threads() {
    local has_next="$1" nodes="${2:-}"
    [[ -n "$nodes" ]] || nodes="[]"
    /bin/cat > "$MOCK_GH_DIR/threads.json" <<EOF
{"data": {"repository": {"pullRequest": {"reviewThreads": {
  "pageInfo": {"hasNextPage": $has_next, "endCursor": "CUR1"},
  "nodes": $nodes}}}}}
EOF
}

# One thread node. Args: id path resolved outdated <comment json…>
_prf_thread_node() {
    local id="$1" path="$2" resolved="$3" outdated="$4"; shift 4
    local comments count
    comments=$(printf '%s,' "$@"); comments="[${comments%,}]"
    count=$#
    printf '{"id": "%s", "isResolved": %s, "isOutdated": %s, "path": "%s",
             "line": 42, "originalLine": 42,
             "comments": {"totalCount": %d, "nodes": %s}}' \
           "$id" "$resolved" "$outdated" "$path" "$count" "$comments"
}

# One comment node. Args: databaseId login createdAt body [__typename]
_prf_comment() {
    /usr/bin/python3 -c '
import json, sys
print(json.dumps({"databaseId": int(sys.argv[1]),
                  "url": "https://github.com/acme/testrepo/pull/7#c" + sys.argv[1],
                  "createdAt": sys.argv[3], "body": sys.argv[4],
                  "author": {"login": sys.argv[2],
                             "__typename": sys.argv[5] if len(sys.argv) > 5 else "User"}}))
' "$@"
}

_prf_run() {
    "$REPO_ROOT/skills/iterate-on-pr/scripts/pr-feedback" acme/testrepo 7 2>"$PRF_TMP/err"
}

# The JSON line for one item, selected by a substring of its body.
_prf_item() {
    /usr/bin/python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    item = json.loads(line)
    if sys.argv[1] in item["body"]:
        print(json.dumps(item, sort_keys=True))
        break
' "$1"
}

test_pr_feedback_treats_a_finding_thread_as_reviewer_feedback() {
    _prf_setup
    local rc=0 out item
    # review-pr posts under the same login as the human; only the tag says so.
    _prf_threads "false" "[$(_prf_thread_node T1 src/a.ts false false \
        "$(_prf_comment 1001 amarcu 2026-09-01T10:00:00Z \
            'The null check is missing. <!-- finding:f1 severity:blocker round:1 -->')")]"

    out=$(_prf_run) || rc=1
    item=$(printf '%s\n' "$out" | _prf_item "null check")
    assert_contains "$item" '"kind": "reviewer"' "a finding tag makes it reviewer feedback" || rc=1
    assert_contains "$item" '"skip": ""' "and it is actionable" || rc=1
    assert_contains "$item" '"finding": "f1"' "the finding id is carried through" || rc=1
    assert_contains "$item" '"id": 1001' "id is the comment to reply to" || rc=1

    _prf_teardown
    return $rc
}

test_pr_feedback_skips_a_thread_the_worker_already_answered() {
    _prf_setup
    local rc=0 out item
    # The reply marker is the durable idempotence record: thread resolution is
    # deny-listed for scheduled runs, so nothing else survives to the next run.
    _prf_threads "false" "[$(_prf_thread_node T1 src/a.ts false false \
        "$(_prf_comment 1001 amarcu 2026-09-01T10:00:00Z \
            'The null check is missing. <!-- finding:f1 severity:blocker round:1 -->')" \
        "$(_prf_comment 1002 amarcu 2026-09-01T11:00:00Z \
            'Added the guard in parse(). <!-- reply finding:f1 outcome:fixed -->')")]"

    out=$(_prf_run) || rc=1
    item=$(printf '%s\n' "$out" | _prf_item "null check")
    assert_contains "$item" '"skip": "answered"' "an answered thread is not acted on twice" || rc=1
    assert_not_contains "$item" "Added the guard" "the worker's own reply is not feedback" || rc=1
    assert_contains "$(/bin/cat "$PRF_TMP/err")" "actionable=0" "summary counts it as skipped" || rc=1

    _prf_teardown
    return $rc
}

test_pr_feedback_skips_comments_older_than_the_last_summary() {
    _prf_setup
    local rc=0 out old new
    _prf_threads "false" "[$(_prf_thread_node T1 src/a.ts false false \
        "$(_prf_comment 1001 amarcu 2026-09-01T09:00:00Z 'STALE rename this')"),
      $(_prf_thread_node T2 src/b.ts false false \
        "$(_prf_comment 1003 amarcu 2026-09-01T13:00:00Z 'FRESH swap the order')")]"
    /bin/cat > "$MOCK_GH_DIR/issue-comments.json" <<'EOF'
[[{"id": 900, "created_at": "2026-09-01T12:00:00Z",
   "user": {"login": "amarcu", "type": "User"},
   "html_url": "https://github.com/acme/testrepo/pull/7#i900",
   "body": "Addressed in abc1234:\n\n- renamed\n\n<!-- agentic-skills: skill=iterate-on-pr repo=acme/testrepo pr=7 -->"}]]
EOF

    out=$(_prf_run) || rc=1
    old=$(printf '%s\n' "$out" | _prf_item "STALE")
    new=$(printf '%s\n' "$out" | _prf_item "FRESH")
    assert_contains "$old" '"skip": "addressed"' "feedback older than the summary is done" || rc=1
    assert_contains "$new" '"skip": ""' "feedback newer than the summary is not" || rc=1
    assert_contains "$(printf '%s\n' "$out" | _prf_item 'Addressed in')" \
        '"skip": "own-summary"' "the worker's own summary is never feedback" || rc=1

    _prf_teardown
    return $rc
}

test_pr_feedback_drops_bots_and_the_reviewer_summary_body() {
    _prf_setup
    local rc=0 out
    /bin/cat > "$MOCK_GH_DIR/issue-comments.json" <<'EOF'
[[{"id": 901, "created_at": "2026-09-01T10:00:00Z",
   "user": {"login": "vercel[bot]", "type": "Bot"},
   "html_url": "https://github.com/acme/testrepo/pull/7#i901",
   "body": "PREVIEW deployment ready"}]]
EOF
    /bin/cat > "$MOCK_GH_DIR/reviews.json" <<'EOF'
[[{"id": 800, "submitted_at": "2026-09-01T10:30:00Z", "state": "COMMENTED",
   "user": {"login": "amarcu", "type": "User"},
   "html_url": "https://github.com/acme/testrepo/pull/7#r800",
   "body": "<!-- review-pr repo=acme/testrepo pr=7 round=1 verdict=changes-needed -->\nVERDICT one blocker."}]]
EOF

    out=$(_prf_run) || rc=1
    assert_contains "$(printf '%s\n' "$out" | _prf_item PREVIEW)" '"kind": "bot"' \
        "a Bot author is never feedback" || rc=1
    assert_contains "$(printf '%s\n' "$out" | _prf_item PREVIEW)" '"skip": "bot"' \
        "and is never acted on" || rc=1
    assert_contains "$(printf '%s\n' "$out" | _prf_item VERDICT)" '"skip": "reviewer-summary"' \
        "the review summary is context; its findings arrive as threads" || rc=1

    _prf_teardown
    return $rc
}

test_pr_feedback_pages_past_the_first_response() {
    _prf_setup
    local rc=0 out
    _prf_threads "true" "[$(_prf_thread_node T1 src/a.ts false false \
        "$(_prf_comment 1001 amarcu 2026-09-01T10:00:00Z 'PAGE1 fix this')")]"
    /bin/cat > "$MOCK_GH_DIR/threads-page2.json" <<EOF
{"data": {"repository": {"pullRequest": {"reviewThreads": {
  "pageInfo": {"hasNextPage": false, "endCursor": null},
  "nodes": [$(_prf_thread_node T2 src/b.ts false false \
      "$(_prf_comment 1002 amarcu 2026-09-01T10:05:00Z 'PAGE2 and this')")]}}}}}
EOF

    out=$(_prf_run) || rc=1
    assert_contains "$(printf '%s\n' "$out" | _prf_item PAGE2)" '"skip": ""' \
        "a thread on the second page is still feedback" || rc=1
    assert_contains "$(/bin/cat "$PRF_TMP/err")" "threads=2" "both pages counted" || rc=1

    _prf_teardown
    return $rc
}

test_pr_feedback_halts_rather_than_truncating_a_crowded_pr() {
    _prf_setup
    local rc=0 out status=0
    /usr/bin/python3 -c '
import json, sys
nodes = [{"id": "T%d" % i, "isResolved": False, "isOutdated": False,
          "path": "src/f%d.ts" % i, "line": 1, "originalLine": 1,
          "comments": {"totalCount": 1, "nodes": [
              {"databaseId": 2000 + i, "url": "u", "createdAt": "2026-09-01T10:00:00Z",
               "body": "thread %d" % i, "author": {"login": "amarcu", "__typename": "User"}}]}}
         for i in range(60)]
json.dump({"data": {"repository": {"pullRequest": {"reviewThreads": {
    "pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": nodes}}}}},
    open(sys.argv[1], "w"))
' "$MOCK_GH_DIR/threads.json"

    out=$(_prf_run) || status=$?
    assert_exit 3 "$status" "a PR past the cap halts" || rc=1
    assert_contains "$(/bin/cat "$PRF_TMP/err")" "more than 50 review threads" \
        "and says why, rather than truncating silently" || rc=1
    assert_not_contains "$out" '"kind"' "nothing is emitted from a halted run" || rc=1

    _prf_teardown
    return $rc
}

test_pr_feedback_keeps_an_unresolved_human_thread_actionable() {
    _prf_setup
    local rc=0 out
    _prf_threads "false" "[$(_prf_thread_node T1 src/a.ts false false \
        "$(_prf_comment 1001 amarcu 2026-09-01T10:00:00Z 'HUMAN swap the order here')"),
      $(_prf_thread_node T2 src/b.ts true false \
        "$(_prf_comment 1002 amarcu 2026-09-01T10:00:00Z 'DONE already handled')")]"

    out=$(_prf_run) || rc=1
    assert_contains "$(printf '%s\n' "$out" | _prf_item HUMAN)" '"kind": "human"' \
        "an untagged thread is human feedback" || rc=1
    assert_contains "$(printf '%s\n' "$out" | _prf_item HUMAN)" '"path": "src/a.ts"' \
        "with the path the reply anchors to" || rc=1
    assert_contains "$(printf '%s\n' "$out" | _prf_item DONE)" '"skip": "resolved"' \
        "a resolved thread is not reopened" || rc=1

    _prf_teardown
    return $rc
}

test_pr_feedback_only_moves_the_cutoff_for_its_own_summary() {
    _prf_setup
    local rc=0 out
    # The human writes under the same login as the worker, so the "Addressed in"
    # prefix alone cannot identify the worker's summary: a human comment opening
    # with those words would drag the cut-off forward and silently retire every
    # thread older than it. The attribution marker is what settles authorship.
    _prf_threads "false" "[$(_prf_thread_node T1 src/a.ts false false \
        "$(_prf_comment 1001 amarcu 2026-09-01T13:00:00Z 'LIVE this is still wrong')")]"
    /bin/cat > "$MOCK_GH_DIR/issue-comments.json" <<'JSON'
[[{"id": 900, "created_at": "2026-09-01T12:00:00Z",
   "user": {"login": "amarcu", "type": "User"},
   "html_url": "https://github.com/acme/testrepo/pull/7#i900",
   "body": "Addressed in abc1234:\n\n- renamed\n\n<!-- agentic-skills: skill=iterate-on-pr repo=acme/testrepo pr=7 -->"},
  {"id": 901, "created_at": "2026-09-01T14:00:00Z",
   "user": {"login": "amarcu", "type": "User"},
   "html_url": "https://github.com/acme/testrepo/pull/7#i901",
   "body": "Addressed in the release notes already, HUMANPREFIX have another look"}]]
JSON

    out=$(_prf_run) || rc=1
    assert_contains "$(printf '%s\n' "$out" | _prf_item LIVE)" '"skip": ""' \
        "a human comment opening 'Addressed in' must not retire newer feedback" || rc=1
    assert_contains "$(printf '%s\n' "$out" | _prf_item HUMANPREFIX)" '"skip": ""' \
        "and it is feedback in its own right" || rc=1

    _prf_teardown
    return $rc
}

test_pr_feedback_reads_a_summary_from_either_review_lane() {
    _prf_setup
    local rc=0 out
    # Two lanes, one login, two summary markers of the same shape. Until PR #37
    # this matched the literal "<!-- review-pr ", so the Cursor lane's summary
    # fell through to `human` — a machine verdict routed to the path where a
    # worker asks a clarifying question and waits for an answer nobody will send.
    /bin/cat > "$MOCK_GH_DIR/reviews.json" <<'EOF'
[[{"id": 800, "submitted_at": "2026-09-01T10:30:00Z", "state": "COMMENTED",
   "user": {"login": "amarcu", "type": "User"},
   "html_url": "https://github.com/acme/testrepo/pull/7#r800",
   "body": "<!-- review-pr repo=acme/testrepo pr=7 round=1 head=abc1234 verdict=changes-needed gate=passed -->\nCLAUDEVERDICT one blocker."},
  {"id": 801, "submitted_at": "2026-09-01T11:30:00Z", "state": "COMMENTED",
   "user": {"login": "amarcu", "type": "User"},
   "html_url": "https://github.com/acme/testrepo/pull/7#r801",
   "body": "<!-- cursor-review repo=acme/testrepo pr=7 round=1 head=abc1234 model=grok verdict=changes-needed request_id=r1 -->\nCURSORVERDICT two majors."}]]
EOF

    out=$(_prf_run) || rc=1

    local claude cursor
    claude=$(printf '%s\n' "$out" | _prf_item CLAUDEVERDICT)
    assert_contains "$claude" '"kind": "reviewer"' "review-pr's summary is still reviewer" || rc=1
    assert_contains "$claude" '"lane": "review-pr"' "and names its lane" || rc=1
    assert_contains "$claude" '"skip": "reviewer-summary"' "context, not a thing to fix" || rc=1

    cursor=$(printf '%s\n' "$out" | _prf_item CURSORVERDICT)
    assert_contains "$cursor" '"kind": "reviewer"' "and so is cursor-review's" || rc=1
    assert_contains "$cursor" '"lane": "cursor-review"' "named as the other lane" || rc=1
    assert_contains "$cursor" '"skip": "reviewer-summary"' "on the same footing" || rc=1
    assert_not_contains "$cursor" '"kind": "human"' \
        "never human — a verdict is not a question to ask back" || rc=1

    _prf_teardown
    return $rc
}

test_pr_feedback_attributes_an_inline_finding_to_the_lane_that_raised_it() {
    _prf_setup
    local rc=0 out item
    # Both lanes write the same lane-neutral finding tag under the same login,
    # so nothing in the comment itself says who raised it. The attribution runs
    # thread -> its review -> that review's summary marker.
    _prf_threads "false" "[$(_prf_thread_node T1 src/a.ts false false \
        "$(_prf_comment 1001 amarcu 2026-09-01T10:00:00Z \
            'The CASTCANTHROW check is missing. <!-- finding:f1 severity:major round:1 -->')")]"
    /bin/cat > "$MOCK_GH_DIR/reviews.json" <<'EOF'
[[{"id": 801, "submitted_at": "2026-09-01T11:30:00Z", "state": "COMMENTED",
   "user": {"login": "amarcu", "type": "User"},
   "html_url": "https://github.com/acme/testrepo/pull/7#r801",
   "body": "<!-- cursor-review repo=acme/testrepo pr=7 round=1 head=abc1234 model=grok verdict=changes-needed request_id=r1 -->\nCURSORVERDICT one major."}]]
EOF
    /bin/cat > "$MOCK_GH_DIR/pr-comments.json" <<'EOF'
[[{"id": 1001, "pull_request_review_id": 801, "in_reply_to_id": null}]]
EOF

    out=$(_prf_run) || rc=1
    item=$(printf '%s\n' "$out" | _prf_item CASTCANTHROW)
    assert_contains "$item" '"kind": "reviewer"' "the tag still classifies it, as before" || rc=1
    assert_contains "$item" '"skip": ""' "and it is still actionable" || rc=1
    assert_contains "$item" '"finding": "f1"' "with its finding id" || rc=1
    assert_contains "$item" '"lane": "cursor-review"' \
        "now naming the reviewer the reply will answer" || rc=1

    _prf_teardown
    return $rc
}

test_pr_feedback_does_not_read_the_workers_own_summary_as_a_lane() {
    _prf_setup
    local rc=0 out item
    # The worker's own marker carries repo=, pr= and round= too. It must not
    # read as a review lane, or the skill would classify its own summary as a
    # reviewer's and answer itself.
    /bin/cat > "$MOCK_GH_DIR/issue-comments.json" <<'EOF'
[[{"id": 905, "created_at": "2026-09-01T12:00:00Z",
   "user": {"login": "amarcu", "type": "User"},
   "html_url": "https://github.com/acme/testrepo/pull/7#i905",
   "body": "Addressed in abc1234:\n\n- OWNSUMMARY renamed\n\n<!-- agentic-skills: skill=iterate-on-pr repo=acme/testrepo pr=7 round=1 sha=abc1234 addressed=1 skipped=0 routine=interactive run=none model=x -->"}]]
EOF

    out=$(_prf_run) || rc=1
    item=$(printf '%s\n' "$out" | _prf_item OWNSUMMARY)
    assert_contains "$item" '"lane": null' "the worker is not a review lane" || rc=1
    assert_contains "$item" '"kind": "human"' "and its summary is not reviewer feedback" || rc=1
    assert_contains "$item" '"skip": "own-summary"' "it is skipped as its own" || rc=1

    _prf_teardown
    return $rc
}
