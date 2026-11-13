---
domain: universal
kind: coding
version: 0.8.0
status: experimental
last-assessed: 2026-09-03
---

## Purpose
The project-manager skill. Dispatches approved GitHub issues to `work-on-task` one at a time, in an
order that serves driver and undriven repos before driven ones and features before chores, bounded
per repo and overall by how many open agent PRs are already waiting to be reviewed. It is the
autonomous bridge between human approval (a label added) and PR creation, and it writes no GitHub
object of its own.

## Model / budget
- Model: `claude-sonnet-5` — the dispatcher lists issues and PRs, filters them, calls one skill per
  task and composes a digest. That is bookkeeping; nothing in it needs Opus reasoning.
- Effort: `medium` — the only real judgement calls are the shape/round-robin ordering and deciding
  that three failures are systemic. `low` would blur those; `high` would spend on clerical work.
- Each worker inherits nothing from this skill. `work-on-task` declares `context: fork` alongside
  its own `model: claude-opus-4-8` and `effort: high`, and a fork was measured to run on its own
  declared model in its own context while the dispatcher resumes on Sonnet
  (`references/worker-isolation.md`, 2026-09-03).
- Typical run: ≈$0.40 for the dispatcher itself, plus each dispatched worker's own cost on top.
- **The fork isolates model and context, not spend.** `_run.sh` starts one `claude -p` with one
  `--max-budget-usd` covering the dispatcher and every worker together. `budget` — `slots` capped by
  `DISPATCH_RUN_MAX` — is what actually bounds a run's cost, and the run cap is the tighter of the
  two on most nights.
- **A fork is not a subagent for accounting.** `subagent_stats.spawned` stayed `0` across every
  probe, forks included, so per-worker cost attribution has to come from the distinct `modelUsage`
  entry each fork creates and from the run's `DISPATCH:` lines — not from `subagent_stats`.

## Configuration
Everything numeric lives in `launchd-runtime/repos.conf` (single source of truth). SKILL.md and the
routine prompts name identifiers and never restate values.

- `REPOS_BY_PRIORITY` / `ACTIVE_REPOS` / `is_active_repo` — which repos get dispatched, in what order
- `DISPATCH_TOTAL_MAX` — the global ceiling on open agent PRs; Step 2 subtracts the current count to
  get this run's `slots`. Since the per-repo cap arrived it bounds the human's total review load and
  nothing else — no single repo can reach it alone
- `DISPATCH_PER_REPO_MAX` — the same count inside one repo; Step 2 turns it into a `slots_r` per repo
  and Step 3 spends them one round at a time. A repo at its limit is skipped and blocks only itself
- `DISPATCH_RUN_MAX` — new dispatches per run, whatever the other two leave free; `budget =
  min(slots, DISPATCH_RUN_MAX)`
- `get_driver <owner/repo>` — the driver/driven relation Step 1 filters and Step 3 orders by

The caps are configuration, not arguments: there are no `--total-max` / `--per-repo-max` flags, and
the only arguments are `--repos` and `--dry-run`.

## Dependencies
- `gh` CLI, authenticated
- `launchd-runtime/bin/check-requirements` — Step 1 runs it per repo; a repo whose required
  `agent/requirements.conf` fails on this host is dropped into `unmet` and gets no worker
- `work-on-task` skill, which must **not** carry `disable-model-invocation: true` — that flag blocks
  the Skill tool and would make every dispatch a silent no-op (`references/worker-isolation.md`)
- `launchd-runtime/bin/telegram-send` for the run digest
- Target repos must have a root `CLAUDE.md`; `work-on-task` enforces it and refuses without one

## Halt Conditions (a no-op run leaves no trace)

Every halt has the same shape on stdout: the `DISPATCH GATE:` line first, then
`HALT: dispatch-tasks <reason>`, then `DISPATCH END:` last. The end line closes a halted run exactly
as it closes a dispatching one, so `DISPATCH END:` is always the final line and `HALT:` always sits
immediately before it. Halts 1 to 4 send no Telegram, having changed nothing; a systemic-failure
stop still reports whatever the workers before it changed, by Step 5's rule.

1. **Gate closed** (`gate-closed`) — **no repo is eligible**: every repo with queued work is at
   `DISPATCH_PER_REPO_MAX`, or the global `DISPATCH_TOTAL_MAX` is reached. One repo being full is
   not a halt — it is skipped and the rest of the roster still dispatches, which is the whole point
   of the per-repo cap. Above either cap is reachable, since a hand-written PR matching the agent-PR
   rule counts too. Eligibility takes all three of `budget > 0`, that repo's `slots_r > 0` and a
   queued issue, so a run whose `budget` is spent reports `eligible=-` however much per-repo room
   remains. The halt names each at-limit repo with the oldest agent PR to land in it, and — whenever
   `budget <= 0` — the oldest agent PR across the active repos as `global ceiling: land
   <owner/repo>#<n>`, because a ceiling-bound halt has an empty `at_limit` and would otherwise point
   the human nowhere. A repo Step 1 dropped on a failed requirements check — tooling absent, or a
   manifest that does not parse — contributes to this halt the same way an empty queue does — it is named in `unmet` and left out of `eligible`, never a halt of
   its own. The gate line carries the same picture:

   ```
   DISPATCH GATE: open_agent_prs=<n> cap=<N> per_repo=<P> run_max=<R> budget=<b> blocked=<k> unmet=<repo,repo|-> at_limit=<repo,repo|-> eligible=<repo,repo|->
   ```
2. **Empty queue** (`empty-queue`) — no `approved` issue anywhere without an open PR.
3. **All in progress, blocked, deferred or unanchored** (`all-blocked`) — every approved issue was
   dropped by a Step 1 filter, rather than there being none.
4. **GitHub unreachable** (`github-unreachable`) — every repo's `gh` calls failed.
5. **Systemic worker failure** (`systemic-failure`) — three consecutive `halted`/`refused` outcomes
   sharing one `gate=` value or halt reason. Stop dispatching; the digest names the pattern. A
   `dry-run` outcome is a rehearsal that worked and never counts toward it — rehearsed workers all
   carry `gate=-`, so counting them would halt every dry run at its third issue.

Per-task failures are logged and the run continues. The dispatcher never aborts a queue over one bad
task, which matters most for unattended scheduled runs.

## Known Issues
- **Two Telegram senders per run.** `work-on-task` notifies per opened PR and this skill sends a run
  digest, so a three-PR run produces four messages. Suppressing the per-PR notify belongs in
  `work-on-task`, not here.
- **No retry on transient failures.** A worker that fails on a rate limit or a moved origin is
  logged and skipped; re-run the skill to pick it up.
- **No deadline awareness.** Ordering is shape band, then round-robin, then creation date. Urgency
  is not modelled.
- **`propose-tasks` still proposes against one global backlog.** `PROPOSED_BACKLOG_MAX` counts
  unapproved `proposed` issues across the whole roster, so one repo with a fat approval queue can
  still stop proposals everywhere — the same weakest-link shape this release removed from dispatch.
  Splitting it per repo is a separate change on the proposals side.
- **Cross-repo dependencies verify "merged", not "deployed".** Where deploy-before-consume matters,
  the human must confirm deployment before approving the dependent issue.

## Status: experimental (v0.6.1)
Scheduled nightly via launchd (`com.agentic-skills.routines.dispatch-tasks-night`) since 2026-05-12.
Graduation candidate — promote to active once a non-empty-queue run is confirmed end to end with
forked workers. Watch list: whether the `blocked:`/unanchored split holds up in practice,
calibration of all three caps now that they interact, and per-worker cost attribution from
`modelUsage`.

## Changelog
- 2026-10-04 (v0.8.0): Step 3 runs `launchd-runtime/bin/jev-route` once per planned issue, in shadow.
  Jev (TypeSafe) scores how checkable, how much judgment and how broad the issue is, and the script
  suggests a model tier (sonnet, opus or fable). The line is logged with the raw answers in
  `jev-shadow.jsonl` and changes nothing; every worker still runs on `work-on-task`'s own model. The
  log can only show where a cheaper tier was too optimistic, because every worker runs on Opus; a
  small live trial has to follow before Jev chooses anything.
- 2026-09-08 (v0.7.0): Step 1 now runs `check-requirements <repo>` per repo and drops one whose
  **required** `agent/requirements.conf` fails on this host, reporting it in a new `unmet=` field on
  the gate line. On 2026-09-07 two GameTwo workers each spent a dispatch slot before finding that
  the game-engine checkout was missing and full Xcode absent; the tooling was declared nowhere, so
  the only way to discover it was to spend a worker. `unmet` is its own field rather than part of
  `blocked=` because the two count different things — `blocked` counts issues carrying a `blocked:`
  label, `unmet` names repos — and folding them would make neither readable. A repo with no
  manifest, or an `advisory` one that fails, dispatches exactly as before.

  The budget was paid structurally rather than by cutting more prose, which three rounds had already
  thinned. Step 4's rationale moved into `references/worker-isolation.md`: the "why a dry run still
  forks" paragraph, both hand-off-failure recitals (the arguments that never reached the fork, and
  the fork that ended its turn on a subagent), and the `PLANNED:` row's explanation of why a
  rehearsed worker never reaches its own `WORK:` line. Step 1's drop line now points at
  `references/queue-building.md` for the four reasons that file already documents instead of listing
  them, and the Output contract's "`dispatched` counts the workers that rehearsed" is gone from
  there because Step 5 states it. **Nothing normative left `SKILL.md`** — Step 4's three mapping
  rows, the breaker rule that excludes `dry-run`, the gate line and the requirements wording are all
  still inline, because they are contract rather than rationale.

  Review round on PR #35 (Copilot): `check-requirements` reported `REQ: <repo> ok` and exited 0 over
  a manifest whose unrecognised line it had skipped — the ERROR lines printed without `--quiet`, but
  the summary line and the exit code, which are the only things Step 1 acts on, said the repo was
  fine. An unchecked requirement reporting `ok` is the failure this feature exists to remove, so a
  malformed line is now a hard failure in every mode and Step 1's exit-1 test catches it unchanged.
  Round three: Step 1 also says what exit 2 means. `check-requirements` reserves it for a repo
  `repos.conf` cannot resolve, which is a broken mapping rather than a host gap, so the repo joins
  the `skipped:` list beside a `gh` failure instead of `unmet` — `unmet` is for repos this host
  cannot build, and a repo nobody can locate has not been assessed at all. Step 1's "Exit 0 (`ok`,
  `advisory`, `no-manifest`)" lost its enumeration to pay for it; exit 0 is the rule and the three
  statuses are listed in COMMANDS.md.

  Round four (Grok, finding f2): Step 1 dropped a repo into `unmet`, and the gate line reported
  `unmet=`, but Step 1's own verify line still asked only that every active repo be "represented in
  the queue counts or named as `skipped:`". An unmet repo is in neither, so a correct run could not
  satisfy the check the step ends on — and `references/queue-building.md`, which Step 1 sends its
  reader to for what gets dropped, never mentioned the bucket at all. The verify line now names
  three buckets, and `queue-building.md` opens with a section separating the two LEVELS of drop:
  `unmet` and `skipped:` take whole repos before any issue is considered, and the four tests it
  already documented take issues inside a repo that survived. `test_cap_names.sh` pins both halves —
  Step 1's verify line must admit `unmet`, and the reference must document it — beside the existing
  check that `unmet=` is a field of the gate line.

  Paid structurally again. "(a `repos.conf` error, not a host gap)" left Step 1 for the new
  `queue-building.md` section, which states the distinction in full rather than in a parenthesis:
  exit 2 is fixed by a line in `repos.conf`, not a `brew install`, so recording it as `unmet` would
  send a human hunting a tool that was never the problem. `SKILL.md` came out 21 bytes SMALLER than
  it went in (10,220 → 10,199) with the verify line longer, and nothing normative moved.

  The same round changed what lands in `unmet`: a `cmd` installed below its declared `>=` floor now
  exits 1 under an `advisory` gate as well as a required one, so such a repo is dropped rather than
  dispatched with its verify gate downgraded. `work-on-task/META.md` carries that reasoning.
- 2026-09-08: Review round on PR #34. Step 4 said "echo the worker's returned `WORK:` line", which
  no rehearsed worker can satisfy: `work-on-task` prints `PLANNED:` and returns there under its own
  dry run, never reaching its `WORK:` line. Step 4 now consumes whichever contract line came back —
  `WORK:` copied verbatim, `PLANNED:` recorded as `outcome=dry-run gate=- pr=-`, neither line still
  `outcome=halted`, which is what the subagent-delegation failure returns. Step 5's "under a dry run
  every outcome is `dry-run`" overstated it: a worker can refuse at Step 1 (not approved, an open
  PR, no root `CLAUDE.md`, an unmet dependency) or halt on a capability gap without ever planning,
  and both GameTwo workers did exactly that on the night of 2026-09-07; those outcomes stay
  `refused`/`halted` under a dry run and `dispatched=<d>` counts only the workers that planned.
  Halt 5 narrowed with them: the breaker counts `halted`/`refused`, not every non-`pr-opened`
  outcome, because rehearsed workers all carry `gate=-` and would otherwise halt each dry run at its
  third issue. Five more restatements were cut for the budget — the Contract's "the gate line prints
  on every run" (Step 2 says it), Step 3's "and no Telegram" and Step 5's "at most one message per
  run" (the Contract and Step 5's own rule say them), and the Hard rules on `budget`/`slots_r` and
  on `blocked:` issues (Steps 1 to 3 carry both). Second pass: the fix above was written as prose
  that read as if the dispatcher printed a `WORK:` line and buried the missing-line case in
  "neither line is …", which parses two ways — at 04:10 a model reads this file, so Step 4 now
  states the mapping as three rows, what the fork returned against the `DISPATCH:` fields to print.
  The paragraph above it no longer recites the two hand-off failures; they moved into the row they
  are the reason for, which paid for the rows.
- 2026-09-07: Hotfix — a dry run no longer returns before Step 4. It forks every planned worker
  exactly as a real run does, appending `--dry-run` to the args, and the worker's own dry-run
  contract (it stops before its first mutation) is what keeps the rehearsal read-only. Skipping the
  fork made the dispatcher-to-worker hand-off the one thing a rehearsal could not test — and that
  hand-off is the part that has broken twice, first with arguments that never reached the fork, then
  with a fork that delegated to a subagent and returned no line. `make smoke-dispatch-tasks-night`
  failed the routine for exactly that: a correct gate naming an eligible repo, a correct plan naming
  two issues, then `dispatched=0` with no `DISPATCH:` line and no worker forked. `DISPATCH:` gains
  `outcome=dry-run` for a worker that planned and wrote nothing, and under a dry run
  `DISPATCH END:`'s `dispatched=<d>` counts the workers rehearsed. Nothing else about a dry run
  changes: no Telegram, no labels, no comments, no PRs. To stay inside the S4 budget, three Hard
  rules that only restated Steps 2, 3 and 4 (one repo at its limit is not a halt; one worker's
  failure never aborts the run; only open agent PRs count against the PR caps) were cut along with
  the role paragraph's third sentence, which restated the Contract block. `BASELINE.md` and
  `docs/skill-standard.md` S7 were corrected to match: a skill that orchestrates other skills
  rehearses them rather than skipping them.
- 2026-09-07: Step 0 now echoes `dry_run=${ROUTINE_DRY_RUN:-0}` so the smoke gate (`make smoke`)
  can rehearse this skill read-only; `BASELINE.md` defines the contract, and under it Step 4 still
  forks each worker so the dispatcher-to-worker hand-off is exercised. Three sentences were
  compacted to keep SKILL.md inside the S4 budget.
- 2026-09-06: Hotfix — removed `disable-model-invocation: true`. The flag blocks the Skill tool,
  which is the only path a headless `claude -p` run has from `dispatch-tasks-night.md` to this
  skill, so the runs of 2026-09-05 and 2026-09-06 halted without dispatching. Step 0 now refuses a
  run with `ROUTINE` unset unless `--dry-run` or `--force` is passed — the guard the flag was
  standing in for — and `--force` is new. Step 1's drop tests and Step 3's ordering detail moved to
  `references/queue-building.md` to keep `SKILL.md` inside its 10 KB budget.
- 2026-09-05 (v0.6.1): Review round on PR #28. Two holes in the gate as v0.6 first wrote it.
  Eligibility tested only `slots_r > 0`, so at the global ceiling — `slots <= 0`, and therefore
  `budget <= 0` — a repo with per-repo room still printed as `eligible` on a line that dispatched
  nothing; it now takes all three of `budget > 0`, `slots_r > 0` and a queued issue, which makes
  `eligible=-` the unambiguous companion of every halt. And a ceiling-bound halt has an empty
  `at_limit` by definition, so the per-repo pointers named nothing and the one halt a human cannot
  act on locally was the one with no lead: it now also reports the oldest agent PR across the active
  repos as `global ceiling: land <owner/repo>#<n>`. The gate line itself is unchanged, byte for
  byte. `daily-review-nudge` said "the caps, both of them" when `repos.conf` holds three, and now
  names the two PR caps it means. The cap-relation unit test reads its variables by indirect
  expansion rather than `eval`.
- 2026-09-05 (v0.6): **Per-repo limits under a global ceiling — the gate is no longer weakest-link.**
  A single global count meant two or three unreviewed PRs in one repo shut dispatch for all seven
  active repos, including those with zero open PRs and approved work ready, so the pipeline ran at
  the speed of its most-neglected project. `repos.conf` gains `DISPATCH_PER_REPO_MAX` (open agent
  PRs in one repo, same agent-PR definition) and `DISPATCH_RUN_MAX` (new dispatches per run);
  `DISPATCH_TOTAL_MAX` keeps its value and narrows to bounding the human's total review load.
  Step 2 now computes `slots`, a `slots_r` per repo and `budget = min(slots, DISPATCH_RUN_MAX)`,
  and halts only when **no repo is eligible** — naming each at-limit repo with the oldest agent PR
  to land in it. Step 3 round-robins across eligible repos, decrementing `slots_r`. The gate line
  gained `per_repo`, `run_max`, `budget`, `at_limit` and `eligible` and lost `slots`; a static test
  now pins its wording so SKILL.md and META cannot drift apart. `daily-review-nudge` reports
  in-flight per repo alongside the global count, and `daily-summary`'s pipeline line names the
  at-limit repos.
- 2026-09-03 (v0.5): Rewritten against `docs/skill-standard.md`; off `skill-contract-exceptions.txt`.
  Frontmatter now declares `disable-model-invocation`, `model: claude-sonnet-5`, `effort: medium`
  and prefix-scoped `allowed-tools` in place of bare `Bash`. SKILL.md dropped from 15.3 KB to under
  the 10 KB budget, with the sequential-dispatch and dependency-lookup rationale moved to
  `references/`. **Output contract fixed**: the `DISPATCH GATE:` line is now the unconditional first
  line of every run — a manual run on 2026-09-02 computed the gate correctly and then wrote it as
  prose, so the parsable line never appeared — and every run now emits `DISPATCH PLAN:`, one
  `DISPATCH:` per task copied from the worker's `WORK:` line, and `DISPATCH END:`. **Workers are
  isolated**: `work-on-task` gains `context: fork` and loses `disable-model-invocation: true`, so
  each worker runs on its own Opus/`high` in its own context instead of silently inheriting this
  dispatcher's Sonnet — and so the Skill tool can invoke it at all. Added the driver/driven ordering:
  Step 1 skips a `shape:feature` in a driven repo that has no `DRIVEN BY` line, and Step 3 orders
  features and polish in driver and undriven repos first, driven repos next, `shape:chore` last.
- 2026-09-02 (v0.4): Broke the dispatch deadlock. The old `WIP_TOTAL_MAX` counted open agent PRs
  **plus** approved-but-unstarted issues, so the queue blocked the only gate that could drain it —
  in the 04:10 run, 2 open PRs plus 7 approved issues read as 9 against a cap of 6 and the run
  dispatched nothing. The cap now counts open agent PRs only, is named `DISPATCH_TOTAL_MAX`, and is
  defined once in `repos.conf` (it had been declared under four names with four different values).
  Added the dispatch gate and the `blocked:` label filter. Removed `TOTAL_MAX`, `PER_REPO_MAX`,
  `WIP_MAJOR_MAX` and the `--total-max` / `--per-repo-max` flags; per-repo fairness became
  round-robin ordering. A static test now fails the suite on an undefined `*_MAX` or a prompt that
  hardcodes a cap.
- 2026-07-14: Efficiency pass (measured): one-repo-per-Bash-call queue build with per-repo failure
  isolation; DEPENDS-ON algorithm moved to `docs/depends-on-convention.md`; `REPOS_BY_PRIORITY`
  sourced from `repos.conf`; POSIX-safe shell note; digest sent via `telegram-send` with no rm or
  chaining.
- 2026-07-08: Assessed — no SKILL.md issues found. Corrected the Status section.
- 2026-05-08 (v0.3): Cross-repo dependency support — `DEPENDS ON owner/repo#N` alongside same-repo
  `#N`, cross-repo extracted and stripped before same-repo matching, 404 defers rather than
  silently satisfying.
- 2026-05-07 (v0.2): Dependency-aware queue building; `DEPENDS ON #N` parsed from issue bodies and
  unmet deps deferred, with a Deferred section in the plan and digest.
- 2026-05-07 (v0.1): Initial draft. Sequential dispatch with priority and caps.
