#!/bin/bash
# Tests for launchd-runtime/bin/plan-attack — a non-Claude model attacks one
# issue's plan before anyone builds it.
#
# No network and no Cursor API: the mock cursor-agent serves a canned envelope
# and the mock gh serves the issue. What these pin is what cannot be checked by
# reading the script: that a Claude model id never reaches cursor-agent, that
# the attacker can read and never edit, that the API key travels in the
# environment and not in argv, that it works on a copy of the base branch and
# not in the checkout, and that an answer the parser cannot read fails loudly
# instead of becoming "clean".

_pa_setup() {
    PA_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-attack.XXXXXX)
    export MOCK_GH_DIR="$PA_TMP/gh"
    export MOCK_CURSOR_DIR="$PA_TMP/cursor"
    export PATH="$FIXTURES_DIR/mock-cursor-agent:$FIXTURES_DIR/mock-gh:$PATH"
    export REPOS_CONF="$PA_TMP/repos.conf"
    export CURSOR_API_KEY_FILE="$PA_TMP/api-key"
    export PLAN_ATTACK_TMPDIR="$PA_TMP/work"
    PA_BIN="$RUNTIME_DIR/bin/plan-attack"
    /bin/mkdir -p "$MOCK_GH_DIR" "$MOCK_CURSOR_DIR" "$PLAN_ATTACK_TMPDIR"

    # A real key, model or binary in the runner's environment must not reach a test.
    unset CURSOR_API_KEY CURSOR_REVIEW_MODEL CURSOR_AGENT
    PA_KEY="key_TESTSECRET_do_not_log"
    printf '%s\n' "$PA_KEY" > "$CURSOR_API_KEY_FILE"
    /bin/chmod 600 "$CURSOR_API_KEY_FILE"

    PA_REPO="$PA_TMP/checkout"
    /bin/mkdir -p "$PA_REPO/game"
    printf 'class Player {}\n' > "$PA_REPO/game/Player.cs"
    /usr/bin/git -C "$PA_REPO" init -q -b main
    /usr/bin/git -C "$PA_REPO" config user.email "test@example.com"
    /usr/bin/git -C "$PA_REPO" config user.name "test"
    /usr/bin/git -C "$PA_REPO" add game/Player.cs
    /usr/bin/git -C "$PA_REPO" -c commit.gpgsign=false commit -qm "fixture base"
    # In the checkout and not on the base branch: the attacker must not see it.
    printf 'class Uncommitted {}\n' > "$PA_REPO/game/Uncommitted.cs"

    /bin/cat > "$REPOS_CONF" <<EOF
get_repo_path() {
    case "\$1" in
        acme/game) echo "$PA_REPO" ;;
        *)         echo "" ;;
    esac
}
get_repo_base() { echo main; }
EOF

    _pa_issue 12 "## Goal
Pickups exist.

## Implementation plan (advisory)
1. Add \`Pickup.cs\` beside \`game/Player.cs\`.
2. Match a deleted pickup to its saved copy by its text.

## Acceptance criteria
- [ ] Deleting one pickup leaves another with the same text in place
"
}

_pa_teardown() {
    /bin/rm -rf "$PA_TMP"
}

# _pa_issue <number> <body>
_pa_issue() {
    "$JQ_BIN" -n --argjson n "$1" --arg body "$2" \
        '{number: $n, title: "Drop pickups", body: $body, state: "OPEN"}' > "$MOCK_GH_DIR/issue-$1.json"
}

# _pa_answer <the text cursor-agent returns as its result>
_pa_answer() {
    "$JQ_BIN" -n --arg result "$1" \
        '{type: "result", subtype: "success", is_error: false, result: $result, request_id: "req-1"}' \
        > "$MOCK_CURSOR_DIR/stdout.json"
}

_pa_run() {
    "$PA_BIN" "$@" 2>"$PA_TMP/stderr.txt"
}

PA_FINDINGS='I read issue.md and then src/game.

The second step is the problem.

```json
{"verdict": "findings", "findings": [
 {"id": "a1", "severity": "must", "target": "plan step 2",
  "claim": "Two pickups with the same text are different pickups, so matching by text deletes both.",
  "evidence": "the plan: \"by its text\"; criterion 1 says the other must stay {in place}",
  "settles": "Match by an id assigned when the pickup is created."},
 {"id": "a2", "severity": "should", "target": "plan step 1",
  "claim": "The plan names no test file.", "evidence": "", "settles": "Name the test."}
]}
```'

test_plan_attack_reports_the_findings_and_one_parsable_line() {
    _pa_setup
    local rc=0 out
    _pa_answer "$PA_FINDINGS"
    out=$(_pa_run acme/game 12)
    assert_exit 0 $? "an attack that found something is still exit 0: the verdict is the line" || rc=1
    assert_contains "$(echo "$out" | /usr/bin/tail -1)" \
        "PLAN ATTACK: repo=acme/game issue=12 model=cursor-grok-4.6-high verdict=findings findings=1/1 base=" \
        "the last line carries the verdict and the counts by severity" || rc=1
    assert_contains "$out" "a1  MUST   plan step 2" "each finding names its severity and its target" || rc=1
    assert_contains "$out" "settles:  Match by an id assigned when the pickup is created." \
        "and what would close it" || rc=1
    out=$(_pa_run acme/game 12 --json)
    assert_equal "findings 2 must" "$(echo "$out" | /usr/bin/sed '$d' | "$JQ_BIN" -r '"\(.verdict) \(.findings | length) \(.findings[0].severity)"')" \
        "--json carries the same findings, found inside the model's narration and past a brace in a string" || rc=1
    _pa_teardown
    return $rc
}

test_plan_attack_reads_and_never_edits_and_keeps_the_key_out_of_argv() {
    _pa_setup
    local rc=0 argv work
    _pa_answer '{"verdict": "clean", "findings": []}'
    assert_contains "$(_pa_run acme/game 12 --keep | /usr/bin/tail -1)" "verdict=clean findings=0/0" \
        "a clean answer is a clean verdict" || rc=1
    argv=$(/bin/cat "$MOCK_CURSOR_DIR/argv.txt")
    assert_contains "$argv" "ask" "cursor-agent is run in ask mode" || rc=1
    assert_not_contains "$argv" "--force" "never with --force" || rc=1
    assert_not_contains "$argv" "--yolo" "never with --yolo" || rc=1
    assert_not_contains "$argv" "$PA_KEY" "the API key is not an argument" || rc=1
    assert_equal "key=set" "$(/bin/cat "$MOCK_CURSOR_DIR/env.txt")" "it arrives in the environment" || rc=1
    assert_not_contains "$(/bin/cat "$PA_TMP/stderr.txt")" "$PA_KEY" "and is never printed" || rc=1
    work=$(/usr/bin/grep -A1 '^--workspace$' "$MOCK_CURSOR_DIR/argv.txt" | /usr/bin/tail -1)
    assert_contains "$work" "$PLAN_ATTACK_TMPDIR/plan-attack-acme-game-12-" \
        "the workspace is a throwaway directory, not the checkout" || rc=1
    assert_file_exists "$work/src/game/Player.cs" "holding the base branch's tree" || rc=1
    assert_equal "" "$(ls "$work/src/game/Uncommitted.cs" 2>/dev/null)" \
        "and nothing that is only in the checkout" || rc=1
    assert_contains "$(/bin/cat "$work/issue.md")" "Match a deleted pickup" "and the issue's own plan" || rc=1
    _pa_run acme/game 12 >/dev/null
    assert_equal "" "$(ls "$PLAN_ATTACK_TMPDIR" | /usr/bin/grep -v "$(/usr/bin/basename "$work")")" \
        "without --keep the workspace is removed" || rc=1
    # --ref replays the plan against the code as it was at a named commit.
    printf 'class Pickup {}\n' > "$PA_REPO/game/Pickup.cs"
    /usr/bin/git -C "$PA_REPO" add game/Pickup.cs
    /usr/bin/git -C "$PA_REPO" -c commit.gpgsign=false commit -qm "the plan, built"
    _pa_run acme/game 12 --keep --ref main~1 >/dev/null
    work=$(/usr/bin/grep -A1 '^--workspace$' "$MOCK_CURSOR_DIR/argv.txt" | /usr/bin/tail -1)
    assert_equal "" "$(ls "$work/src/game/Pickup.cs" 2>/dev/null)" \
        "--ref exports that commit, so a plan already built is attacked against the code before it" || rc=1
    _pa_run acme/game 12 --ref no-such-commit >/dev/null
    assert_exit 1 $? "and a commit the checkout does not have is exit 1" || rc=1
    _pa_teardown
    return $rc
}

test_plan_attack_refuses_a_claude_model_before_anything_is_sent() {
    _pa_setup
    local rc=0 model
    _pa_answer '{"verdict": "clean", "findings": []}'
    for model in claude-opus-5-5 claude-fable-5-2 sonnet-5 ; do
        _pa_run acme/game 12 --model "$model" >/dev/null
        assert_exit 6 $? "$model is refused" || rc=1
    done
    CURSOR_REVIEW_MODEL=claude-haiku-5-5 _pa_run acme/game 12 >/dev/null
    assert_exit 6 $? "so is one that arrives through the environment" || rc=1
    assert_equal "" "$(ls "$MOCK_CURSOR_DIR/argv.txt" 2>/dev/null)" "and cursor-agent was never called" || rc=1
    _pa_teardown
    return $rc
}

test_plan_attack_never_turns_an_unreadable_answer_into_clean() {
    _pa_setup
    local rc=0 out
    _pa_answer "Looks solid to me, I would go ahead with this plan."
    out=$(_pa_run acme/game 12)
    assert_exit 8 $? "prose with no verdict is exit 8" || rc=1
    assert_not_contains "$out" "PLAN ATTACK:" "and no verdict line is printed" || rc=1
    _pa_answer '{"verdict": "clean", "findings": [{"id": "a1", "severity": "must", "target": "step 1", "claim": "It breaks."}]}'
    _pa_run acme/game 12 >/dev/null
    assert_exit 8 $? "a clean verdict carrying a finding is not an answer" || rc=1
    _pa_answer '{"verdict": "findings", "findings": [{"severity": "nit", "claim": "Rename it."}]}'
    _pa_run acme/game 12 >/dev/null
    assert_exit 8 $? "nor is a findings verdict with no finding of a known severity" || rc=1
    /bin/rm -f "$MOCK_CURSOR_DIR/stdout.json"
    _pa_run acme/game 12 >/dev/null
    assert_exit 8 $? "and a cursor-agent that fails is exit 8" || rc=1
    _pa_teardown
    return $rc
}

test_plan_attack_refuses_what_it_cannot_attack_or_place() {
    _pa_setup
    local rc=0
    _pa_issue 13 "## Goal
A hand-filed issue with no plan."
    _pa_run acme/game 13 >/dev/null
    assert_exit 4 $? "an issue with no plan is exit 4" || rc=1
    assert_contains "$(/bin/cat "$PA_TMP/stderr.txt")" "nothing to attack" "and says so" || rc=1
    _pa_run acme/unknown 12 >/dev/null
    assert_exit 2 $? "a repo outside the map is refused, never searched for" || rc=1
    _pa_run acme/game >/dev/null
    assert_exit 2 $? "a missing issue number is a usage error" || rc=1
    _pa_run acme/game 99 >/dev/null
    assert_exit 1 $? "an issue gh cannot show is exit 1" || rc=1
    /bin/chmod 644 "$CURSOR_API_KEY_FILE"
    _pa_run acme/game 12 >/dev/null
    assert_exit 5 $? "a key file others can read is refused" || rc=1
    assert_equal "" "$(ls "$MOCK_CURSOR_DIR/argv.txt" 2>/dev/null)" "and none of these reached cursor-agent" || rc=1
    _pa_teardown
    return $rc
}

test_plan_attack_dry_run_builds_the_workspace_and_calls_nothing() {
    _pa_setup
    local rc=0 out
    /bin/rm -f "$CURSOR_API_KEY_FILE"
    out=$(_pa_run acme/game 12 --dry-run)
    assert_exit 0 $? "a dry run needs no key and exits 0" || rc=1
    assert_contains "$out" "dry run: cursor-agent is not invoked" "it says what it did not do" || rc=1
    assert_equal "" "$(ls "$MOCK_CURSOR_DIR/argv.txt" 2>/dev/null)" "and cursor-agent was not called" || rc=1
    _pa_teardown
    return $rc
}
