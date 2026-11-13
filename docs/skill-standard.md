# The skill definition standard

Every `SKILL.md` in this repo must meet the ten rules below. They are written for whoever is
authoring or rewriting a skill — a person or an agent.

Two of the ten are checked at commit time. S1 and S2 are enforced in full by
[`test_skill_contract.sh`](../launchd-runtime/tests/static/test_skill_contract.sh), which also
checks the `kind:` field of S10 and S3's `$ARGUMENTS` placeholder; S5 is enforced separately by
`test_cap_names.sh`. The rest — body order, attribution, idempotence, the
Telegram path, the safety citations — no grep can settle, so they are on the author and the
reviewer. A green suite means a
skill has not broken the mechanical rules, not that it meets the standard.

The rules exist because an audit of the eleven skills in this repo scored them 33–40 out of 56
against a rubric built from Anthropic's own skill-authoring guidance. Nothing was broken; the
problem was that every skill had solved the same five problems — argument parsing, Telegram,
caps, halts, attribution — a slightly different way, so a fix in one never reached the others.
The standard is what a rewrite lands into. The test is what keeps it there.

Every skill has been migrated, so every contract failure fails the suite.

---

## S1 — Frontmatter complete and scoped

*A skill that names itself wrong, or asks for `Bash`, is a skill nobody can reason about from its
first eight lines.*

The frontmatter is a `---`-delimited block of `key: value` lines at the top of the file. Only
fields Claude Code documents may appear (`name`, `description`, `when_to_use`, `argument-hint`,
`arguments`, `disable-model-invocation`, `user-invocable`, `allowed-tools`, `disallowed-tools`,
`model`, `effort`, `context`, `agent`, `background`, `hooks`, `paths`, `shell`, `metadata` — see
<https://code.claude.com/docs/en/skills.md>). Six of them carry obligations here:

- **`name` equals the directory name.** For a personal or project skill the command comes from the
  directory, so a `name` that disagrees produces a skill whose listing label and invocation differ.
- **`description` ends with a "Use when …" trigger clause.** The description is the only thing in
  context before the skill loads; it is what Claude reads to decide whether to load it. Say what
  the skill does, then say when to reach for it: *"… Use when a routine needs a human decision
  before an irreversible action."*
- **`argument-hint` matches the body's Arguments section.** Every `--flag` in the hint is
  documented in the body, and every flag the body parses appears in the hint. A flag that exists in
  one and not the other is a flag that silently does nothing.
- **`allowed-tools` is prefix-scoped.** Write `Bash(gh issue:*)`, `Bash(git commit:*)`,
  `Bash(${CLAUDE_SKILL_DIR}/scripts/render.sh *)` — never bare `Bash`. The field pre-approves tools
  for the invoking turn without prompting, so bare `Bash` hands a scheduled run an unreviewed shell.
  Non-Bash tool names (`Read`, `Edit`, `Skill`) may be listed bare; they are not a command surface.
- **`disable-model-invocation: true`** goes ONLY on a skill a human types interactively and that
  must never run unattended — `plan-features`, `triage-repo`. **Never on a skill
  a routine prompt runs by `/name`, and never on one another skill invokes through the `Skill`
  tool.** Both reach the skill the same way: a headless `claude -p` run is handed its routine prompt
  as natural language, so it is the model that invokes the skill, through the Skill tool — the one
  path this flag blocks. With it set the caller is told the skill is `/name`-only and the call
  silently does nothing, no error and no work. That is what stopped `morning-triage`,
  `morning-proposals`, `dispatch-tasks-night` and `daily-summary-routine` on the nights of
  2026-09-05 and 2026-09-06, and what a five-run probe on 2026-09-03 had already shown for
  skill-to-skill calls (`work-on-task` from `dispatch-tasks`; `notify` and `request-approval` from
  `work-on-task` and `iterate-on-pr`).

  A routine skill still needs a guard against an interactive session loading it and sending Telegram
  at an hour the human did not choose. That guard is a precondition in its Step 0, not frontmatter:
  refuse unless `ROUTINE` is set — `launchd-runtime/bin/_run.sh` exports it into the CLI's
  environment — or `--dry-run` or `--force` was passed, printing
  `HALT: <skill> interactive-run-refused (set --dry-run or --force)` and exiting 0.
- **`disallowed-tools` names `Agent` on a headless-invoked skill.** A skill a routine prompt runs
  by `/name`, or another skill forks through the `Skill` tool, has one turn in which to print its
  contract line, and a fork that ends its turn has returned — so a delegated subagent returns
  nothing and the caller reads the missing line as a halt. That is what stopped `work-on-task` on
  2026-09-07; the worker reads the code itself.

## S2 — Model and effort declared in the skill's own frontmatter

*The skill knows what it costs; the runner is only guessing.*

Declare `model:` and `effort:` in the skill's frontmatter. Both are documented Claude Code fields,
and both were verified to override the CLI's `--model` / `--effort` inside headless `claude -p`
runs on both of the user's machines: a skill's declaration wins the moment the skill loads.

`launchd-runtime/bin/_run.sh` still passes `--model` and `--effort`, and it must keep doing so —
those flags cover the wrapper turn before any skill loads, and they pin the model against
interactive drift (unpinned runs cost a measured $13/30d extra, 2026-07-14 assessment). Treat them
as the fallback, not the decision. A read-only digest that runs on `effort: low` should say so
itself rather than inheriting whatever the routine happened to be given.

## S3 — One body order

*Two skills that answer the same question in a different order cost a reader two reads.*

Every skill body runs in this order, with no sections inserted between them:

1. **Role paragraph** — exactly three sentences: who you are, what you produce, what you never do.
2. **Limits / Configuration** — the constraints this skill operates under, **by name only**. The
   numbers live in `repos.conf` (S5).
3. **Baseline citation** — one line, through the skill's own directory:
   `Read ${CLAUDE_SKILL_DIR}/BASELINE.md first and apply its five principles throughout.` Skills
   that write code cite `${CLAUDE_SKILL_DIR}/BASELINE-CODING.md` on the same line. The skill's
   directory carries each cited file as a relative symlink (`BASELINE.md -> ../BASELINE.md`), and
   `test_baseline_conformance.sh` fails a citation that has none. Not an absolute path, which
   exists only on the owner's machines; not `${CLAUDE_SKILL_DIR}/../BASELINE.md`, which the Read
   tool normalises as text and so misses through the symlinked install in `~/.claude/skills`; and
   not `${CLAUDE_PLUGIN_ROOT}/BASELINE.md`, which Claude Code substitutes only for plugin installs.
4. **Arguments** — one bullet per argument, matching `argument-hint` exactly (S1). The section
   must also carry the literal `$ARGUMENTS` placeholder: a forked skill's entire prompt is its
   substituted body, so a skill with no placeholder is handed no arguments at all.
5. **Contract** — four labelled lines: **Refuses when**, **Writes**, **Halts**, **Budget**. This is
   the section a reader checks before trusting the skill with a scheduled run.
6. **Steps** — numbered, each ending in its own check ("→ verify: `gh pr view <n> --json isDraft`
   reports `true`"). A step without a check is a step whose failure is invisible.
7. **Output contract** — the exact parsable stdout lines the skill emits (S6).
8. **Hard rules** — the short list of things this skill never does, each citing the baseline (S9).

## S4 — Progressive disclosure

*`SKILL.md` is loaded whole; everything beside it is loaded only when needed.*

Keep `SKILL.md` to what a run needs every time: the contract, the output lines, and the literals a
model cannot derive — markers, label names, script paths, caps. There is no budget to write up to:
a limit enforced by the byte moved text into `references/` to make room rather than because it
belonged there, and that is the wrong reason for a file boundary. `test_skill_contract.sh` keeps a
tripwire at 20 KB, twice the old cap, so a body that doubles by accident fails loudly.

What moves out, and where:

- **`references/`** — rationale, worked examples, recipes, the diagnostic history behind a rule.
- **`scripts/`** — any procedure that is fixed. A shell script that always runs the same way is
  cheaper, more reliable and more auditable than prose asking the model to reconstruct it.

Address both through `${CLAUDE_SKILL_DIR}`, never a relative path and never a hardcoded
`~/.claude/skills/…`. Skills are installed as directory symlinks, so the whole directory is
reachable, but the working directory is not the skill directory.

`${CLAUDE_SKILL_DIR}` addresses files *inside* the skill's own directory and nothing else. A
repo-level runtime file — `launchd-runtime/repos.conf`, a script under `launchd-runtime/bin/`, a
document under `docs/` — is cited by its absolute path, because it is not part of the skill and
because an `allowed-tools` prefix is a literal string that has to match the command as written. Link to each supporting file from
`SKILL.md` with a sentence saying what it holds and when to open it — an unreferenced file is a
file that never loads.

## S5 — Numbers live once, in `repos.conf`

*The nightly dispatch deadlocked on 2026-09-02 because one cap existed under four names with four
values.*

`launchd-runtime/repos.conf` holds every number that more than one file reads — the caps shared
between a skill and the prompt that fires it (`DISPATCH_TOTAL_MAX`, `PROPOSED_BACKLOG_MAX`,
`REVIEW_ROUND_MAX`), the repo lists, the budgets. Skills and prompts name the identifier and read
the value; they never restate it. A limit exactly one skill reads — a per-session issue count, a
plan-step cap — is not shared state and does not belong in `repos.conf`: state it once in that
skill's own `## Limits` block, where its only reader will find it. A prompt may name a cap. A
prompt may never set one — "raise TOTAL_MAX to 8 for this run only" is a second source of truth
wearing a different hat. `test_cap_names.sh` enforces both halves.

## S6 — Every write is attributable

*When a routine writes something at 04:10 and it is wrong at 09:00, the only question that matters
is which run wrote it.*

**Every issue body, PR body and review summary ends with this HTML comment marker:**

```html
<!-- agentic-skills: skill=<name> repo=<owner/repo> issue|pr=<n> routine=${ROUTINE:-interactive} run=${ROUTINE_RUN_ID:-none} model=<id> -->
```

Use `issue=<n>` on an issue, `pr=<n>` on a pull request. `ROUTINE` and `ROUTINE_RUN_ID` are
exported by `_run.sh`; the defaults are what an interactive invocation gets. The marker is a
comment, so it renders as nothing on GitHub and greps as an exact string — which is also how a
skill checks whether it already wrote something (S7).

**Every unit of work prints one parsable line to stdout**, and nothing else claims to be one:

| Line | Emitted by | Meaning |
|---|---|---|
| `DISPATCH: run=<id> repo=<owner/repo> issue=<N> outcome=<pr-opened\|halted\|refused> gate=<g> pr=<url\|->` | dispatch-tasks | one issue handed to a worker |
| `PROPOSED: <owner/repo>#<N> \| shape:chore \| size:<XS\|S\|M> \| <title>` | propose-tasks | one issue created |
| `WORK: run=<id> repo=<owner/repo> issue=<N> outcome=<pr-opened\|halted\|refused> gate=<passed\|failed\|could-not-run\|no-gate> pr=<url\|-> branch=<name\|->` | work-on-task | one issue worked to its end state |
| `REVIEW: run=<id> repo=<owner/repo> pr=<N> round=<K> head=<sha7> verdict=<v> gate=<g> findings=<blocker>/<major>/<minor>` | review-pr | one review posted |
| `HALT: <skill> <reason>` | any | a clean stop, with the reason |

Stdout is captured in the routine log, which is auditable and costs nothing. This is the channel
for progress; Telegram is not (BASELINE Principle 5).

## S7 — Idempotent, with a `--dry-run` that stops before the first mutation

*A routine that cannot be run twice safely cannot be re-run after a failure, which is when you most
need to run it.*

Running a skill twice against the same input produces the same end state, not two of everything.
State-changing skills get there by checking for their own S6 marker before writing: search the
target's existing issues, PRs or comments for `skill=<name>` plus the identifying key, and if it is
already there, print the `HALT:` line and exit 0.

`--dry-run` is not "do it and tell me" — it performs every read and every decision, prints exactly
the output contract lines it would have printed, and returns before the first mutating call. If a
skill has a mutation it cannot honestly simulate, that is the mutation to move into a script.

A skill that orchestrates other skills rehearses them rather than skipping them: it still invokes
each one, passing `--dry-run` through, because the hand-off is itself a thing that breaks and a run
that stops short of it proves nothing. Read-only comes from the invoked skill's own dry run.
`dispatch-tasks` Step 4 is the worked example.

`ROUTINE_DRY_RUN=1` in the environment is the same thing without the flag, and it is what the smoke
gate sets. `BASELINE.md` defines it; a skill honours it by echoing `dry_run=${ROUTINE_DRY_RUN:-0}`
alongside `ROUTINE` in its first preflight step — Step 0 wherever there is one, Step 1 in a skill
like `work-on-task` that starts there. That echo is the only channel it has: `env` and `printenv`
are denied in a headless run. A skill whose dry run cannot be reached this way cannot be smoke-tested, and a
routine nobody can rehearse is a routine whose next regression lands in production.

## S8 — One Telegram path

*Every duplicate-message bug this stack has had came from a second way to send.*

There is exactly one: `launchd-runtime/bin/telegram-send`, invoked as a single unchained command on
a file written to a literal path. The recipe, its constraints (no `mktemp`, no variable assignment,
no chaining, no retry on perceived failure) and the diagnostic history behind them live in `notify`
and nowhere else. Other skills call `/notify`; they do not restate the recipe and they do not build
their own `curl`.

Quiet by default: a no-op run sends nothing. The two documented exceptions are named in BASELINE
Principle 5 and nowhere else — if you think your skill is a third, it is not.

## S9 — Safety lines stated once, citing the baseline

*A rule copied into eleven files is a rule that will be edited in one.*

State each of these once, as a one-line citation rather than a restatement:

- Never `gh pr ready`, never `gh pr merge`, never force-push — BASELINE, *Merging and Marking PRs
  Ready*. A scheduled run has no user to instruct it; `_run.sh` denies both commands outright.
- Deletion goes through a guarded path only — `permissions/protected-roots.conf` and the deny rules
  in `~/.claude/settings.json`, which survive `--dangerously-skip-permissions`.
- Anything sensitive, irreversible or externally visible goes through `/request-approval`, which
  creates the issue, sends the Telegram and stops. The caller does not proceed.
- A denied command is a stop signal — BASELINE, *Respect the Denial*. Do not retry it in another
  form.

If a skill needs to say more than the citation, the extra belongs in `BASELINE.md`, where every
skill gets it.

## S10 — `META.md` is checked, not trusted

*An assessment file that nothing verifies is a file that ages into fiction.*

Every skill has a `META.md` that follows `_templates/META.md` and satisfies:

- **`kind:` is one of `coding`, `readonly`, `meta`** — `test_baseline_conformance.sh` requires every
  `kind: coding` skill to cite BASELINE.md, which is how a headless run is shown Respect the Denial,
  so the field is load-bearing, not documentation. `coding` writes code, `readonly` only reads and
  reports, `meta` operates on this repo's own skills.
- **`last-assessed:`** records the last time a person or `skill-assess` read the skill. It is not a
  deadline: a skill nothing has touched is a skill nothing has broken.
- **A changelog entry per version.** A `version:` bump with no changelog line means the version
  number is decoration.
- **A "Model / budget" section** naming the `model:` and `effort:` the skill declares (S2) and the
  observed cost of a typical run, so a routing change has a before to compare against.

---

## Changing a skill

- Declare `model:` and `effort:`, chosen for what the skill does rather than inherited (S2).
- Run `make test`; a contract failure fails the suite.
- Run `make smoke-<routine>` for every routine whose skill or prompt you touched, and paste the
  `SMOKE:` lines into the PR. `make test` checks the files; only that checks the run.
