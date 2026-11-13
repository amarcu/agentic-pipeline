---
domain: universal
kind: coding
version: 2.2.0
status: active
last-assessed: 2026-09-03
---

## Purpose
The worker half of the review loop. `work-on-task` opens a draft PR; `review-pr` and
`cursor-review` post findings on it as inline threads, under the same `finding:` tag and the same
login; this skill reads those threads plus whatever the human added, fixes or contests each one, pushes the commits to the PR's own branch, replies in every thread it touched and
posts one `Addressed in <sha>` summary. It is the only skill that writes to a branch someone else
created, which is why it works in that branch's existing worktree and never checks it out in the
shared clone. With `--review-rounds <n>` above zero it then drives the PR's Copilot review rounds to
green through `launchd-runtime/bin/pr-review-round`, repeating the fix/reply pass on each round's
new findings — the loop a human drove by hand four times on `amarcu/agentic-pipeline#35` in one day.

## Model / budget
- Model: `claude-opus-4-8` — the work is production code written against a reviewer's claim rather
  than a specification, and a weaker model's failure mode here is a plausible diff that answers a
  finding without fixing it, which costs the reviewer another round.
- Effort: `high` — each item has to be understood, tested and either fixed or contested with
  evidence, and a contested finding that turns out to be right burns two rounds.
- Typical run: 20-40 turns, roughly $3.00 per PR at Opus pricing (estimated from `work-on-task`'s
  measured $2.50 plus the reply and classification traffic; no measured run yet under v2.0.0).
  Budget ceiling is 60 turns. Each `--review-rounds` round is another fix/verify/push/reply pass, so
  `--review-rounds 3` is up to four times that; the flag defaults to `0` for exactly that reason. The threads one run may address are capped by `MAX_THREADS` in
  `scripts/pr-feedback` (50); an item that asks for another issue's work is named, not done.

## Halt Conditions
Every one of these ends the run, and the `ITERATE:` line always prints.

**Refusals** (Step 1, printed as `HALT: iterate-on-pr <reason>`; nothing is written to the PR):
- `not-open` — the PR is closed or merged.
- `not-draft` — a human marked it ready, which means they have taken it over.
- `protected-branch` — the head branch is `main`, `master` or `production`.
- `no-claude-md` — the clone has no root `CLAUDE.md`, so there is no gate and no autonomy boundary.

**Halts**:
- `unmapped-repo` — no `get_repo_path` entry. Halt, never scan (`work-on-task`'s
  `references/environment.md`).
- `no-feedback` — nothing actionable after classification. No commit, no comment, no Telegram:
  a no-op run leaves no trace (BASELINE Principle 5).
- `too-many-threads` — `pr-feedback` exits 3 past `MAX_THREADS`. The alternative is truncating the
  GraphQL page, which drops findings without saying so.
- `verify-failed` / `verify-could-not-run` — the gate failed after the retry budget, or its tool is
  absent on this host. The work commits locally and nothing is pushed: a broken commit on a branch
  under review costs the reviewer a whole round.
- A push that will not fast-forward after one `pull --ff-only` retry — surfaced, never auto-merged
  or rebased.
- A `BASELINE-CODING.md` hard halt: ambiguous intent, a MUST-ask-first area (via
  `/request-approval`, which stops the run), feedback contradicting the issue, or a capability gap.

The review rounds (Step 7) end the loop rather than halting the run — the `ITERATE:` line still
prints, carrying the verdict `pr-review-round status` last reported. `request` exit 3 (no request
was created), `wait` exit 4 (the timeout expired), exit 5 (`quota-exhausted`) and any exit 2 (a gh
failure) all stop the rounds, and none of them is ever recorded as `verdict=green`. Exit 5 stops
them *immediately*, with the remaining rounds unspent: the reviewer is out of quota, so another
round would only repeat the non-answer. Exit 6 (`already-reviewed-at`) is not reached by a
well-behaved loop at all — it is the backstop for a round opened without a commit to review, which
GitHub would bill to the human for a verdict already on the PR.

## Idempotence
A second run against an unchanged PR does nothing. Three markers carry it, all written by the
previous run and all greppable:
- `<!-- reply finding:<id> outcome:… -->` / `<!-- reply iterate-on-pr outcome:… -->` on every thread
  acted on. GitHub thread resolution would be the natural record, but `resolveReviewThread` is
  deny-listed for scheduled runs in `_run.sh`, so the reply is the durable one.
- `<!-- agentic-skills: skill=iterate-on-pr … -->` on the summary comment: everything older than
  the newest one carrying it is `addressed`, and the run never reads its own summary back as
  feedback. The `Addressed in <sha>:` prefix is `daily-summary`'s contract, not the signature —
  the human posts under the same login, so a human comment opening with those words must not be
  able to move the cut-off.

## Dependencies
- `gh` CLI, authenticated, with GraphQL access (review threads expose `isResolved` only there)
- `python3` for `scripts/pr-feedback`
- `launchd-runtime/repos.conf` — `get_repo_path` for the clone
- `EnterWorktree` / `ExitWorktree` (Claude Code harness)
- Target repo has a root `CLAUDE.md`; the PR is open and a draft
- `launchd-runtime/bin/pr-review-round` — the request/wait/status mechanics of Step 7; only
  reached when `--review-rounds` is above zero
- `review-pr` for the finding tag it consumes, `notify` for Telegram, `request-approval` for
  MUST-ask-first areas, `daily-summary` as the consumer of the `Addressed in ` prefix

## Known Issues
- **No visual verification.** A CSS or layout change is made, marked "needs human verification on
  rendered output", and never claimed to look right.
- **Conflicting reviewers are not adjudicated.** Two people asking for opposite things is ambiguous
  feedback: it is asked about in the thread, not resolved by picking a side.
- **A Copilot round is not a human round.** `--review-rounds` drives the Copilot reviewer only.
  A finding a human raises in reply to this run's reply is still next run's work.
- **The round loop is unmeasured.** It has been unit-tested against a mock `gh` and never yet run
  against a live PR, so the turn and cost figures above cover the `--review-rounds 0` path alone.
- **The `contested` count is the model's, not the script's.** `pr-feedback` reports actionable and
  skipped; how many of the actionable ones ended contested is only known after the run.

## Changelog
- 2026-09-08 (v2.1.0): `--review-rounds <n>` (default `0`, so nothing changes unless a caller asks)
  and a Step 7 that drives the Copilot rounds through the new
  `launchd-runtime/bin/pr-review-round`. Four rounds ran by hand on `amarcu/agentic-pipeline#35` on
  2026-09-08; the judgement stays here, the request/wait/collect mechanics moved to the script. The
  round loop, the per-round reply table and the forbidden "clear a comment with a change you believe
  is wrong" rule live in `references/summary-comment.md`, which is now titled for replies, the
  summary and the rounds together. `quota-exhausted` is a first-class outcome throughout: Copilot
  answers a request it cannot serve with a plain "unable to review … quota limit" sentence and no
  verdict line, which reads as silence to a verdict parser and as zero findings to a comment count.
  It stops the loop at once rather than burning the remaining rounds, and the human chooses between
  the last substantive verdict and waiting for quota. Observed live on this repo's PR #35 the same
  day. The `## Steps` variable index paid for that wording and is gone: every one of `$HEAD_BRANCH`,
  `$R`, `$REPO_PATH`, `$WT` and `$SHA` is introduced by the step that sets it. The same PR paid for
  the billing guard: a Copilot review is metered per invocation, billed in AI credits to whoever
  requested it, with no de-duplication for a repeat on an unchanged head SHA — and #35 carries two
  reviews against commit `01ba178b` twelve minutes apart, the second bought with the human's
  allowance to be told what the first already said. `request` now refuses a repeat on a reviewed
  SHA (exit 6, `already-reviewed-at`) unless `--force` is passed, and Step 7 says in one line why
  the loop must never open a round it has not pushed a commit for.
- 2026-09-08 (v2.1.1): two `major` findings from the Cursor/Grok review lane on PR #36, both of the
  false-green class the script exists to prevent. f1: `wait` accepted any Copilot review submitted
  after `--since` whatever commit it was of, so a late review of the previous head — Copilot posts
  those, #35 has two against one commit twelve minutes apart — could satisfy a round opened for a
  new push, after which `status` reported a verdict on code nobody had reviewed. `wait` now waits
  for a review OF the head as it stood when the wait began, picks the newest review of that commit
  rather than the newest review overall, and treats "only reviews of older commits" as a timeout.
  f2: `references/summary-comment.md` told the worker to compute `--since` with `date -u`, which
  this skill's `allowed-tools` never granted, so a deny-closed headless run could not have run the
  loop at all. Fixed structurally rather than with a new grant — `--since` is now optional and
  defaults to the moment `wait` starts, so the loop needs no clock; the flag stays for a human
  reconstructing a round. `status` also gained a stderr note and a `commit_id` in `--json` when the
  verdict on show is not against the head. SKILL.md had 2 B of headroom, so Step 7's billing
  rationale was compressed to its guardrail plus a pointer (the full account of per-invocation
  metering, the credit ranges and the monthly reset stays in `references/summary-comment.md`), and
  the heading dropped its `<n>` placeholder, which `## Arguments` already carries. It is 10,238 B.
- 2026-09-08 (v2.1.2): round two of the same review found the same root cause surviving in the two
  call sites round one did not touch, both `major` and both valid. f3: `cmd_status` still took the
  newest Copilot review whatever commit it was of, so a 🟢 against the commit before a push made
  `status` exit 0 — the loop's "stop, we are green" signal — on code nobody had reviewed. f4:
  `request`'s billing guard compared the head against the most recently reviewed commit, so a late
  review of an older commit hid the fact that the head already had a verdict and let a billed
  re-request through. The real finding was structural: three subcommands each asking "is there a
  review of this commit" three different ways, two of them wrong the same way. They now share one
  `pick_head_review`, and `latest_copilot_review`, `latest_review_of` and `last_reviewed_sha` are
  gone. `status --json` gained the `head` it compared against. Nothing moved out of SKILL.md this
  time: the new clause was paid for by dropping a repeated `status` from a sentence that had just
  named it and a parenthetical restating the `--review-rounds` default. It is 10,226 B.
- 2026-09-08: merged `main` at d199d82, which brought PR #37's `cursor-review` — a second reviewer
  lane — and the root `CLAUDE.md` naming `make test` as the verify gate. No conflicts. Five wording
  fixes so the two lanes do not read as one: the `reviewer` kind in `references/feedback-triage.md`
  and the tag line in `scripts/pr-feedback` said "a `review-pr` finding" for a tag `cursor-review`
  writes too; "The reviewer adjudicates it next round" inside the Copilot section now names Copilot;
  the Purpose above names both lanes as sources of findings; and `references/summary-comment.md`
  now says plainly that `verdict=green` is this lane's green — Copilot is satisfied with the commit,
  the PR is not thereby reviewed. Wording only: no lane was restructured and no classifier changed.
  One gap is reported rather than fixed here, because fixing it changes `pr-feedback`'s behaviour
  rather than its prose: `REVIEW_SUMMARY_MARKER` is `<!-- review-pr `, while `cursor-review` signs
  its summary body `<!-- cursor-review `, so a cursor-review summary carrying no inline finding tag
  classifies as `human` rather than `reviewer`. Its inline findings classify correctly.
- 2026-09-09 (v2.2.0): that gap fixed, on the user's decision to fix #36 rather than merge it.
  `scripts/pr-feedback` no longer matches one lane's literal marker: `REVIEW_SUMMARY_RE` reads the
  shape both lanes share — `<!-- <lane> repo=… pr=… round=… -->` — and captures the lane, so a third
  lane needs no edit here. A Cursor summary was classifying as `human`, which routed a machine
  verdict into the ACTIONABLE/DISCUSSION/AMBIGUOUS path: the worker could ask a clarifying question
  of a script, then wait for an answer that was never coming. Emitted items gained a `lane` field
  (`review-pr` | `cursor-review` | null). A summary names its own lane; an inline finding does not —
  both lanes write the same lane-neutral tag under the same login — so a thread is attributed
  through the review it belongs to, which costs one extra read-only call to
  `repos/<repo>/pulls/<n>/comments` and is the only way to answer "which reviewer am I replying to".
  The worker's own `<!-- agentic-skills: skill=… -->` marker cannot match the lane pattern (the `:`
  after the name is where it stops) and a test pins that. `references/feedback-triage.md` documents
  the `lane` field and adds a bullet for reviewer summaries — context, read it, never answer it as a
  question — and `references/summary-comment.md` says the reviewer reply rows apply to both lanes
  and that the reply must be threaded, because `cursor-review` follows `in_reply_to_id` to adjudicate
  its prior findings and a top-level reply is invisible to it. SKILL.md is unchanged at 10,226 B.
  SKILL.md gained ~390 B and had to give the same back, so eleven
  passages were compressed — every one of them rationale that is stated in full elsewhere, and no
  guardrail was dropped: Step 0's "an interactive session must not fire scheduled work by accident"
  (this changelog, 2026-09-06); Step 1's `not-draft` and `no-claude-md` glosses (Halt Conditions
  above); Step 2's per-source field list (`references/feedback-triage.md`); Step 3's "`work-on-task`
  keeps the head branch checked out, so `git checkout` in the shared clone fails" and "which stops
  the run" (this changelog, v2.0.0, and Halt Conditions); Step 4's "rather than skipping red
  silently" (`references/feedback-triage.md`, *Visual changes*); Step 5's "only the merge closes the
  issue" and "means origin moved"; Step 6's `gh api … /replies` example, its "resolving a thread is
  deny-listed" and "omit the marker" rationale, and the `daily-summary` prefix gloss (all in
  `references/summary-comment.md`); the Hard rules' subagent rationale (v2.0.2 below) and "the reply
  is the record" (`references/summary-comment.md`); and the Additional resources glosses, shortened
  to one line each. SKILL.md is 10,227 B, the size it was before.
- 2026-09-07: Step 0 now echoes `dry_run=${ROUTINE_DRY_RUN:-0}` for the smoke gate (`make smoke`);
  `BASELINE.md` defines the contract. One sentence was compacted to keep SKILL.md inside the S4
  budget.
- 2026-09-07 (v2.0.2): `disallowed-tools: Agent` in the frontmatter, and a Hard rules line
  saying so. `pr-iterate-night` runs `/iterate-on-pr <number> --repo <owner/repo>` headless, so
  this skill has the exposure that stopped a forked `work-on-task` on 2026-09-07: a skill that
  delegates ends its turn without its `ITERATE:` line, and a return without that line reads as a
  halt. Two passages were trimmed to stay inside the 10 KB budget: the "never mark the PR ready,
  never merge, never force-push" sentence in the opening paragraph (Hard rules says it) and the
  "truncating would drop findings silently" rationale on Step 2's exit-3 halt. Enforced by
  `test_contract_headless_skills_disallow_the_agent_tool`.
- 2026-09-07 (v2.0.1): Arguments now carries the literal `$ARGUMENTS` placeholder. The
  `pr-iterate-night` routine prompt runs `/iterate-on-pr <number> --repo <owner/repo>`, so this
  skill has the same exposure that broke `work-on-task` on 2026-09-07. Two clauses were trimmed to
  stay inside the 10 KB budget: the `environment.md` back-reference in Step 1 (the Additional
  resources list already points there) and the "a broken commit under review costs a whole round"
  rationale in Step 5. Enforced by
  `test_contract_skills_invoked_with_arguments_carry_the_arguments_token`.
- 2026-09-06: Hotfix — removed `disable-model-invocation: true` ahead of the routine PR #27
  schedules. The flag blocks the Skill tool, which is how a headless run reaches a skill its prompt
  names, and it halted four routines on the nights of 2026-09-05 and 2026-09-06. New Step 0 refuses
  a run with `ROUTINE` unset unless `--dry-run` or `--force` is passed, so nothing but the runner
  can start committing and pushing; `--force` is new and `allowed-tools` gained `Bash(echo:*)`.
  Step 2's `kind` bullets moved to `references/feedback-triage.md` and Step 6's reply markers to
  `references/summary-comment.md`, to keep `SKILL.md` inside its 10 KB budget.
- 2026-09-03 (v2.0.0): Rewritten against `docs/skill-standard.md`, closing five audit findings.
  ITERATE-1: Step 3 resolves the clone through `get_repo_path`, finds the branch's existing worktree
  with `git worktree list --porcelain` and creates `.claude/worktrees/pr-<N>` only when none holds
  it — the old Step 4 ran `git checkout` in the shared clone, which git refuses outright for a
  branch `work-on-task` already has checked out in a worktree. ITERATE-2: `review-pr` posts under
  the same login as the human, so the old `type == Bot` filter classified its findings as human
  feedback and the skill never spoke the finding-tag protocol; threads are now classified
  `human | reviewer | bot`, and a reviewer thread is fixed or contested and always answered in-thread
  with an `outcome:` marker, never parked as ambiguous. ITERATE-3: nothing used to mark a thread as
  handled — only general comments had a since-last-summary cut-off — so a second run re-acted on
  every addressed thread; the mandatory reply is now the durable marker, and the cut-off applies to
  threads too. ITERATE-4: `disable-model-invocation: true`, verified safe because no skill invokes
  `Skill(name="iterate-on-pr", …)` and no routine prompt fires `/iterate-on-pr`. ITERATE-5:
  `model: claude-opus-4-8`, `effort: high`, a stated turn and cost ceiling, and `pr-feedback` pages
  with `pageInfo.hasNextPage` and halts past `MAX_THREADS` rather than truncating at `first: 50`.
  Frontmatter gains prefix-scoped `allowed-tools` in place of bare `Bash`; `--dry-run` returns
  before the first worktree, edit or comment; the GraphQL query, the REST calls and the bot list
  moved into `scripts/pr-feedback`, the categorisation and image handling into
  `references/feedback-triage.md`, the summary and marker shapes into
  `references/summary-comment.md`, taking SKILL.md from 15.1 KB to 10,208 B. The Homebrew PATH
  gotcha is gone: `work-on-task/references/environment.md` carries it for both skills. Fixes are
  test-first where a framework exists, as in `work-on-task`. Removed from
  `skill-contract-exceptions.txt`; `tests/unit/test_pr_feedback.sh` covers the classifier.
- 2026-07-14: Baseline split (efficiency assessment D1) — preamble now reads BASELINE.md (core five
  principles) AND BASELINE-CODING.md (relocated coding detail: halt conditions, scope
  circuit-breaker, replace_all discipline, verify/retry rules). No behavioral change.
- 2026-07-08 (v1.0): Assessed — no SKILL.md issues found. Graduated experimental → active on the
  strength of real-PR runs and the v0.2/v0.3 hardening.
- 2026-05-07 (v0.3): Added `replace_all` discipline to Step 6 — surfaced after the first iteration
  run on PR #3, where gendered noun forms in a translated string would have been silently corrupted by a
  naive `replace_all`.
- 2026-05-07 (v0.2): Added the bot-comment filter and the empty-feedback halt, after the first run
  on PR #3 surfaced only deployment-bot notices and no human review feedback.
- 2026-05-07 (v0.1): Initial draft, modeled on work-on-task v0.2 with iteration-specific differences
  (PR target instead of issue; additive commits; image-attachment ingestion; categorisation step).
