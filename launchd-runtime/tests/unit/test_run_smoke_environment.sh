#!/bin/bash
# Tests for the environment tests/smoke/run-smoke.sh gives each routine.
#
# 2026-09-12: the smoke gate, started over ssh on the pipeline host, handed
# every routine the ssh session's PATH. `gh` was not on it, so morning-triage
# scanned nothing — while launchd, which sets PATH from each routine's plist,
# gave the real 04:02 run a working gh. A rehearsal in a different environment
# rehearses something else. These pin that each routine gets the PATH its own
# plist declares, and that a routine with no declared environment is refused
# rather than quietly run in the caller's.
#
# No API call: CLAUDE_CLI is a mock that records the PATH it was started with
# and prints a passing envelope.

_rse_setup() {
    RSE_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-rse.XXXXXX)
    export SMOKE_OUT_DIR="$RSE_TMP/out"
    export SMOKE_SKILLS_ROOT="$REPO_ROOT"
    export SMOKE_ENV_RECORD="$RSE_TMP/path-seen"
    export SMOKE_ENV_ENVELOPE="$RSE_TMP/envelope.json"
    "$JQ_BIN" '.result = "Scanned under ROUTINE_DRY_RUN=1.\n\nTRIAGE: run=smoke-1 repos=9 blocking=1 needs_approval=3 proposed=4 escalated=0 errors=0"' \
        "$FIXTURES_DIR/smoke-envelopes/morning-triage-pass.json" > "$SMOKE_ENV_ENVELOPE"
    /bin/cat > "$RSE_TMP/claude-cli" <<'MOCK'
#!/bin/bash
[[ "${1:-}" == "--help" ]] && exit 0
printf '%s\n' "$PATH" > "$SMOKE_ENV_RECORD"
/bin/cat "$SMOKE_ENV_ENVELOPE"
MOCK
    /bin/chmod +x "$RSE_TMP/claude-cli"
    export CLAUDE_CLI="$RSE_TMP/claude-cli"
}

_rse_teardown() {
    /bin/rm -rf "$RSE_TMP"
}

test_run_smoke_gives_each_routine_the_path_its_plist_declares() {
    _rse_setup
    local rc=0 out declared seen
    declared=$(/usr/bin/plutil -extract EnvironmentVariables.PATH raw \
        "$RUNTIME_DIR/agents/com.agentic-skills.routines.morning-triage.plist")
    # The tracked plist is a template; the smoke run fills the home in as install.sh does.
    declared="${declared//__HOME__/$HOME}"
    out=$(PATH="/usr/bin:/bin" "$RUNTIME_DIR/tests/smoke/run-smoke.sh" morning-triage 2>&1)
    assert_contains "$out" "SMOKE: morning-triage pass" "the rehearsal ran and passed" || rc=1
    assert_file_exists "$SMOKE_ENV_RECORD" "the CLI was started" || rc=1
    seen=$(/bin/cat "$SMOKE_ENV_RECORD" 2>/dev/null)
    assert_equal "$declared" "$seen" \
        "the routine got its plist's PATH, not the caller's /usr/bin:/bin" || rc=1
    _rse_teardown
    return $rc
}

test_run_smoke_refuses_a_routine_with_no_declared_environment() {
    _rse_setup
    local rc=0 out
    export SMOKE_AGENTS_DIR="$RSE_TMP/no-agents"
    /bin/mkdir -p "$SMOKE_AGENTS_DIR"
    out=$("$RUNTIME_DIR/tests/smoke/run-smoke.sh" morning-triage 2>&1)
    assert_contains "$out" "SMOKE: morning-triage FAIL" "no plist means no rehearsal" || rc=1
    assert_contains "$out" "no-routine-environment" "and the reason says why" || rc=1
    if [[ -f "$SMOKE_ENV_RECORD" ]]; then
        echo "  FAIL: the CLI was started anyway, in the caller's environment"
        rc=1
    fi
    _rse_teardown
    return $rc
}

test_run_smoke_refuses_a_plist_that_declares_no_path() {
    # plutil prints "Could not extract value" on stdout for a missing key, so a
    # check on empty output would have run the routine with that sentence as
    # its PATH.
    _rse_setup
    local rc=0 out
    export SMOKE_AGENTS_DIR="$RSE_TMP/agents"
    /bin/mkdir -p "$SMOKE_AGENTS_DIR"
    local plist="$SMOKE_AGENTS_DIR/com.agentic-skills.routines.morning-triage.plist"
    /usr/bin/plutil -create xml1 "$plist"
    /usr/bin/plutil -insert Label -string com.agentic-skills.routines.morning-triage "$plist"
    out=$("$RUNTIME_DIR/tests/smoke/run-smoke.sh" morning-triage 2>&1)
    assert_contains "$out" "no-routine-environment" "a plist with no PATH is refused" || rc=1
    if [[ -f "$SMOKE_ENV_RECORD" ]]; then
        echo "  FAIL: the CLI was started with PATH=$(/bin/cat "$SMOKE_ENV_RECORD")"
        rc=1
    fi
    _rse_teardown
    return $rc
}
