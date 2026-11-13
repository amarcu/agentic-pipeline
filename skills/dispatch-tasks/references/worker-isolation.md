# Worker isolation — what `context: fork` was measured to do

Read this before changing how Step 4 invokes a worker. Everything below was measured on
2026-09-03 with a throwaway skill pair (`outer` invoking `inner` through the Skill tool) run under
`claude -p --output-format json --max-turns 8 --no-session-persistence --setting-sources user,project`,
which is the shape `launchd-runtime/bin/_run.sh` uses. Design against these observations, not
against the documentation.

## The problem this solves

A skill's `model:` and `effort:` override the CLI's `--model` / `--effort`, and the override holds
for the rest of the turn. `dispatch-tasks` runs on Sonnet and `work-on-task` on Opus at `high`. Run
in one context, either the dispatcher's Sonnet swallows the worker's Opus or the worker's Opus is
still in force when the dispatcher resumes its bookkeeping — and the dispatcher does its bookkeeping
between every task.

## What was measured

Five runs. `inner` is the worker, `outer` the dispatcher.

| Run | `inner` frontmatter | CLI `--model` | Models in `modelUsage` |
|---|---|---|---|
| A | `model: sonnet-5`, `context: fork` | opus-4-8 | sonnet-5 only |
| B | `model: sonnet-5`, no fork | opus-4-8 | sonnet-5 only |
| C | `model: opus-4-8`, `context: fork` | sonnet-5 | sonnet-5 **and** opus-4-8 |
| D | `model: opus-4-8`, no fork | sonnet-5 | sonnet-5 only |
| E | C plus `disable-model-invocation: true` | sonnet-5 | sonnet-5 only — `inner` never ran |

1. **The fork runs, headless, and returns its output to the caller.** In run A the outer's final
   message was `INNER-RAN hello\n\nOUTER-DONE` — the fork's text came back into the caller's turn,
   which is what lets Step 4 parse a worker's `WORK:` line. `background: false` makes it wait.

2. **A forked skill's own `model:` is applied; an in-process one's is ignored.** Run C shows a
   distinct `claude-opus-4-8[1m]` entry with `cacheReadInputTokens: 0` and its own cache creation —
   a fresh, separate context on the declared model. Run D is the same skill without `context: fork`
   and produced *no* opus usage at all: the nested declaration was silently dropped and the worker
   ran on the caller's Sonnet. Without the fork, `work-on-task` would quietly run on Sonnet at
   whatever effort the dispatcher had.

3. **The caller resumes on its own model.** In run C the outer ran a Bash call and a final message
   after the fork returned; all of it landed in the sonnet-5 entry, and the opus entry never read
   from cache, so it was one isolated context rather than a model that stayed switched on.

4. **`disable-model-invocation: true` blocks the Skill tool outright.** Run E is run C with that one
   line added to `inner`. `inner` never ran; the outer reported that it is "marked
   `disable-model-invocation`, so only you can run it directly via `/inner`", skipped the step and
   finished the rest. This is why `work-on-task` does **not** carry the flag: with it, this
   dispatcher cannot invoke a worker at all and every run would dispatch nothing.

   The flag stays on `dispatch-tasks`, which is the skill a routine prompt invokes by name. The
   standard also puts it on skills that send Telegram; `work-on-task` asks `notify` to send rather
   than sending, and `notify` and `request-approval` — the other skills invoked by another skill —
   carry no flag either, for the same reason.

5. **A fork is not a subagent for accounting.** `subagent_stats.spawned` was `0` in all five runs,
   forks included. Per-worker cost attribution therefore cannot come from `subagent_stats`; it comes
   from the distinct `modelUsage` entry a fork creates and from the run's own `DISPATCH:` lines.

## Why a dry run still forks

`--dry-run`, and `ROUTINE_DRY_RUN=1` with it, returns before every mutation except this one: Step 4
still forks a worker, with `--dry-run` appended to its arguments. Read-only is the worker's own
flag, which halts it before its first mutation — not the dispatcher declining to fork.

The hand-off is the part that keeps breaking, and a rehearsal that returns before Step 4 exercises
none of it. Both failures are from 2026-09-07:

- **The arguments never reached the fork.** `dispatch-tasks` invoked
  `Skill(name="work-on-task", args="18 --repo acme/GameTwo")` twice. A forked skill's whole
  prompt is its own body after substitution, and `work-on-task`'s Arguments section carried no
  `$ARGUMENTS` placeholder, so the arguments went nowhere — both workers replied "I don't have an
  issue number to work on".
- **The fork ended its turn without returning a line.** A worker spawned a background research
  subagent and finished with "Waiting on the primitives-search agent … before finalizing the plan".
  A forked skill that ends its turn has returned; there was no `WORK:` line to copy.

Both times the dispatcher scored the missing line as `halted`, two in a row tripped the
systemic-failure breaker, and the night dispatched nothing. Step 4's three mapping rows are the
contract that came out of it, and this is why the third one exists.

It is also why a rehearsed worker returns `PLANNED:` and not `WORK:` — it stops at its own plan,
before the step that would emit the other line — and why a `dry-run` outcome does not count toward
the breaker: a fork that came back with its plan is a hand-off that worked.

## What the fork does not isolate

The budget. `_run.sh` starts one `claude -p` with one `--max-budget-usd`, and a fork is in-process,
so the dispatcher and every worker spend against the same cap. Isolation here is of model, effort
and context — not of spend. `slots` is what actually bounds a run's cost, which is another reason
the gate is computed before anything is dispatched.
