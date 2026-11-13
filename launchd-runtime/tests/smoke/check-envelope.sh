#!/bin/bash
# Judge one smoke run from the JSON envelope `claude -p --output-format json`
# wrote for it.
#
# Usage: check-envelope.sh <routine> <envelope.json> [<cli-exit-code>]
#
# Prints one word — `pass` — or `FAIL` followed by the reason, and exits 0 or 1.
# Separate from run-smoke.sh so `make test` can exercise every verdict against
# fixture envelopes without spending an API call: the checker is the part with
# the logic in it, and an unchecked checker is how a green smoke means nothing.
#
# What a run has to show for itself:
#   * the CLI exited 0 and the envelope does not say `is_error`;
#   * nothing was denied — under the smoke's dry run a routine reads and
#     decides, so a denial means it reached for a mutation it should not have;
#   * `result` carries the routine's output-contract line. In `-p` mode that
#     field IS the run's last word, so a contract line missing from it is a
#     contract line the log would not have either;
#   * `result` carries neither of the two signatures we have already been
#     bitten by (see SIGNATURES below).

set -uo pipefail

ROUTINE="${1:-}"
ENVELOPE="${2:-}"
CLI_EXIT="${3:-0}"

if [[ -z "$ROUTINE" || -z "$ENVELOPE" ]]; then
    echo "usage: $0 <routine> <envelope.json> [<cli-exit-code>]" >&2
    exit 2
fi

# Same resolution order as _run.sh and tests/helpers.sh: the candidate list
# first, PATH only as a fallback. macOS before 15 has no /usr/bin/jq.
if [[ -z "${JQ:-}" ]]; then
    for _jq_candidate in /usr/bin/jq /opt/homebrew/bin/jq /usr/local/bin/jq "$HOME/.local/bin/jq"; do
        [[ -x "$_jq_candidate" ]] && { JQ="$_jq_candidate"; break; }
    done
fi
[[ -z "${JQ:-}" ]] && JQ=$(command -v jq 2>/dev/null || echo "")
if [[ -z "$JQ" ]]; then
    echo "FAIL jq-not-found (set JQ=<path>)"
    exit 1
fi

fail() { echo "FAIL $*"; exit 1; }

# ── The two failure signatures we have already paid for ───────────────────
#
# "disable-model-invocation": the 2026-09-05/06 outage. Every routine whose
# prompt says "run the /skill" halted, because that frontmatter flag blocks the
# Skill tool — the one path a headless run reaches a skill through. The model
# says the phrase out loud when it happens ("the Skill tool refuses to run it,
# disable-model-invocation is set"), which is what makes it greppable.
#
# "don't have an issue number": the 2026-09-07 outage. dispatch forked
# work-on-task and the fork arrived with no arguments, so the worker reported
# it had no issue to work. Both are model prose, not fields — matched
# case-insensitively, on the shortest stable fragment.
SIGNATURES=("disable-model-invocation" "don't have an issue number")

[[ -f "$ENVELOPE" ]] || fail "no-envelope ($ENVELOPE)"
"$JQ" -e . "$ENVELOPE" > /dev/null 2>&1 || fail "envelope-unparseable"

[[ "$CLI_EXIT" -eq 0 ]] || fail "cli-exit=$CLI_EXIT"

is_error=$("$JQ" -r '.is_error // false' "$ENVELOPE")
if [[ "$is_error" == "true" ]]; then
    subtype=$("$JQ" -r '.subtype // "-"' "$ENVELOPE")
    fail "is_error subtype=$subtype"
fi

denials=$("$JQ" -r '(.permission_denials // []) | length' "$ENVELOPE")
if [[ "$denials" -gt 0 ]]; then
    # Name the first one: "3 denials" sends you to the envelope, the tool name
    # sends you to the step that reached for it.
    first=$("$JQ" -r '(.permission_denials // [])[0]
                      | (.tool_name // .toolName // "?") as $t
                      | ($t + " " + ((.tool_input // .toolInput // {}) | tojson | .[0:80]))' "$ENVELOPE")
    fail "permission_denials=$denials first=$first"
fi

result=$("$JQ" -r '.result // ""' "$ENVELOPE")
[[ -n "${result// /}" ]] || fail "empty-result"

for sig in "${SIGNATURES[@]}"; do
    if printf '%s' "$result" | /usr/bin/grep -qiF -- "$sig"; then
        fail "known-signature:\"$sig\""
    fi
done

# ── Per-routine output contract ───────────────────────────────────────────
#
# What each routine's final message owes lives in bin/routine-contracts.tsv, the
# same table the runner warns from, so the two cannot disagree (#52). A routine
# with no row fails here: a new prompt file joins `make smoke` automatically and
# stays red until someone writes down what it is supposed to print.
# Anchored, not a substring search: the model narrates, and prose like "no
# TRIAGE: line was printed" contains the token. The contract line has to start
# a line of its own (leading whitespace tolerated — a digest may indent it).
has() { printf '%s' "$result" | /usr/bin/grep -qE -- "^[[:space:]]*($1)"; }

CONTRACTS="${ROUTINE_CONTRACTS_FILE:-$(cd "$(/usr/bin/dirname "$0")/../../bin" && pwd)/routine-contracts.tsv}"
rows=$(LC_ALL=C /usr/bin/awk -F'\t' -v r="$ROUTINE" '$1 == r {print $2}' "$CONTRACTS" 2>/dev/null)
[[ -n "$rows" ]] || fail "unknown-routine (no contract defined)"
while IFS= read -r group; do
    [[ "$group" == "-" ]] && continue
    has "$group" || fail "no ${group//|/ or } line in result"
done <<< "$rows"

# Two routines owe more than a line, and those rules need the line's content.
case "$ROUTINE" in
    morning-triage)
        # A scan in which every repo errored reports zero of everything, which
        # reads as a quiet day. 2026-09-12: a rehearsal with no gh on PATH saw
        # all seven repos come back as ERROR: and still printed this line.
        triage=$(printf '%s' "$result" | /usr/bin/grep -m1 -E '^[[:space:]]*TRIAGE:')
        repos=$(printf '%s' "$triage" | /usr/bin/sed -n 's/.* repos=\([0-9][0-9]*\).*/\1/p')
        errors=$(printf '%s' "$triage" | /usr/bin/sed -n 's/.* errors=\([0-9][0-9]*\).*/\1/p')
        [[ -n "$errors" ]] || fail "TRIAGE: line has no errors= count"
        if [[ -n "$repos" && "$repos" -gt 0 && "$errors" -ge "$repos" ]]; then
            fail "every repo errored (errors=$errors of repos=$repos) — the scan saw nothing"
        fi
        ;;
    dispatch-tasks-night)
        # The gate line names the repos with a free slot. When it named one,
        # the run had a worker to fork, and the worker's own line is the only
        # evidence that the fork carried its arguments — the 2026-09-07 bug
        # lives in exactly that hand-off and is invisible to a check that
        # stops at the dispatcher's own output.
        eligible=$(printf '%s' "$result" \
            | /usr/bin/sed -n 's/.*DISPATCH GATE:.*eligible=\([^ ]*\).*/\1/p' | /usr/bin/head -1)
        if [[ -n "$eligible" && "$eligible" != "-" ]]; then
            has "WORK:|PLANNED:" \
                || fail "gate had eligible=$eligible but no WORK:/PLANNED: line from a worker"
        fi
        ;;
esac

echo "pass"
