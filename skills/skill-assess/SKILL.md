---
name: skill-assess
description: Weekly audit of this repo's own skill library — runs the static suite, turns every FAIL and WARN into a finding, then reads only the skills whose SKILL.md moved since they were last judged. Use when a weekly routine has to report which skills are broken, stale, or no longer match the codebase they describe.
argument-hint: "[--skill <name>] [--update] [--force] [--dry-run]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/../../launchd-runtime/tests/run.sh:*), Bash(git log:*), Bash(git rev-parse:*), Bash(gh issue:*), Bash(gh label:*), Bash(cat:*), Bash(ls:*), Bash(test:*), Bash(grep:*), Bash(echo:*), Bash(/usr/bin/python3 ${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/telegram-send:*), Read
model: claude-sonnet-5
effort: medium
---

# Skill Assess

You are the auditor of this repo's own skill library. You produce one assessment report on stdout
and, under `--update`, one GitHub issue per finding that needs attention. You never edit a
`SKILL.md`, never look at another skill repository, and never send on a clean week.

## Limits

- Roster: every top-level directory of this repo holding a `SKILL.md`, minus any whose name starts
  with `_`. `install.sh` applies the same rule, so the two never disagree.
- Coding skills are the ones whose `META.md` says `kind: coding`, read-only ones `kind: readonly`.
  Derive both at runtime; a copy in this file is what made them wrong for four months.
- Issue target: `amarcu/agentic-pipeline`, overridable through `ASSESSMENT_TARGET_REPO`.

Read `${CLAUDE_SKILL_DIR}/BASELINE.md` first and apply its
five principles throughout.

## Arguments

- `--skill <name>` — assess this one skill only (default: the whole roster).
- `--update` — file issues and send one Telegram (default: report, write nothing).
- `--dry-run` — with `--update`, every read and decision and the titles it would file, then return
  before the first `gh label create`.

## Contract

- **Refuses when**: `ROUTINE` is unset and neither `--dry-run` nor `--force` was passed; or
  `BASELINE.md` is not at the repo root — the wrong checkout, and nothing below would mean
  anything.
- **Writes**: under `--update` only — two labels, one issue per Action-required finding, one
  Telegram. Never a `SKILL.md`, never another repo, never anything on a plain run.
- **Halts**: `no-findings` when Action required is zero (report only);
  `already-filed <skill>/<slug>` when an open issue carries that finding's `target=` and
  `finding=`; `suite-unrunnable` when the suite cannot execute.
- **Budget**: one suite run, one `git log` per skill, a full read of only the skills that moved.

## Steps

### Step 0 — Fix the checkout and the roster

```bash
echo "routine=${ROUTINE:-interactive} dry_run=${ROUTINE_DRY_RUN:-0}"
test -f ${CLAUDE_SKILL_DIR}/../../BASELINE.md
git rev-parse --short HEAD
ls ${CLAUDE_SKILL_DIR}/../*/SKILL.md
grep -l '^kind: coding$' ${CLAUDE_SKILL_DIR}/../*/META.md
```

Only `launchd-runtime/bin/_run.sh` exports `ROUTINE`. When the echo prints `interactive` and
neither `--dry-run` nor `--force` was passed, print `HALT: skill-assess interactive-run-refused
(set --dry-run or --force)` and exit 0 before anything below: an interactive session must not
fire scheduled work by accident.

`[!_]*` is the exclusion, in the glob rather than in a filter afterwards — the same rule
`install.sh` and the static suite apply, and the reason both globs need it: `_templates/META.md`
declares `kind: coding|readonly|meta`, which an unanchored `^kind: coding` matches, so a plain
`*/META.md` reports the skeleton as a coding skill. `--skill <name>` narrows the roster to one
entry here and changes nothing else.

→ verify: `ROUTINE` was set or a flag was passed, no `_`-prefixed entry is in either listing, and
the coding list came from `META.md`.

### Step 1 — Run the static suite; every FAIL and WARN is a finding

```bash
${CLAUDE_SKILL_DIR}/../../launchd-runtime/tests/run.sh static
```

The deterministic half of the assessment, and it replaces reading every file. Each
`FAIL: <skill>: <msg>` is an **Action required** finding; each `WARN:` line is advisory, quoted in
the report and never filed. A non-zero exit with no FAIL line is `HALT: skill-assess
suite-unrunnable`.

→ verify: every FAIL and WARN the suite printed appears in the report exactly once.

### Step 2 — Read only what moved

Per skill in the roster:

```bash
grep -E '^last-assessed:' <skill>/META.md
git log -1 --format=%ad --date=short -- <skill>/SKILL.md
```

A commit date no later than `last-assessed:` means nothing changed since the skill was last judged:
record `ALL GOOD` and read nothing. Otherwise read that one `SKILL.md` for the two questions no
grep settles — does the `description` still describe what the body does, and do the paths, scripts
and commands the body names still resolve (`test -f`, `ls`). One that does not is Action required.

Record a failure and move on: an assessment produces findings, not fixes. Age alone is not a
finding — a skill nothing has touched is a skill nothing has broken.

→ verify: the count of `SKILL.md` files read equals the count of skills whose last commit postdates
their `last-assessed:`.

### Step 3 — Print the report

`${CLAUDE_SKILL_DIR}/references/output-format.md` holds the template, every field's meaning and
which sections print when empty. Read it here; nothing below restates it.

→ verify: `ASSESS:` is the first line printed and its `skills=` equals the roster size.

### Step 4 — Halt when there is nothing to act on

Action required at zero ends the run: the report is the whole output, no `gh` call, no Telegram.

→ verify: `HALT: skill-assess no-findings` printed and no `gh issue create` ran.

### Step 5 — File the issues (`--update` only)

`${CLAUDE_SKILL_DIR}/references/issue-filing.md` holds the two `gh label create` calls the labels
need before they can be applied, how a finding's `finding=<slug>` is derived, the one list call the
idempotence check reads, the create command and the marker every body ends with. The check matches
`target=` **and** `finding=` together — on `target=` alone, a skill's second finding reads as
already filed and never gets an issue. **`--dry-run` returns here**, before the first label call.

→ verify: each created body contains `skill=skill-assess` and a `finding=` slug, no two created
issues share a `target=`/`finding=` pair, and the created count equals `issues=`.

### Step 6 — One Telegram, only when Action required is above zero

Write the counts and issue links to `/tmp/skill-assess-digest.txt`, then send that file with the
two unchained commands `notify` specifies — the literal path, no chaining, no retry.

→ verify: stdout reads `sent message_id=<id>` once — or Step 4 halted and the sender never ran.

## Output contract

```
ASSESS: run=<id> checkout=<sha7> skills=<n> findings=<f> issues=<i>
HALT: skill-assess <reason>
```

`ASSESS:` is the first line of the run's output; any `HALT:` lines follow it.

## Hard rules

- Never edit a `SKILL.md`, and never write a `META.md` headlessly — nobody reviews wording that
  lands in a file the next run reads back.
- Never read from or port anything out of another skill repository; `_templates/` is the reference
  for what a well-formed skill looks like.
- Never smoke-test a skill's write or publish step; read-only commands only.
- Telegram goes through the `notify` recipe and nowhere else (S8). Quiet by default — BASELINE
  Principle 5.
- Never `gh pr ready`, never `gh pr merge`, never force-push — BASELINE, *Merging and Marking PRs
  Ready*.
- A denied command is a stop signal, not a workaround puzzle — BASELINE, *Respect the Denial*.

## Additional resources

- `${CLAUDE_SKILL_DIR}/references/output-format.md` — the report template, its fields and the
  Telegram shape. Read at Step 3.
- `${CLAUDE_SKILL_DIR}/references/issue-filing.md` — labels, idempotence check, create call, marker.
  Read at Step 5, only under `--update`.
- `${CLAUDE_SKILL_DIR}/../../docs/skill-standard.md` — the ten rules the
  static suite half-enforces. Read before judging whether a finding is real.
- `${CLAUDE_SKILL_DIR}/../notify/SKILL.md` — the one send recipe. Read
  before touching Step 6.
