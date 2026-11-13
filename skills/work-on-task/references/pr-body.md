# The PR body

Read this at Step 7, before `gh pr create`. Write the body to `/tmp/work-on-task-pr.md` and pass it
with `--body-file`; a heredoc inside the `gh` invocation is one quoting mistake away from a PR whose
body is a shell error.

## Template

```markdown
## Summary
<1-2 sentences: what this changes and why the issue asked for it>

## Changes
<bullets, grouped by area, one per file or coherent group>

## Verification
<the gate command from CLAUDE.md, and its result — see "Gate outcomes" below>
<each acceptance criterion from the issue, with how it was checked>

## Assumptions and notes
<anything guessed at, anything noted but deliberately not changed, open questions>

## Test plan
<the tests added, first: their names, what each asserts, and the command that runs them>
<the red run: the command and the first error line it produced before the fix>
<then how a human verifies the rest by hand>

Closes #<N>

<!-- agentic-skills: skill=work-on-task repo=<owner/repo> issue=<N> routine=${ROUTINE:-interactive} run=${ROUTINE_RUN_ID:-none} model=<model id> gate=<outcome> -->
```

The marker is the last line. It renders as nothing on GitHub, greps as an exact string, and is how
Step 1 of a later run recognises that this issue already has a PR. `ROUTINE` and `ROUTINE_RUN_ID`
are exported by `launchd-runtime/bin/_run.sh`; an interactive invocation gets the defaults shown.

## Tests come first

The tests that encode the acceptance criteria are written before the implementation, run red, and
then run green (Steps 5 and 6). The Test plan section says so in that order — the tests added, then
the failing command and its first error line, then anything left to check by hand. A reviewer who
cannot see the red run cannot tell a test that proves the fix from a test written to match it.

Two cases state themselves rather than going quiet:

- **No framework.** The repo's `CLAUDE.md` declares `NO GATE — verify by reading` and the repo has
  no test framework at all. Say that no automated test was possible and why, and say what you read
  instead.
- **Nothing a test can express.** Pure documentation, configuration or a data file. Name the change
  as untestable and say why; never skip red and green silently.

## Gate outcomes

Only `passed` and `no-gate` reach a PR at all.

- `passed` — name the command and say it passed. Never claim a compile, a test run or a build you
  did not observe.
- `no-gate` — the repo's `CLAUDE.md` says `NO GATE — verify by reading`, or names a gate whose tool
  is deliberately absent. Say so verbatim in Verification, name what you read instead, and state
  that a human must run the gate before the PR is marked ready.

## Conditional notes

**Production-branch repos.** If `CLAUDE.md` names a `production` branch, or any deploy-only branch
that a human promotes, add to Assumptions and notes:

> **After merge:** a human promotes `main` → `production` for deploy. Do not merge into
> `production` directly.

**Cross-repo work.** If `CLAUDE.md` describes cross-repo coordination and the diff touches anything
the sibling repo consumes — DTOs, API contracts, shared schemas, generated clients — add a
"Cross-repo dependencies" section naming the sibling repos, saying whether their change has to land
and deploy first, and asking the question outright if you cannot tell. A dependency resolved as
`CLOSED` means the upstream issue is closed, not that the upstream change is deployed.

**Divergence from the issue's plan.** An issue's `## Implementation plan` is advisory. Where a path
it named did not exist, or the code contradicted it, say so in Assumptions and notes and say what
you did instead.

**Pre-existing staged work.** If Step 7 found something already staged and you committed with
`git commit <path> …`, note it: "Found staged work on this branch unrelated to this task; left it
untouched."

**Gate output.** When the gate prints a machine-readable verdict, paste it verbatim rather than
summarising it — a whole line, elided nowhere:

    {"verdict":"pass-no-tests","tests":0,"note":"project compiles; no EditMode tests exist"}

That states exactly what was and was not checked, where "gate passed" does not. `pass-no-tests`
means the project compiles and nothing else was verified — it never supports a claim that the
change works.
