#!/bin/bash
# Tests for launchd-runtime/bin/agent-prs — the one predicate the review and
# iterate lanes use to tell an agent's PR from the human's. Every PR posts under
# the same account, so a wrong predicate means the pipeline pushes commits onto
# the human's branches, which is what it did on 2026-09-26 (GameTwo #99, #158).

_ap_setup() {
    AP_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-agentprs.XXXXXX)
    export MOCK_GH_DIR="$AP_TMP/gh"
    export PATH="$FIXTURES_DIR/mock-gh:$PATH"
    export JQ_BIN
    /bin/mkdir -p "$MOCK_GH_DIR"
    /bin/cat > "$MOCK_GH_DIR/pr-list.json" <<'JSON'
[
 {"number": 99,  "headRefName": "sim/measurement-record",     "isDraft": true,  "updatedAt": "2026-09-20T09:00:00Z"},
 {"number": 158, "headRefName": "tools/upgrade-lobby",        "isDraft": true,  "updatedAt": "2026-09-19T09:00:00Z"},
 {"number": 49,  "headRefName": "task/issue-45-sessionlog", "isDraft": true,  "updatedAt": "2026-09-12T09:00:00Z"},
 {"number": 16,  "headRefName": "worktree-issue-9",           "isDraft": true,  "updatedAt": "2026-06-01T09:00:00Z"},
 {"number": 60,  "headRefName": "task/issue-61-hud",          "isDraft": false, "updatedAt": "2026-09-22T09:00:00Z"},
 {"number": 70,  "headRefName": "fix/task/issue-3-lookalike", "isDraft": true,  "updatedAt": "2026-09-23T09:00:00Z"}
]
JSON
}

_ap_teardown() {
    /bin/rm -rf "$AP_TMP"
}

test_agent_prs_lists_only_what_agents_shipped() {
    _ap_setup
    local rc=0 out
    out=$("$RUNTIME_DIR/bin/agent-prs" acme/game)
    assert_exit 0 $? "the listing succeeds" || rc=1
    assert_equal "16 49 60" "$(printf '%s\n' "$out" | /usr/bin/cut -f1 | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')" \
        "agent branches only, oldest first" || rc=1
    assert_not_contains "$out" "sim/measurement-record" "the human's own draft is never listed" || rc=1
    assert_not_contains "$out" "lookalike" "the prefix must start the branch name" || rc=1
    _ap_teardown
    return $rc
}

test_agent_prs_narrows_to_drafts_on_request() {
    _ap_setup
    local rc=0 out
    out=$("$RUNTIME_DIR/bin/agent-prs" acme/game --draft-only)
    assert_equal "16 49" "$(printf '%s\n' "$out" | /usr/bin/cut -f1 | /usr/bin/tr '\n' ' ' | /usr/bin/sed 's/ $//')" \
        "a PR the human marked ready is left alone" || rc=1
    _ap_teardown
    return $rc
}

test_agent_prs_fails_loudly_when_it_cannot_list() {
    # An empty answer would read as "no agent PRs tonight"; a failed query must not.
    _ap_setup
    local rc=0 status=0
    /bin/rm -f "$MOCK_GH_DIR/pr-list.json"
    "$RUNTIME_DIR/bin/agent-prs" acme/game >/dev/null 2>&1 || status=$?
    assert_equal "1" "$status" "a failed query exits 1" || rc=1
    "$RUNTIME_DIR/bin/agent-prs" "not a repo" >/dev/null 2>&1; status=$?
    assert_equal "2" "$status" "a malformed repo is a usage error" || rc=1
    _ap_teardown
    return $rc
}
