---
domain: universal
kind: coding
version: 2.0.2
status: active
last-assessed: 2026-09-03
---

## Purpose
The independent-reviewer half of the PR loop. `work-on-task` opens a draft PR; this skill reviews it against the originating issue's acceptance criteria and the repo's real verify gate, posts findings as inline review threads, and records a verdict a later gate and a human can both read. `iterate-on-pr` then consumes those threads and fixes or contests each finding.

Exists because review is the measured bottleneck: across 57 agent PRs there were zero human review comments, and merge outcome was explained entirely by whether a human sat down that week.

`kind: coding`, not `readonly`: the skill writes review comments, labels and a verdict file. It reads far more than it writes, but the 6 KB read-only budget is for skills that only read and report, and a skill whose writes land on someone else's PR is not one of those.

## Model / budget
- Model: `claude-opus-4-8` — adjudicating a diff against acceptance criteria, and deciding whether an author's reply settles a finding, is the judgement half of the loop; a cheaper model produces findings that cost more to dismiss than they save.
- Effort: `high` — the run reads a whole diff, walks the head-SHA tree to resolve symbols, and runs a build. `medium` was the pre-standard default and produced reviews that anchored on the diff alone.
- Typical run: not yet measured under v2. v1 ran 4-9 minutes on a one-to-three-file diff; the `REVIEW:` line and the metrics file exist so v2 has a before to compare against.

## Dependencies
- `gh` CLI with GraphQL access
- `launchd-runtime/bin/pr-review-bundle` — context isolation, the `src/` tree the gate runs against, and the exit codes Step 2 branches on
- Target repo checked out locally and mapped in `launchd-runtime/repos.conf`'s `get_repo_path` — that is where the bundle archives the head SHA from
- Target repo SHOULD have a root `CLAUDE.md` declaring a verify gate; without one the gate outcome is `no-gate` and the review can never reach `pass`
- `REVIEW_ROUND_MAX`, `REVIEW_NEW_FINDINGS_BY_ROUND`, `REVIEW_FINDINGS_MAX` in `repos.conf`

## Design notes
**The verdict has a reader now.** v1 wrote `verdict.json` into an ephemeral `/tmp` bundle for `launchd-runtime/bin/pr-ready-gate`, a script that was never written — so every verdict this skill ever produced was deleted unread. v2 puts the conclusion in three places with three readers: the first line of the review summary is a marker a future gate can parse without cloning anything, the metrics copy under `$HOME/.agentic-skills/routines/metrics/` is the durable ledger, and the `REVIEW:` line is what the routine log captures.

**Rounds close because the marker is defined.** v1 named an idempotence marker on `(head_sha, round)` without ever saying what it looked like, forbade reading prior review comments, and used `review-round-N` labels that nothing created — so `--add-label` failed on repos that had never seen the label, the round floor never advanced, and round 2 had no way to tell a fixed finding from an ignored one. v2 defines the marker (`head=<sha>` in the summary's first line), creates every label with `gh label create --force` before adding it, and grants round 2 a narrow exception: the reviewer's own threads and the worker's replies to them, never the PR description.

**Label before post.** If a run dies between posting findings and applying `review-round-<K>`, the floor never moves and the PR is reviewed forever at the same round. The reverse failure — a label with no review — costs one wasted round, which the cap absorbs.

**Why the gate runs inside the bundle.** `<bundle>/src` is the head SHA exported with `git archive`, so running the gate there cannot disturb the author's checkout, needs no branch switch, and cannot silently test the wrong commit. A `CLAUDE.md` that declares `NO GATE — verify by reading` (StarBonk's wording) yields `no-gate`, and neither `no-gate` nor `could-not-run` may verdict `pass`: "I read it and it looked fine" is not a verification.

**Two markers, two jobs.** The first line carries the verdict for a machine; the last line is the S6 attribution marker every write in this repo carries, so one grep finds everything a run touched. The idempotence check reads the first, `pipeline-metrics` reads the last.

**The protocol is a separate file on purpose.** `references/review-protocol.md` holds the finding schema, the inline tag, the adversarial checklist, the cap names and the verdict shape, with no Claude-specific instruction and no credentialed write in it. A second reviewer on another model can execute it against the same bundle; the disagreement between two verdicts on one head SHA is the signal this loop currently has no way to produce.

## Known Issues
- Reviewer and author are the same model and account. Independence is structural (the bundle omits the PR body and commit messages) rather than genuine third-party review — which is what the model-agnostic protocol exists to fix.
- Cannot approve: `viewerDidAuthor: true` under the single account, so GitHub rejects `event: APPROVE`. `COMMENT` is the only usable event, which is why the verdict lives in the marker rather than in a review state.
- A `no-gate` repo's review rests entirely on reading. StarBonk is the standing example and its open PRs cannot be verified by any gate today.
- A contested finding is recorded and escalated, never adjudicated by fiat.
- A repo missing from `repos.conf`'s `get_repo_path` map gets no `src/`, so the outcome is `could-not-run` for a reason that has nothing to do with the repo's own tooling. `meta.json`'s `bundle.src_note` records which case it was.
- The `pr-ready-gate` consumer still does not exist. Until it does, the marker is read by a human.

## Changelog
- 2026-09-07: Step 0 now echoes `dry_run=${ROUTINE_DRY_RUN:-0}`, the channel the smoke gate
  (`make smoke`) reaches this skill's dry run through; `BASELINE.md` defines the contract.
- 2026-09-07 (v2.0.2): `disallowed-tools: Agent` in the frontmatter, and a Hard rules line
  saying so. `pr-review-night` runs `/review-pr <number> --repo <owner/repo>` headless, so this
  skill has the exposure that stopped a forked `work-on-task` on 2026-09-07: a skill that
  delegates ends its turn without its `REVIEW:` line, and a return without that line reads as a
  halt. Two passages were trimmed to stay inside the 10 KB budget: the "never mark a PR ready,
  never merge, never push" sentence in the opening paragraph (Hard rules says it) and the "Why
  `COMMENT`, and why inline threads" pointer in Step 5 (Step 4 already sends the reviewer to
  that reference). Enforced by `test_contract_headless_skills_disallow_the_agent_tool`.
- 2026-09-07 (v2.0.1): Arguments now carries the literal `$ARGUMENTS` placeholder. The
  `pr-review-night` routine prompt runs `/review-pr <number> --repo <owner/repo>`, so this skill
  has the same exposure that broke `work-on-task` on 2026-09-07. Enforced by
  `test_contract_skills_invoked_with_arguments_carry_the_arguments_token`.
- 2026-09-06: Hotfix — removed `disable-model-invocation: true` ahead of the routine PR #27
  schedules. The flag blocks the Skill tool, which is how a headless run reaches a skill its prompt
  names, and it halted four routines on the nights of 2026-09-05 and 2026-09-06. New Step 0 refuses
  a run with `ROUTINE` unset unless `--dry-run` or `--force` is passed, so nothing but the runner
  can start a review; `--force` is new and `allowed-tools` gained `Bash(echo:*)`. Step 3's gate
  outcome table, Step 5's `event: COMMENT` rationale and Step 4's budget detail moved to
  `references/review-protocol.md` to keep `SKILL.md` inside its 10 KB budget.
- 2026-09-03 (v2.0): Rewritten to `docs/skill-standard.md`. The verdict gained a reader (first-line marker, metrics copy, `REVIEW:` line) after the discovery that `pr-ready-gate` was never written; the `(head_sha, round)` marker is now defined and checked, `review-round-<K>` and `review-escalated` are created with `gh label create --force`, and round 2 may read its own threads to adjudicate. The gate runs inside `<bundle>/src` at the head SHA, with four named outcomes; `no-gate` and `could-not-run` can never reach `pass`. New `references/review-protocol.md` carries a model-agnostic review contract and a five-item adversarial checklist. Caps moved to `repos.conf` (`REVIEW_ROUND_MAX`, `REVIEW_NEW_FINDINGS_BY_ROUND`, `REVIEW_FINDINGS_MAX`); added `--dry-run`.
- 2026-09-03 (v1.1): `pr-review-bundle` now delivers what the skill always claimed to read. `acceptance-criteria.md` was built from the `body` of `closingIssuesReferences`, which gh 2.92 does not return, so every bundle ever built carried the "(issue body empty)" placeholder and no review has seen an acceptance criterion; the issue is now fetched explicitly and ONLY its `## Acceptance criteria` section is written. The bundle also exports the source tree at the head SHA under `src/` (`git archive`, no `.git`), which the gate and "cite a symbol you resolved yourself" both needed and neither had. `tree.txt` is now bounded to the directories the diff touches — the recursive listing it replaced was 427 KB (5,649 paths, ~107k tokens) on StarBonk regardless of what the diff contained. New advisory exits: 5 (PR closes no issue), 6 (no criteria section); only 4 still refuses.
