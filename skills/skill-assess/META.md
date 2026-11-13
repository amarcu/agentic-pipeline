---
domain: meta
kind: meta
version: 2.0.0
status: active
last-assessed: 2026-09-04
---

## Purpose
The weekly audit of this repo's own skill library. Since `docs/skill-standard.md` landed, most of
what this skill used to read for is checked mechanically by `launchd-runtime/tests/static/`, so the
skill's job is now to run that suite, turn every `FAIL` and `WARN` into a finding, and spend its
model budget only on the two questions no grep settles: whether a skill's `description` still
describes its body, and whether the paths and commands that body names still resolve. It is the
only skill that may write another skill's `META.md`, and it may do so only interactively.

`kind: meta`: it operates on this repo's own skills rather than on a product codebase.

## Schedule
Mondays at 04:20 on the pipeline host, via `com.agentic-skills.routines.skill-assess-weekly` and the prompt
`launchd-runtime/prompts/skill-assess-weekly.md`. It sits after the 04:00–04:10 batch so it audits
a tree the night's routines have finished touching. Before 2026-09-04 it had no schedule at all and
had not run since 2026-07-09 — the skill existed, nothing fired it.

## Model / budget
- Model: `claude-sonnet-5` — the expensive half of the old skill was reading thirteen `SKILL.md`
  files in full; the suite does that work now. What is left is reading a handful of changed files
  and judging whether a sentence still matches a body, which does not need Opus.
- Effort: `medium` — `low` cannot hold a whole `SKILL.md` against its `description`; `high` would
  spend on clerical diffing the suite already did.
- Typical run: not yet measured on this version. The routine sets `ROUTINE_CAPTURE_JSON=1`, so the
  first Monday run writes a row to `metrics/runs.jsonl`; record the figure here after it lands. The
  old version has no comparable figure — it was never scheduled.

## Dependencies
- `launchd-runtime/tests/run.sh` — the static suite is the assessment's deterministic half
- `git` — `git log -1` per skill decides what gets read; `git rev-parse` stamps the report
- `gh` CLI, authenticated, with issue and label write on `ASSESSMENT_TARGET_REPO`
- `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`, only on an `--update` run with findings
- `launchd-runtime/bin/telegram-send` — the one sender; the recipe is `notify`'s to state

## Halt Conditions
- **`no-findings`** — Action required is zero. The report prints to stdout, no issue is filed and
  no Telegram is sent. This is BASELINE Principle 5 and it is the common case: a week in which
  nothing regressed should leave no trace. Pending-rewrite and stale entries do not count as
  findings for this purpose — the first are tracked in `skill-contract-exceptions.txt` and the
  second need a human's read, not a ticket.
- **`already-filed <skill>`** — an open `skill-maintenance` issue already carries this finding's
  `target=` marker. Nothing is written for it; the run continues with the next finding.
- **`suite-unrunnable`** — `tests/run.sh static` exited non-zero without printing a `FAIL` line, so
  the assessment has no deterministic half. Report and stop rather than guess.

## Known Issues
- **`--update` writes issues but not `META.md` files.** The old Step 4 wrote `last-assessed:` and
  changelog lines into every skill's `META.md` on a headless run. That is now refused: nobody
  reviews wording that lands in a file the next run reads back, and a wrong line there is invisible
  until it misleads the following assessment. `META.md` updates are an interactive job.
- **`--skills-dir` is gone.** `allowed-tools` scopes the test runner by absolute path, and a
  prefix is a literal string, so the skill can only run the suite of the checkout it names. A
  worktree audit means invoking the skill from a checkout whose path matches, or running
  `tests/run.sh static` by hand.
- **The judgement pass trusts `last-assessed:`.** A skill whose `META.md` was touched without a
  real assessment reads as current and is not re-read. The suite still checks it either way.

## Changelog
- 2026-09-07: Step 0 now echoes `dry_run=${ROUTINE_DRY_RUN:-0}`, the channel the smoke gate
  (`make smoke`) reaches this skill's dry run through; `BASELINE.md` defines the contract.
- 2026-09-06: Hotfix — removed `disable-model-invocation: true`, which blocked the Skill tool that
  `skill-assess-weekly` reaches this skill through headlessly (the 2026-09-05/06 routine outage).
  Step 0 now refuses a run with `ROUTINE` unset unless `--dry-run` or `--force` is passed, which is
  the guard the flag was standing in for; `--force` is new.
- 2026-09-04 (v2.0.0): Rewritten against `docs/skill-standard.md`; off
  `skill-contract-exceptions.txt`. **Scheduled for the first time** —
  `com.agentic-skills.routines.skill-assess-weekly` fires `/skill-assess --update` at 04:20 on Mondays;
  the skill had been silent since 2026-07-09 because nothing invoked it. The cat-every-file loop is
  replaced by one `tests/run.sh static` call whose `FAIL`/`WARN` lines are the findings, plus a
  `git log` per skill so only the skills whose `SKILL.md` postdates their `last-assessed:` are read
  in full. The coding and read-only rosters are derived from `META.md`'s `kind:` instead of the two
  hardcoded lists that had disagreed with it since `kind:` was introduced. Telegram now fires only
  when Action required is above zero, where it previously fired on every `--update` run.
  `--update` creates the `skill-maintenance` and `automated` labels before filing — neither exists
  on this repo, so every previous `--update` run would have failed at the first `gh issue create` —
  and checks for its own `target=` marker first, so a re-run files nothing twice. Added `--dry-run`,
  the `ASSESS:` output-contract line, the S6 marker on every issue body, and prefix-scoped
  `allowed-tools` in place of bare `Bash, Read, Write`. Dropped `--skills-dir` and headless
  `META.md` writes (see Known Issues). Body split: the report template into
  `references/output-format.md`, the filing procedure into `references/issue-filing.md`.
- 2026-07-08 (v1.2.0): Fixed Step 0/1 skill discovery to enumerate only directories containing a
  `SKILL.md`. The old grep filter let the non-skill `anchor/`, `docs/` and `Makefile` entries
  through after they were added to the repo.
- 2026-05-11 (v1.1.0): Re-scoped to agentic-skills only, removed coupling to any external skill
  repo. Added the baseline-conformance check to Step 2. Parameterised the target repo via
  `ASSESSMENT_TARGET_REPO`. Assessed against BASELINE.md.
- 2026-05-06 (v1.0.0): Initial version.
