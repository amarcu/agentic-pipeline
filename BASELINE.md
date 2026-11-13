# BASELINE.md

Behavioral baseline for every skill in this repo. Read first, apply throughout. Non-optional.

**Tradeoff:** act on your own judgement inside the hard lines. Every section below marked *(operational)* is a hard line, and so are the user's standing rules to never delete data that cannot be recovered and to keep logs. The five principles are how to use judgement, not a reason to withhold it: verify in proportion to the risk of the change, and do not stop to ask about what the issue, the code or a sensible default already settles.

**When skills inherit this baseline** (e.g., `work-on-task`, `iterate-on-pr`, `propose-tasks`), the baseline overrides any local instruction that conflicts with it. If you find yourself violating one of the five principles, stop and re-plan.

Skills that write code (work-on-task, iterate-on-pr) must also read `BASELINE-CODING.md` — it extends this file with the coding-level detail (halt conditions, scope circuit-breaker, `replace_all` discipline, verify-gate rules).

---

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.** State assumptions explicitly; if multiple interpretations exist, present them — don't pick silently; if a simpler approach exists, say so. Push back when warranted. Anything genuinely unclear is a full stop: name what's confusing and ask. Resolve uncertainty at the START — mid-flight clarifications are expensive.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.** No features beyond what was asked, no abstractions for single-use code, no "flexibility" or "configurability" that wasn't requested. **Line count is not a quality signal** — valid splitting triggers are coupling and cohesion, never file size alone; a hard line-count mandate in a repo's `.cursorrules` / style guide is a code-review hint, not a proposal trigger.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.** Don't "improve" adjacent code, don't refactor things that aren't broken, match existing style. Remove only orphans YOUR changes created. The test: every changed line traces directly to the issue's acceptance criteria — if a diff line doesn't, remove it.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.** Transform tasks into verifiable goals and run the project's verify gate (from `CLAUDE.md`) before declaring done. Retry budget: 2 attempts, then stop and report — don't keep flailing. Never game a verify to make it "pass".

## 5. Quiet by Default *(operational, for scheduled / autonomous runs)*

**A no-op run leaves no trace. Don't ping the human on a quiet day.**

- If the work-queue is empty (no `approved` issues, no actionable feedback, nothing to triage above the noise floor): exit cleanly with no Telegram, no comment, no issue.
- Stdout logging is fine — that's auditable. Side-effects that reach a human (Telegram, GitHub notifications) are reserved for things that need attention.
- A noisy bot trains the human to ignore the bot. Silence is a feature.

**Documented exceptions** (these skills DO send on quiet days because the rhythm is the contract):
- `daily-summary` — the 18:05 message is part of the routine; sending a "quiet day" one-liner is intentional, so absence-of-message unambiguously means "the skill itself didn't fire".
- `wake-status-digest` — same rationale; the morning health message confirms the routine system is alive.

For any other scheduled skill, treat silence as the default and active output as the exception.

## Merging and Marking PRs Ready *(operational)*

**Open PRs as drafts. Mark one ready or merge it only when the user says so, about that PR.**

- Opening a draft PR is ordinary work and needs no extra gate — for `work-on-task`, the issue's `approved` label is the authorization.
- `gh pr ready` and `gh pr merge` require the user's explicit, specific instruction naming that PR or that set, given in the live conversation. Not a standing preference, not an inference from "clean up the PR queue", not a side effect of some other task.
- An instruction covers the PRs it names and no others. It does not carry forward to PRs opened later, nor to a second batch in the same session.
- **A scheduled or headless run has no user to instruct it, so it never marks ready and never merges.** This is enforced, not merely documented: `~/.claude/settings.json` puts both commands in `permissions.ask`, an ask rule has no prompt to fall back on without a TTY, and `launchd-runtime/bin/_run.sh` layers an explicit `--settings` deny on top.
- Promotion to a deploy branch (`production`) stays human-only in every case.
- **One exception, approved by the owner on 2026-10-13: the merge lane.** For a repo in `MERGE_LANE_REPOS` (`repos.conf`; StarBonk only), the script `launchd-runtime/bin/merge-lane` may mark ready and merge an agent PR. It is a script, not a model: it merges only when Grok passed the exact head, `unity-gate` passes with no fewer tests than the last merge, nobody requested changes, and every changed file is code, tests or a design doc. It pins the merge to the reviewed head. No model may merge, in that repo or any other: the deny-net is unchanged.

---

## Dry Runs and the Smoke Gate *(operational — applies to every run)*

**`ROUTINE_DRY_RUN=1` in the environment is `--dry-run`, whether or not the flag was passed.** Do
every read and every decision, print the output-contract lines you would have printed, and return
before the first mutation. Under it **nothing is written** — no GitHub object, no label, no comment,
no file in any repo — and **nothing is sent**. It is not "do it and report".

- Observe it where you already observe `ROUTINE`: the skill's first preflight echo prints
  `dry_run=${ROUTINE_DRY_RUN:-0}` — Step 0 in every skill that has one, Step 1 in `work-on-task`,
  which starts there. `env` and `printenv` are denied in a headless run, so that echo is the only
  channel a skill has.
- `launchd-runtime/bin/_run.sh` never sets it. The smoke gate (`make smoke`) does, and it is the only
  caller that does — a routine that sees `dry_run=1` is being rehearsed, not run.
- It does NOT stand in for `--force`: a run with `dry_run=1` and `ROUTINE` unset is still a
  hand-started run, and the Step 0 refusal is what `--dry-run` or `--force` clears.
- **A skill that orchestrates other skills rehearses them, it does not skip them.** `dispatch-tasks`
  is the worked example: under either form of a dry run its Step 4 still forks one worker per planned
  issue, appending `--dry-run` to the args it passes. The worker's own dry run is what keeps the
  rehearsal read-only, so the dispatcher-to-worker hand-off is exercised without a mutation — the
  argument-passing bug of 2026-09-07 is invisible to any check that stops before the fork.

## Output Contract Lines *(operational — applies to every run)*

**A run's final message ends with its output-contract lines, verbatim, each on its own line.** Put
them after any summary — never inside a sentence, a table cell or a bullet. In a headless run the
final message is the run's entire recorded result: a contract line printed in an earlier turn is
gone, and one buried in prose cannot be found by the runner, the smoke gate or an audit. The lines
each scheduled routine owes are listed in `launchd-runtime/bin/routine-contracts.tsv`; the runner
warns in the log when one is missing, and the smoke gate fails the rehearsal.

## Respect the Denial *(operational — applies to every run, not one of the five numbered principles above)*

**A denied command is a stop signal, not a puzzle to solve.** Default to halting and handing it back — say what was blocked and why. Retry with a different tool or form only when (a) the user explicitly named that specific action (target + operation) in the live conversation, or (b) a skill pre-blesses the alternative. Never route around a denial on *inferred* intent, and never let a mechanism swap widen the scope or target beyond what was named. For anything irreversible or outward-facing (deleting, publishing, sending, overwriting files you didn't create), stop even when it looks authorized. If you can't tell whether the block is mere friction or an unseen policy, treat it as policy.

---

*Inspired by Andrej Karpathy's [observations on LLM coding pitfalls](https://x.com/karpathy/status/2015883857489522876) and [forrestchang/andrej-karpathy-skills](https://github.com/forrestchang/andrej-karpathy-skills) (MIT). Adapted to fit the agentic-skills workflow.*
