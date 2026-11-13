#!/bin/bash
# merge-permissions.sh merges the shared baseline into a Claude Code settings
# file. Allow rules are unioned, so withdrawing an unsafe rule from the baseline
# does nothing on a machine that already merged it — _removeFromAllow is what
# makes a withdrawal actually take effect. Would have caught: shipping
# Bash(rm *.log), which reaches the 580 routine logs that exist in one copy.

MERGE_BIN="$REPO_ROOT/permissions/bin/merge-permissions.sh"

_mk_settings() {
    # $1 = destination path; writes a settings file that already carries the
    # withdrawn rule, plus unrelated config that must survive the merge.
    /bin/cat > "$1" <<'JSON'
{
  "permissions": {
    "allow": ["Bash(rm *.log)", "Bash(rm -f *.log)", "Bash(ls:*)"],
    "deny": ["Bash(rm *.env*)"]
  },
  "hooks": {"SessionStart": [{"matcher": "*", "hooks": [{"type": "command", "command": "echo keepme"}]}]}
}
JSON
}

test_merge_withdraws_an_unsafe_allow_from_an_already_merged_machine() {
    local tmp; tmp=$(/usr/bin/mktemp -d /tmp/agentic-perm.XXXXXX)
    local s="$tmp/settings.json"
    _mk_settings "$s"

    "$MERGE_BIN" "$s" > "$tmp/out.txt" 2>&1
    local rc=0

    local left
    left=$("$JQ_BIN" -r '[.permissions.allow[] | select(test("rm .\\*\\.log|rm -f .\\*\\.log"))] | length' "$s")
    assert_equal "0" "$left" "withdrawn log rules removed from allow" || rc=1
    assert_contains "$(/bin/cat "$tmp/out.txt")" "removed unsafe allow" "removal is reported" || rc=1

    # A withdrawal must not take unrelated rules or other config with it.
    assert_equal "true" "$("$JQ_BIN" -r '(.permissions.allow | index("Bash(ls:*)")) != null' "$s")" "unrelated allow kept" || rc=1
    assert_equal "true" "$("$JQ_BIN" -r '(.permissions.deny  | index("Bash(rm *.env*)")) != null' "$s")" "existing deny kept" || rc=1
    assert_equal "true" "$("$JQ_BIN" -r '.hooks.SessionStart != null' "$s")" "unrelated config kept" || rc=1

    return $rc
}

test_merge_is_idempotent_and_backs_up() {
    local tmp; tmp=$(/usr/bin/mktemp -d /tmp/agentic-perm.XXXXXX)
    local s="$tmp/settings.json"
    _mk_settings "$s"

    "$MERGE_BIN" "$s" > /dev/null 2>&1
    local first; first=$("$JQ_BIN" -S -c '.permissions' "$s")
    "$MERGE_BIN" "$s" > /dev/null 2>&1
    local second; second=$("$JQ_BIN" -S -c '.permissions' "$s")

    local rc=0
    assert_equal "$first" "$second" "second merge changes nothing" || rc=1
    # The backup is the only undo path, so its absence is a failure in itself.
    if ! /bin/ls "$s".bak-* > /dev/null 2>&1; then
        echo "  FAIL: no timestamped backup written"
        rc=1
    fi
    return $rc
}

test_baseline_ships_no_rule_that_reaches_the_routine_logs() {
    # The routine logs are the only record of every run and exist in one copy.
    # No allow rule may name .log at all.
    local hits
    hits=$("$JQ_BIN" -r '[.permissions.allow[] | select(test("\\.log"))] | join(", ")' \
           "$REPO_ROOT/permissions/interactive-baseline.json")
    if [[ -n "$hits" ]]; then
        echo "  FAIL: baseline allows deletion of .log files: $hits"
        return 1
    fi
    return 0
}

test_merge_installs_the_hook_once_and_keeps_other_hooks() {
    local tmp; tmp=$(/usr/bin/mktemp -d /tmp/agentic-perm.XXXXXX)
    local s="$tmp/settings.json"
    /bin/cat > "$s" <<'JSON'
{
  "permissions": {"allow": [], "deny": []},
  "hooks": {"SessionStart": [{"matcher": "*", "hooks": [{"type": "command", "command": "echo keepme"}]}]}
}
JSON

    "$MERGE_BIN" "$s" > /dev/null 2>&1
    "$MERGE_BIN" "$s" > /dev/null 2>&1   # second run must not duplicate

    local rc=0
    assert_equal "1" "$("$JQ_BIN" -r '.hooks.PreToolUse | length' "$s")" \
        "one PreToolUse entry after two merges" || rc=1
    assert_equal "Bash" "$("$JQ_BIN" -r '.hooks.PreToolUse[0].matcher' "$s")" \
        "hook matches the Bash tool" || rc=1
    assert_contains "$("$JQ_BIN" -r '.hooks.PreToolUse[0].hooks[0].command' "$s")" \
        "protected-paths-hook" "hook points at the path resolver" || rc=1
    # Installing our hook must not evict anyone else's.
    assert_equal "true" "$("$JQ_BIN" -r '.hooks.SessionStart != null' "$s")" \
        "pre-existing SessionStart hook kept" || rc=1
    return $rc
}
