---
domain: universal
kind: coding
version: 1.5.0
status: active
last-assessed: 2026-09-04
---

## Purpose
The evening report on the pipeline, not only on its output. Surveys `ACTIVE_REPOS` for what shipped,
what waits on a human decision and what is stuck, then adds the state of the machine itself — how
many agent PRs are in flight against `DISPATCH_TOTAL_MAX`, which repos have hit
`DISPATCH_PER_REPO_MAX`, how many approved issues are waiting for a free slot, and how many issues
carry a `blocked:*` label — and the day's routine spend. It sends one Telegram message and writes
nothing to GitHub. It is the closing bracket of the loop that
`morning-triage` and `propose-tasks` open.

`kind: coding` rather than `readonly`: the skill only reads GitHub, but it sends Telegram, which is
a side effect a human sees. The 10 KB budget follows from that classification.

## Schedule
18:05 daily on the pipeline host, via `com.agentic-skills.routines.daily-summary-routine` and the prompt
`launchd-runtime/prompts/daily-summary-routine.md`. Host ownership is whatever
`$HOME/.agentic-skills/routines/.pipeline-host` names; the wake schedule covers it with a 17:55 pmset wake.

## Model / budget
- Model: `claude-sonnet-5` — the run lists PRs and issues, buckets them, counts them and writes
  prose. There is no code to reason about and no design decision to make, so Opus buys nothing.
- Effort: `medium` — `low` blurs the two judgement calls that matter (which draft PRs actually have
  unanswered human feedback, and what to summarise rather than enumerate); `high` would spend on
  clerical work.
- Typical run: measured at $5.24/run over the 2026-07-14 window on the old prompt, against a
  $2 median for the other read-only routines. Re-measure after the first week on this version — the
  survey is now four `gh` calls per repo instead of six and the digest rules moved out of the
  loaded context, so the previous figure is not a valid baseline.

## Dependencies
- `gh` CLI, authenticated; every repo in `ACTIVE_REPOS` readable by that account
- `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`, checked before the first `gh` call
- `launchd-runtime/repos.conf` — `ACTIVE_REPOS`, `DISPATCH_TOTAL_MAX`, `DISPATCH_PER_REPO_MAX` and
  `get_stale_days`, sourced, never mirrored
- `launchd-runtime/bin/telegram-send` — the one sender; the recipe is `notify`'s to state
- `scripts/spend-today` — optional input; absent ledgers omit the spend line rather than failing
- `iterate-on-pr`'s `Addressed in <sha>:` comment prefix, which is how a draft PR with unanswered
  feedback is detected

## Halt Conditions
- **`quiet-day`** — shipped, needs-review, ready-to-merge, in-flight, waiting and blocked are all
  zero. The one-line message is still sent: this is one of the two exceptions BASELINE Principle 5
  names, so absence of an 18:05 message means the routine did not fire, never that it had nothing
  to say. Stale items alone do not make a day active.
- **`starved`** — replaces `quiet-day` when an active repo has nothing in flight and nothing
  waiting. The message still goes out, with that repo's starved line first.
- **`missing-telegram-env` / `missing-repos-conf` / `missing-gh` / `gh-unauthenticated`** — a
  refusal. The checks run in that order, free ones first, so a run that could not have delivered
  its digest never reaches the network to discover it.
- **`github-unreachable`** — every repo's `gh` calls failed. A single repo failing is reported as
  `(error)` in the digest and the run continues.

Every halt still prints the `SUMMARY:` line last.

## Known Issues
- **The draft-PR feedback check is heuristic.** Comparing the newest human comment against the
  newest `Addressed in <sha>:` comment misses feedback left as a review thread rather than an issue
  comment, and counts a human's "thanks" as new feedback.
- **`waiting` does not distinguish deferred issues.** An approved issue with an unmet `DEPENDS ON`
  is counted as waiting like any other; the digest no longer parses the dependency grammar, so the
  reason a slot is unclaimed has to come from `dispatch-tasks`' own log.
- **Single-user assumption.** "Shipped" conflates every human's merges if more than one person
  works the same repos.
- **Spend is per routine, not per skill.** `runs.jsonl` rows are keyed by routine, so a night that
  dispatched four workers reports one figure for all of them.

## Changelog
- 2026-11-13 (v1.5.0): Step 4 is one command, `scripts/ledger-lines`, which runs `spend-today`,
  `friction` and `review-line`. The trace of the 2026-11-12 digest shows the model ran the first of
  the three listed commands and neither of the others, so two lines were missing with nothing to
  say why.
- 2026-11-12 (v1.4.0): Step 4 also runs `scripts/review-line`, and the digest gains a review line:
  of the agent PRs opened in the last seven days, how many passed every review, the median rounds
  a lane took, how many used every round, and which merged on a commit no reviewer passed. It
  reads `launchd-runtime/bin/review-rollup`, and prints nothing when GitHub does not answer.
- 2026-10-24 (v1.3.0): The digest names a **starved** repo: nothing in flight and nothing waiting,
  so tonight's dispatch has no work. From 2026-10-20 StarBonk halted on `empty-queue` five nights
  running while the digest read `waiting 0 · blocked 0`, which looks healthy. The starved line comes
  first, survives the quiet-day collapse, gives the proposed count and the fix (approve one, or
  `/plan-features`), and turns the halt into `starved`; `SUMMARY:` gains `starved=`. The friction
  line now keeps the end of a long path and adds the failed call's error, so
  `EnterWorktree "…/worktrees/issue-58" ×2: Cannot enter an existing worktree…` says what broke.
- 2026-09-13 (v1.2.0): Step 4 also runs `scripts/friction`, and the digest gains a friction line: a
  denied command or failed tool call that stopped the same routine in two or more runs this week.
  The runner now writes both to ledgers (`denials.jsonl` from the run's envelope, `tool-failures.jsonl`
  from a PostToolUseFailure hook), so a rule that keeps getting in the way reaches the human instead
  of being counted and dropped, or worked around.
- 2026-09-07: Step 0 now echoes `dry_run=${ROUTINE_DRY_RUN:-0}`, the channel the smoke gate
  (`make smoke`) reaches this skill's dry run through; `BASELINE.md` defines the contract.
- 2026-09-06: Hotfix — removed `disable-model-invocation: true`, which blocked the Skill tool and
  so halted `daily-summary-routine` on the nights of 2026-09-05 and 2026-09-06. Step 0's
  precondition list gained `interactive-run-refused`: `ROUTINE` unset with neither `--dry-run` nor
  `--force` now refuses, which is the guard the flag was standing in for. `--force` is new, and
  the `in flight` definition's rationale moved to `references/digest-format.md` for the budget.
- 2026-09-05 (v1.1): Follows `dispatch-tasks` off the weakest-link gate. The pipeline line now names
  the repos whose own in-flight count has reached `DISPATCH_PER_REPO_MAX` — `at limit <repo,repo>`,
  a segment dropped entirely on the usual day when no repo has — because with per-repo caps the
  roster total no longer describes the whole state: two repos at their limit stall those repos while
  `in flight` still reads under the ceiling, which is exactly the "stalled pipeline rendered as All
  quiet today" failure v1.0 set out to end.
- 2026-09-04 (v1.0.2): Adopted `get_stale_days` from `repos.conf` in place of the skill's own
  `STALE_DAYS = 7`. The helper landed on `main` after this skill's rewrite, and its whole point is
  that the threshold differs by workspace — the low-churn Personal Sites repos were reported stale
  every single morning at one flat number. `morning-triage` and `triage-repo` already read it, so
  `daily-summary` was the last file with a private copy, and its copy disagreed with theirs. Step 1
  now calls the function per repo and turns each distinct answer into one literal `date -v-<N>d`
  call; the stale bucket compares against that repo's own threshold. Closes the Known Issue this
  file has carried since v1.0.
- 2026-09-04 (v1.0.1): Review round on PR #20. Step 0's preconditions are now five explicit
  checks read for their exit status, each with its own halt reason and a stop before any `gh` list
  call, instead of a snippet that named reasons it never raised; `repos.conf` readability joined
  them, since Step 3 sources it. `scripts/spend-today` reads its ledgers a line at a time with
  `errors="replace"`, so the half-written UTF-8 sequence a watchdog kill can leave behind is
  skipped rather than raising `UnicodeDecodeError` over the whole day's figure, and it caps the
  named routines at the three costliest the digest format allows. Three new unit tests.
- 2026-09-03 (v1.0): Rewritten against `docs/skill-standard.md`; off
  `skill-contract-exceptions.txt`. Frontmatter now declares `disable-model-invocation: true`,
  `model: claude-sonnet-5`, `effort: medium` and prefix-scoped `allowed-tools` in place of bare
  `Bash`. **The digest now reports the pipeline, not only the repos**: a new Step 3 counts open
  agent PRs against `DISPATCH_TOTAL_MAX` (the same definition `dispatch-tasks` gates on), approved
  issues with no open PR, and issues carrying a `blocked:*` label grouped by reason — and the
  quiet-day halt fires only when those are zero too, so a stalled pipeline can no longer render as
  "All quiet today". Added an optional spend line from `runs.jsonl` and `sends.jsonl` via the new
  `scripts/spend-today`, silently omitted when the ledgers are absent. Added preconditions before
  any GitHub traffic, the `SUMMARY:` output-contract line, the S6 marker on the Telegram text, and
  a `--dry-run` that prints the digest and returns before the send. `--days` was documented but
  unused for four months and now bounds the shipped window. The two copies of the digest template
  collapsed into one, in `references/digest-format.md` with the section order and caps.
  `STALE_DAYS` is a single named constant instead of literals scattered through the body. Dropped
  the `DEPENDS ON` parsing: `blocked` is now the label, and a deferred issue counts as waiting.
- 2026-07-14 (v0.3): Efficiency pass (measured permission-denial waste). Telegram send moved to a
  literal `/tmp` heredoc plus the shared `telegram-send` (no rm/mktemp/export/chaining); repo list
  sourced from `repos.conf`; `DEPENDS ON` parsing pointed at `docs/depends-on-convention.md`;
  POSIX shell-portability note added to the comment-check loop.
- 2026-07-08 (v0.2): Assessed. Migrated the Telegram send to the canonical `notify` pattern — the
  last remaining instance of the shell-substituted curl deprecated after the 2026-05-10
  duplicate-send incident. Graduated experimental → active.
- 2026-05-08 (v0.1): Initial draft. Five-section retrospective digest with a quiet-day one-liner.
