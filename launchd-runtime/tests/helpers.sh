#!/bin/bash
# Shared test helpers. Pure bash, no framework dependency.
# Source this file from each test_*.sh.

# Resolve test paths from $BASH_SOURCE so tests can be invoked from anywhere
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# The roster and the machine map are local files (git-ignored). A test must
# never read the real ones: every script under test takes these two overrides,
# and the suite points them at the tracked examples.
export REPOS_CONF="${REPOS_CONF_FOR_TESTS:-$RUNTIME_DIR/repos.conf.example}"
export MACHINES_CONF="${MACHINES_CONF_FOR_TESTS:-$RUNTIME_DIR/machines.conf.example}"
REPO_ROOT="$(cd "$RUNTIME_DIR/.." && pwd)"
FIXTURES_DIR="$TESTS_DIR/fixtures"

# Resolve jq the SAME WAY the runner does — the candidate list first, PATH only
# as a fallback. Not a stylistic choice: on the pipeline host (macOS 14.6.1) jq
# is at ~/.local/bin/jq, /usr/bin/jq does not exist, and a non-interactive shell
# gets PATH=/usr/bin:/bin:/usr/sbin:/sbin. So `command -v jq` finds nothing there
# and the tests fail on the one machine that actually runs the routines, while
# the runner itself works fine because it never trusted PATH.
# Keep this list in step with _run.sh's _jq_candidate loop.
if [[ -z "${JQ_BIN:-}" ]]; then
    for _jq_candidate in /usr/bin/jq /opt/homebrew/bin/jq /usr/local/bin/jq "$HOME/.local/bin/jq"; do
        if [[ -x "$_jq_candidate" ]]; then
            JQ_BIN="$_jq_candidate"
            break
        fi
    done
fi
if [[ -z "${JQ_BIN:-}" ]]; then
    JQ_BIN="$(command -v jq 2>/dev/null || true)"
fi
if [[ -z "${JQ_BIN:-}" ]]; then
    # Do not invent a path. Defaulting to /usr/bin/jq when it does not exist
    # only moves the failure somewhere less legible: every test touching JSON
    # dies with "command not found" and none of them say why. The runner
    # aborts with a distinct code in this situation (exit 5); match it.
    echo "FATAL: jq not found. Looked in /usr/bin, /opt/homebrew/bin, /usr/local/bin," >&2
    echo "       ~/.local/bin and PATH. Install jq or set JQ_BIN=<path>." >&2
    exit 5
fi
# Exported, not merely set: the mock gh applies the caller's --jq in a child
# process, and a mock that has to fall back to a bare `jq` is resolving through
# the PATH this list exists to distrust. On the pipeline host that fallback
# finds nothing, the mock answers with an empty stdout, and a script reading it
# cannot tell "no results" from "the query never ran".
export JQ_BIN

# ── Counters and result tracking ──────────────────────────────────────────
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# ── Assertion helpers ─────────────────────────────────────────────────────

assert_equal() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [[ "$expected" != "$actual" ]]; then
        echo "  ASSERT FAIL ${msg}: expected '$expected', got '$actual'"
        return 1
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  ASSERT FAIL ${msg}: expected to find '$needle' in:"
        echo "$haystack" | head -10 | sed 's/^/      /'
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  ASSERT FAIL ${msg}: did NOT expect to find '$needle' (but did)"
        return 1
    fi
}

assert_file_exists() {
    local path="$1" msg="${2:-}"
    if [[ ! -f "$path" ]]; then
        echo "  ASSERT FAIL ${msg}: file not found: $path"
        return 1
    fi
}

assert_exit() {
    local expected="$1" actual="$2" msg="${3:-}"
    if [[ "$expected" -ne "$actual" ]]; then
        echo "  ASSERT FAIL ${msg}: expected exit=$expected, got exit=$actual"
        return 1
    fi
}

assert_process_dead() {
    local pid="$1" msg="${2:-}"
    if /bin/kill -0 "$pid" 2>/dev/null; then
        echo "  ASSERT FAIL ${msg}: process $pid is still alive"
        return 1
    fi
}

# ── Test-runner internals ─────────────────────────────────────────────────

run_test() {
    local test_fn="$1"
    local name="${test_fn#test_}"
    local output_tmp=$(mktemp)
    local start_ts=$(/bin/date +%s)

    if ( "$test_fn" ) > "$output_tmp" 2>&1; then
        local elapsed=$(($(/bin/date +%s) - start_ts))
        printf "  \033[32m✓\033[0m %-60s (%ds)\n" "$name" "$elapsed"
        # A passing test that still printed something is reporting a WARN — a
        # finding it has deliberately chosen not to fail on (an unmigrated
        # skill in test_skill_contract.sh, a soft phrasing check elsewhere).
        # Swallowing it made the whole warn-don't-fail tier write-only.
        [[ -s "$output_tmp" ]] && /usr/bin/sed 's/^/      /' "$output_tmp"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        local elapsed=$(($(/bin/date +%s) - start_ts))
        printf "  \033[31m✗\033[0m %-60s (%ds)\n" "$name" "$elapsed"
        sed 's/^/      /' "$output_tmp"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$name")
    fi
    rm -f "$output_tmp"
}

# Discover and run every `test_*` function in the current shell environment
run_all_tests() {
    local fns
    fns=$(compgen -A function | /usr/bin/grep '^test_' || true)
    for fn in $fns; do
        run_test "$fn"
    done
}

print_test_summary() {
    echo
    echo "─────────────────────────────────────────────────────────────────"
    if [[ "$TESTS_FAILED" -eq 0 ]]; then
        printf "\033[32mAll %d tests passed.\033[0m\n" "$TESTS_PASSED"
        return 0
    else
        printf "\033[31m%d test(s) failed:\033[0m\n" "$TESTS_FAILED"
        for t in "${FAILED_TESTS[@]}"; do
            echo "    - $t"
        done
        printf "\033[32m%d test(s) passed.\033[0m\n" "$TESTS_PASSED"
        return 1
    fi
}

# ── Mock-environment lifecycle (only for tests that exercise _run.sh) ─────

start_mock_telegram() {
    export MOCK_TG_PORT=$((10000 + RANDOM % 50000))
    export MOCK_TG_CAPTURE="$TEST_TMP/telegram-captures.jsonl"
    export TELEGRAM_API_URL="http://localhost:$MOCK_TG_PORT"
    : > "$MOCK_TG_CAPTURE"

    /usr/bin/python3 "$FIXTURES_DIR/mock-telegram-server.py" \
        "$MOCK_TG_PORT" "$MOCK_TG_CAPTURE" \
        > "$TEST_TMP/mock-tg.log" 2>&1 &
    export MOCK_TG_PID=$!

    # Wait up to 2 seconds for the server to bind
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if /usr/bin/curl -s "$TELEGRAM_API_URL/" > /dev/null 2>&1; then
            return 0
        fi
        /bin/sleep 0.2
    done
    echo "ERROR: mock telegram server failed to bind on port $MOCK_TG_PORT"
    return 1
}

stop_mock_telegram() {
    [[ -n "${MOCK_TG_PID:-}" ]] && /bin/kill "$MOCK_TG_PID" 2>/dev/null
    wait "$MOCK_TG_PID" 2>/dev/null || true
}

# Build an isolated runtime environment for a _run.sh invocation
# Sets: TEST_TMP, ROUTINE_DIR, SETTINGS_FILE, TELEGRAM_API_URL, CLAUDE_CLI
setup_run_env() {
    export TEST_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test.XXXXXX)
    export ROUTINE_DIR="$TEST_TMP/routines"
    /bin/mkdir -p "$ROUTINE_DIR/logs"

    # Copy fixture settings to a writable location
    export SETTINGS_FILE="$TEST_TMP/settings.json"
    /bin/cp "$FIXTURES_DIR/settings/settings.json" "$SETTINGS_FILE"

    # A developer's own launchd-runtime/secrets.env must never reach a test:
    # point the runner at a file that does not exist unless the test makes one.
    export SECRETS_FILE="$TEST_TMP/no-secrets.env"

    # Default mock to "success" — individual tests override via CLAUDE_CLI
    export CLAUDE_CLI="$FIXTURES_DIR/mock-claude-cli/success"

    # Skip the runner's auth pre-flight canary by default: it spawns an
    # extra CLI call per run that most tests don't target. The canary
    # test unsets this explicitly.
    export _RUN_SKIP_AUTH_CANARY=1

    # Skip the AC-power precheck by default: the suite must pass whether
    # the host is docked or on battery (2026-07-15: the whole unit suite
    # silently aborted with exit 3 on a battery-powered run). The AC test
    # unsets this explicitly and accepts either precheck outcome.
    export _RUN_SKIP_AC_CHECK=1

    # Stage the test prompt
    /bin/cp "$FIXTURES_DIR/prompts/test-routine.prompt.md" \
            "$ROUTINE_DIR/test-routine.prompt.md"

    start_mock_telegram
}

teardown_run_env() {
    stop_mock_telegram
    /bin/rm -rf "$TEST_TMP"
}

# Run _run.sh with the current env. Captures exit + log path.
invoke_runner() {
    local routine="${1:-test-routine}"
    "$RUNTIME_DIR/bin/_run.sh" "$routine"
}

# Inspect the latest log
runner_log() {
    local routine="${1:-test-routine}"
    /bin/cat "$ROUTINE_DIR/logs/${routine}-$(/bin/date +%Y-%m-%d).log"
}

# Inspect captured Telegram payloads
captured_telegram() {
    /bin/cat "$MOCK_TG_CAPTURE" 2>/dev/null || echo ""
}

telegram_count() {
    if [[ -s "$MOCK_TG_CAPTURE" ]]; then
        /usr/bin/grep -c '"path"' "$MOCK_TG_CAPTURE" 2>/dev/null || echo 0
    else
        echo 0
    fi
}
