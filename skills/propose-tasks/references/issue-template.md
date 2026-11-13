# The proposed-issue body

Read this at Step 6, before composing anything. Write each body to a file and pass it with
`--body-file`; a heredoc inside the `gh issue create` invocation is one quoting mistake away from an
issue whose body is a shell error.

The template is the one `plan-features` cuts its issues from, so a worker reads the same shape
whichever skill wrote the issue. Use it literally.

## Template

```markdown
## Goal
<one sentence: what exists once this lands>

## Why now
<the source signal, named: "TODO at src/foo.ts:142", "one session's slice of #45",
 "follow-up to abc1234, which left Y inconsistent">

## Breakdown
- <2-5 independently landable sub-units>

## Implementation plan (advisory)
1. <step - names the file(s) it touches>
2. <...>

## Acceptance criteria
- [ ] <testable>
- [ ] <the verify gate line from CLAUDE.md>
- [ ] Draft PR opened against `<base>`

## Estimated size
<XS | S | M> - <one line>

BASE BRANCH: <base>

## Reference files
- <path>

<!-- propose-tasks run:<YYYY-MM-DD> routine:${ROUTINE:-interactive} run_id:${ROUTINE_RUN_ID:-none} -->
<!-- agentic-skills: skill=propose-tasks repo=<owner/repo> issue=- routine=${ROUTINE:-interactive} run=${ROUTINE_RUN_ID:-none} model=claude-sonnet-5 -->
```

## Rules the template answers to

- **Every path is checked.** `test -e` each file the plan or the Reference files section names,
  before the issue is created. A path that fails the check leaves the body — a worker that finds
  the plan's first file missing has learned only that the plan was guessed.
- **The plan is advisory**, numbered, at most 6 steps, each naming the file or files it touches. A
  plan that needs more steps is describing two issues.
- **The plan must never contain the phrase "depends on."** The only dependency syntax is a line
  beginning `DEPENDS ON #N`, outside the plan and outside the Acceptance criteria —
  `docs/depends-on-convention.md` at the root of this repository has the grammar
  and the parser that reads it. Prose saying "this depends on the router landing" inside a plan is
  read as a dependency by nothing and as noise by everyone.
- **`M` is the largest size one session may take.** Anything bigger becomes a smaller slice, or two
  issues joined by `DEPENDS ON #N`.
- **`BASE BRANCH:`** is `<base>` from Step 1 — `get_repo_base`, the repo's working branch, resolved
  per run, never the literal `main`. The same value fills the "Draft PR opened against" line.
- **The Acceptance criteria carry the gate.** Quote the verify command from the repo's `CLAUDE.md`
  verbatim, or its `NO GATE — verify by reading` line if that is what the file says. A criterion the
  worker cannot run is a criterion nobody checks.
- **Both trailing comments are the last two lines.** The first is this skill's run stamp; the second
  is the S6 attribution marker every write in this repo carries. `issue=-` is deliberate: `gh issue
  create` assigns the number after the body is written, and the marker's two jobs here —
  attribution, and the Step 5 duplicate check — both work without it.

## Title

Imperative, at most 70 characters, and specific enough that the title alone tells the human what
lands: `Add type tests for ShipStats`, not `Testing improvements` and not `We should add tests`.

## The quality bar

Drop the proposal — do not patch it — if any of these fails:

- the title alone does not say what gets done;
- the "Why now" is a reason you constructed rather than a signal you found;
- an acceptance criterion is not testable;
- the Breakdown is one bullet, which means the issue was never broken down;
- the plan names a path that does not exist.

Zero issues is a valid run. One thin proposal costs the human the same review minute as a good one
and returns less.
