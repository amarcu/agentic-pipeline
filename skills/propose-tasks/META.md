---
domain: universal
kind: coding
version: 2.0.1
status: active
last-assessed: 2026-09-04
---

## Purpose
The autonomous maintenance sweep. For one repo whose direction is *not* human-led, it surveys the
signals a machine can read — untriaged issues, TODO comments in live code, recent commits, thin
docs — and cuts up to `MAX_PER_RUN` issues labelled `proposed`, `shape:chore` and `size:` for the
human to approve.

It is the maintenance half of a pair. `plan-features` runs the weekly design conversation and cuts
the features; this skill takes the repos that have no `agent/FOCUS.md` and keeps them from silting
up. Step 2 is where the two meet: a repo carrying `agent/FOCUS.md` halts here, and its issues come
from the design session instead. That division is why this skill never proposes `shape:feature` —
a feature nobody discussed is a feature nobody wants, and the TODO sweep structurally produced
test-only proposals in the repos that do have a focus.

```
propose-tasks (chores) ─┐
                        ├─→ human approves → dispatch-tasks → work-on-task → review-pr
plan-features (features)┘
```

`kind: coding` — it writes: labels and issues in someone else's repo.

## Model / budget
- Model: `claude-sonnet-5` — the run is a survey and a filter. Ranking four signal sources against a
  `CLAUDE.md` CAN list and writing a scoped issue body is judgement a mid-tier model makes well; the
  expensive model is reserved for `plan-features`, where the output sets the direction rather than
  keeping the lights on. The user's decision, 2026-09-04.
- Effort: `medium` — `low` is too little for the ranking step, which has to hold four candidate
  sources and a constraints file in mind at once. `high` buys nothing: nothing here needs a long
  chain of reasoning, and the ceiling of two issues caps what more thinking could produce.
- Typical run: not yet measured under v2. v1 ran roughly 2-4 minutes per repo under the
  morning-proposals routine, most of it in the TODO grep and the issue-list calls.

## Limits (named here, valued in SKILL.md and repos.conf)
- `MAX_PER_RUN`, `MIN_TO_PROPOSE`, `SATURATION` — this skill's own, stated once in SKILL.md's
  `## Limits` block.
- `PROPOSED_BACKLOG_MAX` — the cross-repo gate, in `launchd-runtime/repos.conf`, read by the
  `morning-proposals` routine. Not this skill's number and not restated here.

## Halt Conditions
Every one of these leaves no trace beyond a single `HALT:` line on stdout.

1. **Human-led direction** — `agent/FOCUS.md` exists without a line reading exactly
   `propose-tasks: allowed`. Prints the fixed line `HALT: <owner/repo> | direction is human-led
   (agent/FOCUS.md present) — use /plan-features`, which `morning-proposals` matches on its stable
   prefix and counts as a quiet repo rather than a failure.
2. **Repo not in `get_repo_path`** — the map is the contract; the alternative is a filesystem scan.
3. **No root `CLAUDE.md`** — nothing states what this repo may be asked for, so a proposal is blind.
4. **Saturation** — `SATURATION` or more unapproved `proposed` issues already open here.
5. **Nothing above the bar** — fewer than `MIN_TO_PROPOSE` candidates survive ranking, or every
   survivor duplicates an issue an earlier run already wrote.

## Dependencies
- `gh` CLI, authenticated for the target repo
- Target repo mapped in `get_repo_path` and holding a root `CLAUDE.md`
- `launchd-runtime/bin/telegram-send` — only under `--notify`; the recipe and its constraints belong
  to `notify`
- `ROUTINE` / `ROUTINE_RUN_ID`, exported by `launchd-runtime/bin/_run.sh` and stamped into every
  issue body; an interactive run gets the documented defaults

## Design notes
**One ceiling, one place.** Before v2 the cap and the saturation threshold were stated in seven
places that disagreed: the role paragraph said two, `--max` defaulted to five, Step 4 picked
`min(--max, 5)`, Step 5 required two candidates before proposing anything, the hard rules forbade
more than five and named a saturation threshold of five, Step 2 used two, and META and README each
carried "3-5". A reader could not tell what a run would do, and neither could the skill. v2 states
`MAX_PER_RUN`, `MIN_TO_PROPOSE` and `SATURATION` once each in `## Limits` and names them everywhere
else.

**`--max` may only lower.** It is an argument, and an argument that can raise a ceiling is not a
ceiling. A larger value is clamped, never obeyed.

**One digest, not one per repo.** v1 sent a Telegram per repo, so a seven-repo morning could produce
seven messages for one event. The send moved out to `morning-proposals`, which already aggregates,
and the skill now prints `PROPOSED:` and `HALT:` lines to stdout — auditable, and free. `--notify`
keeps a per-run send for a human running the skill by hand.

**The plan is advisory and its paths are checked.** A worker reading an issue treats
`## Implementation plan` as advice, not instruction, and `work-on-task` re-checks every path anyway.
Checking them at proposal time is what stops a plan being a guess.

## Known Issues
- Timing is not measured under v2, so the Model / budget line has no observed cost to compare a
  routing change against.
- The duplicate check reads two lists, whoever filed their issues: every open issue, and every
  closed one labelled `retired` (`references/duplicates.md`), each bounded by `--limit 500` —
  omitted, `gh` pages 30, which is narrower than the `--limit 60` this replaced. 500 is several
  times the whole issue history of every repo on the roster. Two gaps remain: an issue a human rewrote past recognition no longer
  carries the signal that would match it, and a closure without the label — closed as completed,
  closed in the wrong repo — says nothing here, deliberately.
- The saturation count reads open `proposed` issues only. An unapproved proposal a human closed and
  reopened elsewhere is invisible to it.

## Changelog
- 2026-09-07: Step 0 now echoes `dry_run=${ROUTINE_DRY_RUN:-0}` for the smoke gate (`make smoke`);
  `BASELINE.md` defines the contract. Three sentences were compacted to keep SKILL.md inside the
  S4 budget.
- 2026-09-06: Hotfix — removed `disable-model-invocation: true`. It blocks the Skill tool, the only
  path `morning-proposals` has to this skill headlessly, so that routine halted on 2026-09-05 and
  2026-09-06. New Step 0 refuses a run with `ROUTINE` unset unless `--dry-run` or `--force` is
  passed; `--force` is new. Step 4's four signals moved to `references/signal-recipes.md` to keep
  `SKILL.md` inside its 10 KB budget.
- 2026-09-04 (v2.0.1): Review fixes on PR #24. Steps 1 and 2 described commands that could not do
  what the prose claimed. Step 1 used `$REPO`, `$REPO_PATH` and `$BASE` without ever assigning
  them, and `VAR=$(...)` is denied headlessly, so `test -f "$REPO_PATH/CLAUDE.md"` would have run
  against an empty path and refused for the wrong reason; every value is now substituted literally,
  with the Steps preamble saying so once and the source-plus-lookup kept in one command because
  sourcing does not survive into the next call. Step 2's check exited nonzero both when
  `agent/FOCUS.md` was absent — the normal case — and when it existed without the opt-in line, so a
  runner reading the status could not tell a quiet repo from a halt; it now prints `halt` or
  `proceed` and exits 0 either way, and the Output contract states that every halt prints its line
  and exits 0 so the routine moves to its next repo. `allowed-tools` dropped
  `Bash(gh auth status:*)` and `Bash(ls:*)`, neither of which the body runs.
- 2026-09-04 (v2.0.0): Rewritten to `docs/skill-standard.md`; off the contract-exceptions list.
  Frontmatter gains `disable-model-invocation: true` (the only callers are the `morning-proposals`
  prompt and a human), `model: claude-sonnet-5` / `effort: medium` (S2), and `allowed-tools` scoped
  to the commands the body runs, replacing bare `Bash`, `Read` and an unused `Write`. Body reordered
  into the S3 sequence with a Contract block and a check on every step; SKILL.md 14,140B → 10,168B
  by moving the TODO grep recipes to `references/signal-recipes.md` and the issue body template to
  `references/issue-template.md`, and by dropping the reviewer-facing explanation and the duplicate
  "Reporting back" block. **Role narrowed:** this is the maintenance sweep beside `plan-features`,
  and every issue it cuts is now `shape:chore` with a `size:` label. **Template:** adopts
  `plan-features`' sections — `## Breakdown`, `## Implementation plan (advisory)` (≤ 6 numbered
  steps, each naming its files, every path `test -e`-checked, and never the phrase "depends on"),
  `BASE BRANCH:` and the S6 attribution marker. **Caps:** `MAX_PER_RUN`, `MIN_TO_PROPOSE` and
  `SATURATION`, each valued exactly once in SKILL.md's `## Limits` block and named everywhere else,
  replacing seven statements that disagreed. **Telegram:** the per-repo send is gone; `morning-proposals`
  sends one aggregated digest and this skill prints `PROPOSED:` / `HALT:` lines, with `--notify`
  (default off) keeping a manual per-run send. Added the `--dry-run` that returns before the first
  `gh issue create`, and the S7 duplicate check against the skill's own marker.
- 2026-09-03 (v1.1.1): Defers to human-led direction — Step 0.5 resolves the repo path via
  `get_repo_path` and halts before any signal gathering when `agent/FOCUS.md` exists without a
  `propose-tasks: allowed` line. Repos running the weekly design session get their issues from
  `plan-features`; the TODO sweep structurally produced test-only proposals there.
- 2026-07-14 (v1.1.0): Efficiency pass (assessment items D1/D7/P-fixes) — line-count exclusion and
  quiet-day rationale trimmed to BASELINE P2/P5 citations (keeps the `.cursorrules` caveat and the
  saturation-halt rule); TODO grep now excludes `.claude`/vendored dirs and caps output with `head`;
  Telegram sends rewritten around the shared `launchd-runtime/bin/telegram-send` (literal
  `/tmp/propose-tasks-digest.txt` heredoc + single unchained `python3` call, `[ -n ... ]` credential
  checks, no `rm`, no chaining).
- 2026-09-14 (v2.1): The duplicate check stopped filtering on this skill's own marker and stopped
  stopping at 60 issues, both of which let retired work come back (issue #62). It now reads every
  open issue and every closed one labelled `retired`, whoever filed it — a bare close still says
  nothing, because issues close for reasons that are not decisions. The queries and the rule moved to
  `references/duplicates.md`.
- 2026-07-08 (v1.0): Assessed. Graduated experimental → active — scheduled since 2026-05-12 with
  real proposals shipped. Operational note: club-site had five unapproved proposals open since
  2026-05-28, so the skill had been correctly saturation-halting there.
- 2026-05-07 (v0.1): Initial draft. Modeled on iterate-on-pr v0.3 patterns (empty-feedback halt;
  CLAUDE.md as constraint source; explicit-path discipline; conservative defaults).
