---
domain: universal
kind: coding
version: 2.2.0
status: active
last-assessed: 2026-09-03
---

## Purpose
The core autonomous agent loop. Picks up one `approved` GitHub issue, resolves the base branch the
issue asks for, implements it in an isolated worktree, runs the project's verify gate from
`CLAUDE.md`, and opens a draft PR — one per issue, ever. The implementation is test-driven: the
tests that encode the acceptance criteria are written and run red before any implementation, then
run green, and only then does the full gate run. Invoked by `dispatch-tasks` as
`Skill(name="work-on-task", args="<N> --repo <repo>")`, and by hand for a single issue.

## Model / budget
- Model: `claude-opus-4-8` — this is the only skill in the repo that writes production code against
  an unfamiliar file layout, and the failure mode of a weaker model here is a plausible-looking diff
  that a human has to review line by line.
- Effort: `high` — the run is one shot per issue: the plan, the edits and the gate all have to be
  right the first time, and there is no reviewer in the loop to catch a shortcut.
- Typical run: 20-40 turns, roughly $2.50 per issue, measured across the nightly dispatch runs of
  2026-08. Budget ceiling is 60 turns; a run that has not reached the gate by then is halting for a
  reason the plan did not anticipate.

## Halt Conditions
Every one of these ends the run. The `WORK:` line always prints, whatever the outcome.

**Refusals** (Step 1, recorded by `scripts/record-refusal.sh` as `blocked:<reason>` plus one
comment; `outcome=refused`):
- `closed` — the issue is closed.
- `not-approved` — no `approved` label. The label is the whole authorisation model.
- `no-claude-md` — the repo has no root `CLAUDE.md`, so there is no gate and no autonomy boundary.
- `depends-on` — a `DEPENDS ON` dependency is open, or a cross-repo one returned 404.
- `already-in-progress` — an open PR or a remote `task/issue-<N>-*` branch already exists for this
  issue. This is the idempotence check: a second run must not produce a second PR.
- `missing-deps` — `check-requirements <repo>` exited 1, either because the project's
  `agent/requirements.conf` declares tooling this host has not got, or because a line of it cannot
  be parsed and so a requirement is not being checked at all. Both mean the gate cannot be trusted
  to run, whatever the diff looks like. The comment carries the checker's own text, so the fix is a
  `brew install` or a one-line manifest correction rather than a re-read of the diff. A repo with no
  manifest, and an `advisory` manifest whose failure is an ABSENT requirement, both proceed — the
  second with the gate outcome fixed at `no-gate`. An `advisory` manifest whose `cmd` is installed
  but below its declared `>=` floor does NOT proceed: it exits 1 like any other unmet requirement
  and refuses here, for the reason in the changelog below.

**Halts** (`outcome=halted`):
- No `get_repo_path` entry for the repo — halt, never scan (`references/environment.md`).
- A `BASELINE-CODING.md` hard halt condition: ambiguous intent, a MUST-ask-first action that is not
  pre-authorised, the issue contradicting `CLAUDE.md`, or a capability gap.
- A tripped scope circuit-breaker — surfaced as "this is probably two issues, not one".
- A MUST-ask-first area, via `/request-approval`, which stops the run until a human approves.
- Gate outcome `failed` (still failing after the retry budget) or `could-not-run` (the gate's tool
  is absent on this host). Both commit locally, keep the worktree, add `blocked:verify` with the
  first error line, and open no PR.
- A red test that never goes green is the same halt: the gate cannot pass over a failing test, and
  nothing may be disabled or deleted to get past one.

Only gate outcomes `passed` and `no-gate` reach `gh pr create`; `no-gate` says so in the PR body.

## Dependencies
- `gh` CLI, authenticated
- `EnterWorktree` / `ExitWorktree` (Claude Code harness)
- `launchd-runtime/repos.conf` — `get_repo_path` for the repo's on-disk path
- `launchd-runtime/bin/check-requirements` — Step 1's host precondition, read from the target repo's
  own `agent/requirements.conf`
- Target repo has a root `CLAUDE.md`; target issue has the `approved` label
- `notify` (Telegram on a successful PR, interactive runs only) and `request-approval`
  (MUST-ask-first areas)
- `docs/depends-on-convention.md` — the `DEPENDS ON` grammar

## Known Issues
- **No persistent state across sessions.** A task larger than one session leaves the worktree
  behind; the next invocation starts from the issue again.
- **Single repo per run.** A feature spanning two repos needs one run per repo, in the order
  `CLAUDE.md` prescribes.
- **No auto-resume after `request-approval`.** The human approves, then re-runs the skill; progress
  survives only as the partial state in the worktree.
- **No conflict resolution.** A `git push` rejected by upstream halts the run.

## Changelog
- 2026-09-08 (v2.2.0): Step 1 now runs `check-requirements "$REPO" --quiet` as a precondition and
  refuses `missing-deps` when it exits 1, recording the missing names through
  `scripts/record-refusal.sh` exactly as the other refusals are recorded. On 2026-09-07 two
  GameTwo workers each read the issue, planned, edited and only then discovered that the game-engine
  engine checkout was absent and `xcodebuild` could not run — one had already committed eight lines
  locally when it refused to open a PR. The tooling was declared nowhere, so a dispatch slot was the
  cheapest way to find out. An `advisory` manifest is the other half: its failure proceeds with the
  Step 7 gate outcome fixed at `no-gate`, which is what StarBonk's `CLAUDE.md` already prescribes
  when the Unity CLI is absent. Nine passages were cut to stay inside the 10 KB budget, each one a
  restatement: the `no-issue-number` rationale (the Arguments section says `$0` is required), the
  never-scan Hard rule (Step 3 states it where it applies), the subagent rule's rationale
  (`disallowed-tools: Agent` is the enforcement), "which stops the run" after `/request-approval`
  (a Hard rule says it), the `--dry-run` gloss and Step 4's list of what a dry run does not write
  (BASELINE defines both), the "Start from branch X" legacy note, "adding nothing the issue did not
  ask for" (BASELINE Principle 3, and the step's own check), and "a missing behaviour, not a typo"
  (the step's check says the same). Review round on PR #35: Step 1's `missing-deps` test keys off
  `check-requirements`' exit code rather than the string `missing=`, so a manifest the checker
  cannot parse — now a hard failure of its own, `REQ: … manifest-error line <n>` — refuses the
  issue the same way a genuinely absent tool does. Round three: Step 1 also says what exit 2 means.
  `check-requirements` reserves it for a repo `repos.conf` cannot resolve, which is the unmapped-repo
  halt Step 3 already owns, found one step earlier; it is not a `missing-deps` refusal and must not
  be recorded as one, because the fix is a line in `repos.conf` rather than anything on the host.
  Four sentences were tightened by a word each to pay for it inside the 10 KB budget; nothing was
  removed.

  Round four (Grok, finding f1): **`advisory` covers an absent requirement and nothing else.** The
  hole was StarBonk, which declares `gate: advisory` and `cmd unity >=1.0.0-beta.8` together. A
  beta.5 CLI made the requirement `missing`, `advisory` turned that into exit 0 with `gate=no-gate`,
  and Step 1 then fixed Step 7's outcome at `no-gate` — skipping the verify gate. The gate it
  skipped is `bin/unity-gate`, which refuses beta.5 because that build reports a failed test and a
  failed compile identically as exit 6. So the floor protected nothing, and worse: with no manifest
  at all the worker would have run the gate and halted loudly, which means declaring the floor left
  the repo weaker than declaring nothing. A guarantee that inverts when you write it down is not a
  guarantee.

  Two ways to close it. Either a failed floor stops being advisory, or `work-on-task` keeps running
  the gate when the manifest's floor is what failed. The first is what landed. It puts the decision
  in the one place that already knows *which* requirement failed and why — `check-requirements`
  compares the version, so only it can distinguish "absent" from "present and too old" — and it
  spends nothing to reach the answer. The second would hand `work-on-task` a summary line and ask it
  to infer the distinction, then spend a full worker implementing an issue in order to arrive at a
  gate already known to refuse. The failure this whole feature exists to remove is spending a worker
  to discover a host gap, so an option that spends one on a gap already diagnosed is the wrong half
  of the fork.

  `check-requirements` therefore exits 1 for a below-floor `cmd` under any gate and names it —
  `REQ: <repo> missing=1 (unity) below-floor=unity` — and Step 1 refuses it as `missing-deps`, the
  refusal that already carries the checker's text and the manifest's `# hint:`. `SKILL.md` needed no
  change: "A `REQ: … advisory` line instead proceeds" is still exactly true, because a failed floor
  no longer produces an advisory line. The rationale is here, in `bin/check-requirements`' module
  docstring, and in StarBonk's own manifest beside the floor it explains; the skill body carries
  none of it.
- 2026-09-07: Step 1's echo now carries `dry_run=${ROUTINE_DRY_RUN:-0}` beside
  `args=[$ARGUMENTS]`, so a worker forked by a rehearsed dispatch dry-runs itself instead of
  opening a PR; `BASELINE.md` defines the contract and `make smoke` is its only caller. The
  Contract's `retries per BASELINE-CODING.md` was cut to stay inside the 10 KB budget — the
  Limits list points at the same file for the same thing.
- 2026-09-07 (v2.1.4): **P0 fix.** `disallowed-tools: Agent` in the frontmatter, and a Hard
  rules line saying so. Hours after PR #31 landed, a forked `work-on-task --dry-run` received
  its arguments, read the issue and the code, spawned a background research subagent and ended
  its turn with "Waiting on the primitives-search agent … before finalizing the plan." A forked
  skill that ends its turn has returned: no `PLANNED:` line and no `WORK:` line, and
  `dispatch-tasks` scores a missing `WORK:` line as `halted` — two in a row trip its
  systemic-failure breaker, so the night dispatched nothing. Two passages were trimmed to stay
  inside the 10 KB budget: the "never mark a PR ready, never merge, never work an unapproved
  issue" sentence in the opening paragraph (Hard rules and the Contract each say it already) and
  the "one event, two messages" rationale after Step 7's notify rule. Enforced by
  `test_contract_headless_skills_disallow_the_agent_tool`.
- 2026-09-07 (v2.1.3): **P0 fix.** The Arguments section now carries the literal `$ARGUMENTS`
  placeholder and Step 1 echoes `args=[$ARGUMENTS]` before its first `gh` call, refusing with
  `HALT: work-on-task no-issue-number` when the brackets are empty or the first token is not a
  number. On 2026-09-07 `dispatch-tasks` invoked `Skill(name="work-on-task", args="18 --repo
  acme/GameTwo")` twice; because this skill runs `context: fork`, each worker's whole prompt
  was this file after substitution, and with no placeholder to substitute into, the arguments went
  nowhere. Both workers replied "I don't have an issue number to work on", the dispatcher tripped
  its systemic-failure breaker, and issues #18-#24 went untouched. `$0` stays as it was — it is the
  documented first argument — but it cannot make an absent invocation visible. Enforced by
  `test_contract_skills_invoked_with_arguments_carry_the_arguments_token`. To stay inside the 10 KB
  budget, the branch-prefix rationale and the pre-staged-work recipe moved to
  `references/environment.md`, and the `main is a default` restatement is gone.
- 2026-09-03 (v2.1.2): Step 7's per-PR `notify` is now conditional on `ROUTINE` being unset. Under
  a routine, `dispatch-tasks` already sends one digest for the whole run, so a three-PR night sent
  four Telegram messages for three events; interactive runs have no dispatcher and keep the
  per-PR message. Paid for inside the 10 KB budget by dropping two lines that restated rules the
  file already carries — the `Limits` bullet duplicating the Contract's Writes/Budget lines, and
  "explicit paths only" in Step 7, which is a Hard rule two screens down. SKILL.md 10,220 B.
  (`version:` also catches up with the v2.1.1 entry below, which bumped the changelog but not the
  frontmatter.)
- 2026-09-03 (v2.1.1): Review fixes on PR #15. `## Steps` now introduces `$N`, `$REPO`,
  `$REPO_PATH`, `$BASE` and `$SLUG` once, so the five bash snippets that use them are readable in
  isolation. Step 3's check said `ls-remote` where it meant `git ls-remote`. Step 7's halt path
  called `record-refusal.sh` without a path, which no `allowed-tools` entry matches — both call
  sites now use `${CLAUDE_SKILL_DIR}/scripts/record-refusal.sh "$REPO" "$N"`. The script says
  "halted" for a `verify` reason and "refused" otherwise, since a gate halt is not a refusal and a
  human triaging "why is there no PR" reads that line first. Also dropped
  `disable-model-invocation: true`: it blocks the Skill tool, and `dispatch-tasks` invokes this
  skill as `Skill(name="work-on-task", …)`, so the flag turned every nightly dispatch into a silent
  no-op (five-run probe on the dispatch branch). No routine prompt names `/work-on-task`, so the
  contract test does not require it. SKILL.md 10,198 B.
- 2026-09-03 (v2.1.0): Implementation is now test-driven. Step 5 creates the worktree and then
  writes the tests that encode the issue's acceptance criteria, in the framework and location
  `CLAUDE.md` names, and runs them red — recording the command and its first error line for the PR
  body. Step 6 implements to green. Step 7 runs the full gate as before, with the same four
  outcomes and the same `WORK:` line. A repo whose gate is `NO GATE — verify by reading` still gets
  tests wherever a framework exists; a change no test can express (pure docs, config, data) skips
  red and green and says which and why in the PR body, never silently. The PR body's Test plan
  lists the tests added first, then the red command. Steps 7 and 8 merged into one — the gate
  outcome already decides whether the PR happens — which paid for the new steps inside the 10 KB
  budget (10,215 B).
- 2026-09-03 (v2.0.0): Rewritten against `docs/skill-standard.md`, closing five audit findings.
  WORK-2: Step 1 now refuses `already-in-progress` on an existing open PR or remote
  `task/issue-<N>-*` branch, so an issue cannot collect a second PR. WORK-3: the base branch is
  parsed from a `BASE BRANCH: <name>` marker (legacy "Start from branch X" still accepted) and
  defaults to the repo's own default branch; the worktree is created explicitly from `origin/<base>`
  on a branch already named `task/issue-<N>-<slug>`, and `gh pr create --base` uses it — `--base
  main` is gone. WORK-4: the gate ends in exactly one of `passed | failed | could-not-run |
  no-gate`, and only the first and last continue to a PR; the other two commit locally, label
  `blocked:verify` and halt, which is what both live GameTwo drafts needed. WORK-5/S6: the PR
  body carries the attribution marker and the run prints one `WORK:` line. QUAL-1: an issue's
  `## Implementation plan` is explicitly advisory. Frontmatter gains `disable-model-invocation`,
  `model`, `effort` and prefix-scoped `allowed-tools` in place of bare `Bash`; `--dry-run` stops
  after the plan; rationale moved to `references/environment.md` and `references/pr-body.md` and the
  refusal recipe to `scripts/record-refusal.sh`, taking SKILL.md from 20.1 KB to under the 10 KB
  budget. Removed from `skill-contract-exceptions.txt`.
- 2026-07-14: Baseline split (efficiency assessment D1) — preamble now reads BASELINE.md (core five
  principles) AND BASELINE-CODING.md (relocated coding detail: halt conditions, scope
  circuit-breaker, replace_all discipline, verify/retry rules). No behavioral change.
- 2026-07-08 (v1.0): Assessed. Graduated experimental → active. Minor flag (not fixed): Steps 4 and
  6 restate BASELINE's scope-circuit-breaker and retry-budget rules verbatim next to their
  citations — trim to bare citations in a future pass.
- 2026-05-08 (v0.5): Added cross-repo dependency support to Step 1. Same parsing/resolution rules as
  dispatch-tasks v0.3 — `DEPENDS ON owner/repo#N` resolved against the dep's repo, 404 lookups halt.
- 2026-05-07 (v0.4): Added the defensive dependency check to Step 1, so manual invocations respect
  deps too, not just dispatch-tasks' queue build.
- 2026-05-07 (v0.3): Added `replace_all` discipline to Step 5, after an iterate-on-pr run caught
  gendered noun forms in a translated string that a naive `replace_all` would have corrupted.
- 2026-05-07 (v0.2): Strengthened after the first real run (club-site #2 → PR #3): Read before
  Edit, the Homebrew PATH gotcha, the pre-stage count check and explicit-path staging, Step 7b for
  pre-existing staged work, the production-branch reminder and cross-repo call-outs.
- 2026-05-07: Initial draft (v0.1)
