---
name: skill-name
description: One sentence saying what this skill does, then the trigger clause. Use when <the situation that should make Claude reach for this>.
argument-hint: "<required-arg> [--flag <value>] [--dry-run]"
allowed-tools: Bash(gh issue:*), Bash(gh pr:*), Read
model: claude-opus-4-8
effort: medium
---

<!--
  Copy this directory, rename it, and fill it in. The standard every field and
  section below answers to is docs/skill-standard.md — read it once before you
  start; the rules are referenced by number here (S1…S10).

  Frontmatter (S1, S2):
    name                      must equal this directory's name
    description               must end in a "Use when …" clause
    argument-hint             every --flag here must appear in Arguments below
    disable-model-invocation  omitted by default, and ADDED only for a skill a
                              human types that must never run unattended. Never
                              on one a routine prompt runs or another skill
                              invokes through the Skill tool: both go through
                              that tool, which the flag blocks, and the call
                              then silently does nothing. Guard a routine skill
                              with the Step 0 ROUTINE/--force precondition.
    allowed-tools             prefix-scoped Bash entries only — never bare Bash.
                              Non-Bash tool names (Read, Edit, Skill) go bare.
    model, effort             what THIS skill needs. The runner's --model /
                              --effort are the fallback, not the decision.
  Delete this comment block when the skill is written.
-->

# Skill Name

<!-- Role paragraph (S3.1) — exactly three sentences: who you are, what you
     produce, what you never do. No preamble above it. -->

You are <role>. You produce <the one artefact or side effect this skill exists for>. You never
<the one thing a reader might otherwise assume you do>.

## Limits

<!-- S3.2 / S5 — the constraints this skill runs under, BY NAME ONLY. The values
     live in launchd-runtime/repos.conf and are read at runtime. Never restate a
     number here; a number in two files is a number that will disagree. -->

- Repo roster: `ACTIVE_REPOS` from `launchd-runtime/repos.conf`.
- Cap: `<CAP_IDENTIFIER>` from the same file — read it, do not restate it.

<!-- S3.3 — the baseline citation, one line, absolute path. Skills that write
     code cite BASELINE-CODING.md on the same line. -->

Read `${CLAUDE_SKILL_DIR}/BASELINE.md` first and apply its five
principles throughout.

## Arguments

<!-- S3.4 — one bullet per argument, matching argument-hint exactly (S1). -->

- `$0` — <required argument, what it means>
- `--flag <value>` — <what it changes> (default: `<default>`)
- `--dry-run` — do every read and decision, print the output-contract lines, return before the
  first mutating call (S7)

## Contract

<!-- S3.5 — the four lines a reader checks before trusting this skill with a
     scheduled run. Keep them to one line each. -->

- **Refuses when**: <the preconditions that make this skill exit before doing anything>
- **Writes**: <every artefact this skill creates or mutates, and nothing else>
- **Halts**: <the conditions that stop a run mid-flight, and what it prints>
- **Budget**: <the ceiling on work per run — items, repos, retries — named, not numbered>

## Steps

<!-- S3.6 — numbered, each ending in its own check. A step without a check is a
     step whose failure is invisible. Move any fixed procedure into
     ${CLAUDE_SKILL_DIR}/scripts/ rather than describing it here (S4). -->

### Step 1 — <what this step establishes>

```bash
<the command>
```

→ verify: <the observable that proves the step worked>

### Step 2 — <…>

→ verify: <…>

### Step 3 — write, with the attribution marker

<!-- S6 — every issue body, PR body and review summary ends with this marker.
     S7 — check for it BEFORE writing: if it is already there, HALT and exit 0. -->

```html
<!-- agentic-skills: skill=skill-name repo=<owner/repo> issue=<n> routine=${ROUTINE:-interactive} run=${ROUTINE_RUN_ID:-none} model=<id> -->
```

→ verify: the created object's body contains `skill=skill-name`

## Output contract

<!-- S3.7 / S6 — the exact parsable stdout lines this skill emits. One line per
     unit of work. Nothing else in the output may look like one. -->

```
PROPOSED: <owner/repo>#<issue> <title>
HALT: skill-name <reason>
```

## Hard rules

<!-- S3.8 / S9 — one-line citations, not restatements. If a rule needs more than
     a line, it belongs in BASELINE.md where every skill gets it. -->

- Never `gh pr ready`, never `gh pr merge`, never force-push — BASELINE, *Merging and Marking PRs
  Ready*.
- Anything sensitive, irreversible or externally visible goes through `/request-approval`, which
  stops the run.
- Telegram goes through `/notify` and nowhere else (S8). Quiet by default — BASELINE Principle 5.
- A denied command is a stop signal, not a workaround puzzle — BASELINE, *Respect the Denial*.

## Additional resources

<!-- S4 — link every supporting file with a sentence saying what it holds and
     when to open it. An unreferenced file is a file that never loads. Address
     them through ${CLAUDE_SKILL_DIR}, never a relative or hardcoded path. -->

- `${CLAUDE_SKILL_DIR}/references/<topic>.md` — <what it holds, when to read it>
- `${CLAUDE_SKILL_DIR}/scripts/<name>.sh` — <what it does, when to run it>
