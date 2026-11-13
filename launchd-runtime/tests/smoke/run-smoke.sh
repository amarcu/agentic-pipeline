#!/bin/bash
# Headless smoke gate: run every scheduled routine the way _run.sh runs it,
# minus the mutations, and assert each one's output contract.
#
# Usage: run-smoke.sh [<routine> …]      (no argument = every routine)
#        make smoke                      (all)
#        make smoke-morning-triage       (one)
#
# THIS SPENDS REAL API CALLS. It is deliberately not part of `make test`.
#
# Why it exists: the static suite checks files. Two production outages —
# 2026-09-05/06 (`disable-model-invocation` blocking the Skill tool) and
# 2026-09-07 (a forked worker arriving with no arguments) — were invisible to
# every file-level check and would each have shown up in one headless run of
# the real prompt. This is that run.
#
# What it keeps identical to production (bin/_run.sh):
#   * the prompt file, passed as text to `claude -p`;
#   * the `--settings` deny-net, read from the same bin/headless-deny.sh;
#   * `--dangerously-skip-permissions`, `--effort`, `--model`,
#     `--max-budget-usd`, `--output-format json`;
#   * `ROUTINE` and `ROUTINE_RUN_ID` exported, and the working directory,
#     which for a LaunchAgent with no WorkingDirectory key is `/`;
#   * `PATH`, read from the routine's own plist in agents/, because launchd
#     sets it from that plist and not from whoever started this script. An ssh
#     session's PATH on the pipeline host lacks ~/.local/bin, where gh lives:
#     on 2026-09-12 that rehearsal ran morning-triage with no gh, every repo
#     errored, and the run still printed a well-formed TRIAGE: line. A routine
#     with no plist, or no PATH in it, is refused rather than run in the
#     caller's environment.
#
# What it changes, and why each one is safe to change:
#   * `ROUTINE_DRY_RUN=1` — BASELINE reads it as `--dry-run` in every skill, so
#     the run reads and decides and stops before its first mutation. This is
#     the whole read-only guarantee; the two layers below back it up.
#   * `TELEGRAM_API_URL` points at the mock server in tests/fixtures, and the
#     credentials are placeholders — both pinned in the settings document,
#     which outranks ~/.claude/settings.json's own `env`. Nothing can reach a
#     human even if a skill ignores the dry run.
#   * a smoke-only deny family on top of the production one (SMOKE_EXTRA_DENY
#     below): the GitHub and git writes no read-only rehearsal ever makes. A
#     denial fails the routine, so this is a tripwire as much as a guard.
#   * `METRICS_DIR` points into out/, so a rehearsed send never lands a row in
#     the production ledger.
#   * `--model` defaults to Sonnet (SMOKE_MODEL) and the budget to $1.50
#     (SMOKE_MAX_BUDGET_USD): a rehearsal should not cost what the night costs.
#     A skill's own `model:` frontmatter still wins in-run, as in production.
#
# Knobs: SMOKE_MODEL, SMOKE_EFFORT, SMOKE_MAX_BUDGET_USD, SMOKE_MAX_TURNS,
#        SMOKE_TIMEOUT_SECONDS, SMOKE_SKILLS_ROOT, SMOKE_SKIP_GUARD_CHECK,
#        SMOKE_OUT_DIR, SMOKE_AGENTS_DIR.

set -uo pipefail

SMOKE_DIR="$(cd "$(/usr/bin/dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SMOKE_DIR/.." && pwd)"
RUNTIME_DIR="$(cd "$TESTS_DIR/.." && pwd)"
OUT_DIR="${SMOKE_OUT_DIR:-$SMOKE_DIR/out}"
PROMPTS_DIR="$RUNTIME_DIR/prompts"
AGENTS_DIR="${SMOKE_AGENTS_DIR:-$RUNTIME_DIR/agents}"
CLAUDE_CLI="${CLAUDE_CLI:-$RUNTIME_DIR/bin/claude-cli}"

MODEL="${SMOKE_MODEL:-claude-sonnet-5}"
EFFORT="${SMOKE_EFFORT:-high}"
BUDGET_USD="${SMOKE_MAX_BUDGET_USD:-1.50}"
MAX_TURNS="${SMOKE_MAX_TURNS:-40}"
TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-900}"

# The checkout every prompt and every skill resolves through. Not this one:
# `~/.claude/skills/*` links here, and the prompts name this path for
# BASELINE.md, repos.conf and telegram-send. A smoke run from a branch drives
# the skills installed HERE, whatever branch the runner itself came from.
SKILLS_ROOT="${SMOKE_SKILLS_ROOT:-$(cd "$(/usr/bin/dirname "$0")/../../.." && pwd -P)}"

if [[ -z "${JQ:-}" ]]; then
    for _jq_candidate in /usr/bin/jq /opt/homebrew/bin/jq /usr/local/bin/jq "$HOME/.local/bin/jq"; do
        [[ -x "$_jq_candidate" ]] && { JQ="$_jq_candidate"; break; }
    done
fi
[[ -z "${JQ:-}" ]] && JQ=$(command -v jq 2>/dev/null || echo "")
if [[ -z "$JQ" ]]; then
    echo "ABORT — jq not found. Install jq or set JQ=<path>." >&2
    exit 5
fi

# ── Which routines ────────────────────────────────────────────────────────
# The prompt files ARE the roster: a routine that gets a prompt gets a smoke,
# and check-envelope.sh fails it as `unknown-routine` until someone writes down
# what its output contract is.
ROUTINES=()
if [[ $# -gt 0 ]]; then
    ROUTINES=("$@")
else
    for p in "$PROMPTS_DIR"/*.md; do
        [[ -f "$p" ]] || continue
        ROUTINES+=("$(/usr/bin/basename "$p" .md)")
    done
fi

# ── Preflight: are the INSTALLED skills dry-run aware? ────────────────────
# Fail closed. Before the contract landed, a smoke run would drive skills that
# have never heard of ROUTINE_DRY_RUN — which is not a rehearsal, it is the
# nightly pipeline, at lunchtime, against live repos.
if [[ -z "${SMOKE_SKIP_GUARD_CHECK:-}" ]]; then
    if ! /usr/bin/grep -q 'ROUTINE_DRY_RUN' "$SKILLS_ROOT/BASELINE.md" 2>/dev/null; then
        cat >&2 <<EOF
ABORT — the installed skills do not declare the dry-run contract.

  $SKILLS_ROOT/BASELINE.md has no ROUTINE_DRY_RUN section, so the skills that
  ~/.claude/skills points at would run for real. Land this branch (or check it
  out in that working copy) and try again.

  SMOKE_SKIP_GUARD_CHECK=1 bypasses this — only for a routine you have
  separately confirmed makes no writes.
EOF
        exit 4
    fi
fi

# ── Contain the one side effect that reaches a human ──────────────────────
/bin/mkdir -p "$OUT_DIR"
TG_CAPTURE="$OUT_DIR/telegram-captures.jsonl"
: > "$TG_CAPTURE"
TG_PORT=$((10000 + RANDOM % 50000))
/usr/bin/python3 "$TESTS_DIR/fixtures/mock-telegram-server.py" "$TG_PORT" "$TG_CAPTURE" \
    > "$OUT_DIR/mock-telegram.log" 2>&1 &
TG_PID=$!
TG_UP=no
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if /usr/bin/nc -z localhost "$TG_PORT" 2>/dev/null; then TG_UP=yes; break; fi
    /bin/sleep 0.2
done
if [[ "$TG_UP" != yes ]]; then
    # Fail closed: without the mock, a routine's send goes to the real bot and
    # the human gets a rehearsal digest at whatever hour this was run.
    /bin/kill "$TG_PID" 2>/dev/null
    echo "ABORT — mock Telegram server did not come up on port $TG_PORT" >&2
    exit 5
fi
cleanup() { /bin/kill "$TG_PID" 2>/dev/null; }
trap cleanup EXIT INT TERM

export TELEGRAM_API_URL="http://localhost:$TG_PORT"
export METRICS_DIR="$OUT_DIR"
export ROUTINE_DRY_RUN=1

# ── The settings the CLI is launched with ─────────────────────────────────
# Fail closed on a deny-net that will not load, exactly as _run.sh does:
# `set -u` without `set -e` would otherwise carry an unreadable file all the
# way to an unbound-variable error with nothing pointing at the cause.
DENY_FILE="$RUNTIME_DIR/bin/headless-deny.sh"
if [[ ! -r "$DENY_FILE" ]]; then
    echo "ABORT — deny-net not readable: $DENY_FILE" >&2
    exit 5
fi
. "$DENY_FILE"
if [[ -z "${HEADLESS_DENY:-}" ]]; then
    echo "ABORT — $DENY_FILE set no HEADLESS_DENY" >&2
    exit 5
fi

# Smoke-only, on top of the production deny-net. None of these is a read path,
# so none of them can fire during an honest dry run — which is the point: if
# one fires, the routine reached for a mutation and the run fails naming it.
SMOKE_EXTRA_DENY='[
"Bash(gh issue create:*)",
"Bash(gh issue edit:*)",
"Bash(gh issue comment:*)",
"Bash(gh issue close:*)",
"Bash(gh issue reopen:*)",
"Bash(gh pr create:*)",
"Bash(gh pr edit:*)",
"Bash(gh pr comment:*)",
"Bash(gh pr review:*)",
"Bash(gh label create:*)",
"Bash(gh label edit:*)",
"Bash(git push:*)",
"Bash(git commit:*)"
]'

# The credentials go in the settings document, not the environment: a settings
# file's `env` block is applied to every Bash call the run makes and OUTRANKS
# what this script exports, so ~/.claude/settings.json would otherwise hand the
# routine the real bot token back (measured, 2026-09-07 — the first smoke run
# reached the mock with the live token in the URL). Placeholders here mean a
# rehearsal cannot authenticate a send even if it ignores TELEGRAM_API_URL.
SMOKE_SETTINGS=$("$JQ" -nc --argjson base "$HEADLESS_DENY" --argjson extra "$SMOKE_EXTRA_DENY" \
    --arg api "$TELEGRAM_API_URL" --arg metrics "$OUT_DIR" \
    '{permissions: {deny: ($base.permissions.deny + $extra)},
      env: {TELEGRAM_BOT_TOKEN: "smoke-not-a-real-token", TELEGRAM_CHAT_ID: "smoke",
            TELEGRAM_API_URL: $api, METRICS_DIR: $metrics, ROUTINE_DRY_RUN: "1"}}') || {
    echo "ABORT — could not build the smoke settings document" >&2
    exit 5
}

# Kill a process and every descendant, bottom-up. Same shape as _run.sh's:
# a hung routine must not hang the gate, and `kill -PGID` does not reliably
# reach a CLI's grandchildren on macOS.
kill_tree() {
    local root=$1 sig=${2:-TERM}
    local pids=("$root") frontier=("$root") next=()
    while [[ ${#frontier[@]} -gt 0 ]]; do
        next=()
        for p in "${frontier[@]}"; do
            for c in $(/usr/bin/pgrep -P "$p" 2>/dev/null); do
                pids+=("$c"); next+=("$c")
            done
        done
        [[ ${#next[@]} -eq 0 ]] && break
        frontier=("${next[@]}")
    done
    for ((i=${#pids[@]}-1; i>=0; i--)); do
        /bin/kill "-$sig" "${pids[i]}" 2>/dev/null || true
    done
}

# The CLI grew and lost flags over time; --max-turns is absent from 2.1.263.
# Pass it only where it exists, rather than failing every run on an unknown
# option or silently dropping the cap the caller asked for.
TURN_ARGS=()
if "$CLAUDE_CLI" --help 2>/dev/null | /usr/bin/grep -q -- '--max-turns'; then
    TURN_ARGS=(--max-turns "$MAX_TURNS")
else
    echo "note: this CLI has no --max-turns; --max-budget-usd $BUDGET_USD is the only runaway guard"
fi

echo "smoke: model=$MODEL effort=$EFFORT budget=\$$BUDGET_USD timeout=${TIMEOUT_SECONDS}s skills=$SKILLS_ROOT"
echo "─────────────────────────────────────────────────────────────────"

FAILED=0
PASSED=0
TOTAL_COST=0

for routine in "${ROUTINES[@]}"; do
    prompt_file="$PROMPTS_DIR/$routine.md"
    envelope="$OUT_DIR/$routine.json"
    if [[ ! -f "$prompt_file" ]]; then
        echo "SMOKE: $routine FAIL 0s \$0 no-prompt-file ($prompt_file)"
        FAILED=$((FAILED + 1))
        continue
    fi

    plist="$AGENTS_DIR/com.agentic-skills.routines.$routine.plist"
    # plutil reports a missing file or key on stdout with exit 1, so the exit
    # status decides: an error message must never become the routine's PATH.
    if ! routine_path=$(/usr/bin/plutil -extract EnvironmentVariables.PATH raw "$plist" 2>/dev/null) \
       || [[ -z "$routine_path" ]]; then
        echo "SMOKE: $routine FAIL 0s \$0 no-routine-environment ($plist declares no EnvironmentVariables.PATH)"
        FAILED=$((FAILED + 1))
        continue
    fi
    # The tracked plist is a template; install.sh writes the home in. Do the same here.
    routine_path="${routine_path//__HOME__/$HOME}"

    prompt_content=$(/bin/cat "$prompt_file")
    start=$(/bin/date +%s)

    (
        set -m
        cd / && \
        ROUTINE="$routine" \
        ROUTINE_RUN_ID="smoke-$(/bin/date +%s)" \
        PATH="$routine_path" \
        "$CLAUDE_CLI" \
            -p "$prompt_content" \
            --dangerously-skip-permissions \
            --settings "$SMOKE_SETTINGS" \
            --effort "$EFFORT" \
            --model "$MODEL" \
            --max-budget-usd "$BUDGET_USD" \
            "${TURN_ARGS[@]+"${TURN_ARGS[@]}"}" \
            --output-format json \
            > "$envelope" 2>"$OUT_DIR/$routine.stderr"
    ) &
    cli_pid=$!

    # Wall-clock watchdog: `sleep` pauses across a macOS sleep, `date +%s` does
    # not — the same reason _run.sh polls instead of sleeping the budget.
    (
        t0=$(/bin/date +%s)
        while /bin/kill -0 "$cli_pid" 2>/dev/null; do
            /bin/sleep 5
            if [[ $(( $(/bin/date +%s) - t0 )) -gt "$TIMEOUT_SECONDS" ]]; then
                kill_tree "$cli_pid" TERM
                /bin/sleep 3
                /bin/kill -0 "$cli_pid" 2>/dev/null && kill_tree "$cli_pid" KILL
                break
            fi
        done
    ) &
    watchdog_pid=$!

    wait "$cli_pid"
    cli_exit=$?
    /bin/kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null

    duration=$(( $(/bin/date +%s) - start ))
    cost=$("$JQ" -r '.total_cost_usd // 0' "$envelope" 2>/dev/null || echo 0)
    [[ -n "$cost" ]] || cost=0
    TOTAL_COST=$("$JQ" -n --argjson a "$TOTAL_COST" --argjson b "$cost" '$a + $b' 2>/dev/null || echo "$TOTAL_COST")

    verdict=$("$SMOKE_DIR/check-envelope.sh" "$routine" "$envelope" "$cli_exit")
    if [[ "$verdict" == "pass" ]]; then
        PASSED=$((PASSED + 1))
        echo "SMOKE: $routine pass ${duration}s \$$(printf '%.2f' "$cost") -"
    else
        FAILED=$((FAILED + 1))
        echo "SMOKE: $routine FAIL ${duration}s \$$(printf '%.2f' "$cost") ${verdict#FAIL }"
    fi
done

# grep -c prints its count even when it exits 1 on no match; a `|| echo 0`
# here would append a second line and print the count as "0\n0".
sends=$(/usr/bin/grep -c '"path"' "$TG_CAPTURE" 2>/dev/null) || true
[[ -n "$sends" ]] || sends=0
echo "─────────────────────────────────────────────────────────────────"
printf 'SMOKE TOTAL: %d passed, %d failed, $%.2f, %s telegram send(s) captured (none delivered)\n' \
    "$PASSED" "$FAILED" "$TOTAL_COST" "$sends"
echo "envelopes: $OUT_DIR"

[[ "$FAILED" -eq 0 ]]
