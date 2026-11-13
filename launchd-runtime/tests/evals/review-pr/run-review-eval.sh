#!/bin/bash
# Measure whether `review-pr` catches a real defect without inventing findings.
#
# Usage: run-review-eval.sh [--runs N] [--case defect|clean|both] [--model M] [--out DIR]
#
# THIS SPENDS REAL API CALLS. Like the smoke gate, it is not part of `make test`.
# `make test` runs the graders against recorded runs instead, which costs nothing.
#
# Why it exists: `review-pr` is the nightly quality gate on every worker pull
# request, and nothing measured its judgment (issue #46). A quiet miss lets bad
# code through; an invented finding costs an `iterate-on-pr` round. `claude
# plugin eval` could not host it — no GitHub login in its sandbox, and the
# with/without comparison is meaningless for a slash-invoked skill — so this
# runs the real skill headlessly against a fixture pull request instead.
#
# What is real: the `claude -p` invocation, the skill, `pr-review-bundle`, the
# repository's verify gate, and the review that gets posted.
# What is not: GitHub. A recording `gh` sits first on `PATH` and answers from
# `routes.tsv`; `GH_CONFIG_DIR` points at an empty directory and `GH_TOKEN` is
# cleared, so a real `gh` reached around it cannot authenticate. The fixture
# repository is seeded per run under the run directory.
#
# The bar each case must clear is `expectations.md`, written before the first
# run. The graders are `grade.py`, which reads the `REVIEW:` line and the
# recorded `gh` calls — never whether the final message reads well.
set -u

HERE=$(cd "$(/usr/bin/dirname "$0")" && pwd)
EVALS_DIR=$(cd "$HERE/.." && pwd)
RUNTIME_DIR=$(cd "$EVALS_DIR/../.." && pwd)
REPO_ROOT=$(cd "$RUNTIME_DIR/.." && pwd)

RUNS=3
CASES="defect clean"
MODEL="${REVIEW_EVAL_MODEL:-claude-sonnet-5}"
EFFORT="${REVIEW_EVAL_EFFORT:-high}"
BUDGET_USD="${REVIEW_EVAL_MAX_BUDGET_USD:-2.00}"
TIMEOUT_SECONDS="${REVIEW_EVAL_TIMEOUT:-900}"
OUT_DIR="$EVALS_DIR/out/review-pr-$(/bin/date +%Y%m%d-%H%M%S)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runs)  RUNS="$2"; shift 2 ;;
        --case)  CASES=$([[ "$2" == "both" ]] && echo "defect clean" || echo "$2"); shift 2 ;;
        --model) MODEL="$2"; shift 2 ;;
        --out)   OUT_DIR="$2"; shift 2 ;;
        -h|--help) /usr/bin/sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "run-review-eval.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done

JQ="${JQ_BIN:-$(command -v jq || echo /opt/homebrew/bin/jq)}"
[[ -x "$JQ" ]] || { echo "ABORT — jq not found" >&2; exit 5; }
CLAUDE_CLI="${CLAUDE_CLI:-$(command -v claude)}"
[[ -x "${CLAUDE_CLI:-}" ]] || { echo "ABORT — claude CLI not found" >&2; exit 5; }

DENY_FILE="$RUNTIME_DIR/bin/headless-deny.sh"
[[ -r "$DENY_FILE" ]] || { echo "ABORT — deny-net not readable: $DENY_FILE" >&2; exit 5; }
# shellcheck source=../../bin/headless-deny.sh
. "$DENY_FILE"
[[ -n "${HEADLESS_DENY:-}" ]] || { echo "ABORT — $DENY_FILE set no HEADLESS_DENY" >&2; exit 5; }

/bin/mkdir -p "$OUT_DIR"
echo "review-pr eval — $RUNS run(s) per case [$CASES], model $MODEL, budget \$$BUDGET_USD each"
echo "out: $OUT_DIR"
echo

TOTAL_COST=0
RUN_COUNT=0

for case_name in $CASES; do
    case "$case_name" in
        defect) branch="task/issue-7-cap-charge" ;;
        clean)  branch="task/issue-7-cap-charge-clean" ;;
        *) echo "ABORT — case is defect or clean, got $case_name" >&2; exit 2 ;;
    esac

    for run in $(/usr/bin/seq 1 "$RUNS"); do
        run_dir="$OUT_DIR/$case_name-$run"
        /bin/mkdir -p "$run_dir/case" "$run_dir/gh-config"

        # A fresh repository per run: the skill's gate runs in it, and a run
        # must never inherit what an earlier one left behind.
        shas=$("$HERE/seed-repo.sh" "$run_dir/repo") || { echo "ABORT — seeding failed" >&2; exit 5; }
        base=$(echo "$shas" | /usr/bin/awk '{print $1}')
        head=$(echo "$shas" | /usr/bin/awk -v c="$case_name" '{print (c == "defect" ? $2 : $3)}')

        /usr/bin/python3 "$HERE/render-case.py" "$run_dir/case" "$run_dir/repo" \
            "$branch" "$base" "$head" > /dev/null || { echo "ABORT — rendering failed" >&2; exit 5; }

        /bin/cat > "$run_dir/repos.conf" <<CONF
ACTIVE_REPOS=("acme/evalrepo")
REPOS_BY_PRIORITY=("acme/evalrepo")
DISPATCH_PER_REPO_MAX=2
REVIEW_ROUND_MAX=3
REVIEW_NEW_FINDINGS_BY_ROUND=(5 2 0)
REVIEW_FINDINGS_MAX=7
get_repo_path() {
    case "\$1" in
        acme/evalrepo) echo "$run_dir/repo" ;;
        *)               echo "" ;;
    esac
}
get_driver() { echo ""; }
CONF

        settings=$("$JQ" -nc --argjson base "$HEADLESS_DENY" \
            --arg log "$run_dir/gh.log" --arg routes "$run_dir/case/routes.tsv" \
            --arg reviews "$run_dir/case/reviews.json" --arg comments "$run_dir/case/comments.json" \
            --arg conf "$run_dir/repos.conf" \
            --arg ghconf "$run_dir/gh-config" --arg jq "$JQ" \
            '{permissions: {deny: $base.permissions.deny},
              env: {EVAL_GH_LOG: $log, EVAL_GH_ROUTES: $routes, EVAL_REVIEWS_FILE: $reviews,
                    EVAL_COMMENTS_FILE: $comments,
                    EVAL_JQ: $jq, REPOS_CONF: $conf, GH_CONFIG_DIR: $ghconf, GH_TOKEN: "",
                    GITHUB_TOKEN: "", TELEGRAM_BOT_TOKEN: "eval-not-a-real-token",
                    TELEGRAM_CHAT_ID: "eval"}}') || {
            echo "ABORT — could not build the settings document" >&2; exit 5; }

        start=$(/bin/date +%s)
        (
            set -m
            cd "$run_dir" && \
            ROUTINE="pr-review-night" \
            ROUTINE_RUN_ID="review-eval-$case_name-$run-$(/bin/date +%s)" \
            EVAL_GH_LOG="$run_dir/gh.log" \
            EVAL_GH_ROUTES="$run_dir/case/routes.tsv" \
            EVAL_REVIEWS_FILE="$run_dir/case/reviews.json" \
            EVAL_COMMENTS_FILE="$run_dir/case/comments.json" \
            EVAL_JQ="$JQ" \
            REPOS_CONF="$run_dir/repos.conf" \
            GH_CONFIG_DIR="$run_dir/gh-config" \
            GH_TOKEN="" GITHUB_TOKEN="" \
            PATH="$EVALS_DIR/bin:$PATH" \
            "$CLAUDE_CLI" \
                -p "/review-pr 7 --repo acme/evalrepo" \
                --dangerously-skip-permissions \
                --settings "$settings" \
                --effort "$EFFORT" \
                --model "$MODEL" \
                --max-budget-usd "$BUDGET_USD" \
                --output-format json \
                > "$run_dir/envelope.json" 2>"$run_dir/stderr.txt"
        ) &
        cli_pid=$!
        (
            t0=$(/bin/date +%s)
            while /bin/kill -0 "$cli_pid" 2>/dev/null; do
                /bin/sleep 5
                if [[ $(( $(/bin/date +%s) - t0 )) -gt "$TIMEOUT_SECONDS" ]]; then
                    /bin/kill -TERM "$cli_pid" 2>/dev/null
                    /bin/sleep 3
                    /bin/kill -KILL "$cli_pid" 2>/dev/null
                    break
                fi
            done
        ) &
        watchdog=$!
        wait "$cli_pid"; cli_exit=$?
        /bin/kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
        duration=$(( $(/bin/date +%s) - start ))

        "$JQ" -r '.result // ""' "$run_dir/envelope.json" > "$run_dir/result.txt" 2>/dev/null || : > "$run_dir/result.txt"
        cost=$("$JQ" -r '.total_cost_usd // 0' "$run_dir/envelope.json" 2>/dev/null || echo 0)
        [[ -n "$cost" ]] || cost=0
        TOTAL_COST=$("$JQ" -n --argjson a "$TOTAL_COST" --argjson b "$cost" '$a + $b' 2>/dev/null || echo "$TOTAL_COST")

        grade=$(/usr/bin/python3 "$HERE/grade.py" "$run_dir" "$case_name" --json)
        printf '%s\n' "$grade" > "$run_dir/grade.json"
        outcome=$(printf '%s' "$grade" | "$JQ" -r '.outcome')
        verdict=$(printf '%s' "$grade" | "$JQ" -r '.verdict // "-"')
        printf 'RUN: case=%-6s run=%s outcome=%-13s verdict=%-14s %ss $%s exit=%s\n' \
            "$case_name" "$run" "$outcome" "$verdict" "$duration" "$cost" "$cli_exit"
        printf '%s' "$grade" | "$JQ" -r '.failures[]? | "     - " + .'
        RUN_COUNT=$((RUN_COUNT + 1))
    done
done

echo
echo "== report"
/usr/bin/python3 "$HERE/report.py" "$OUT_DIR"
report_status=$?
printf 'EVAL: total_cost_usd=%s runs=%d model=%s out=%s\n' \
    "$TOTAL_COST" "$RUN_COUNT" "$MODEL" "$OUT_DIR"
exit "$report_status"
