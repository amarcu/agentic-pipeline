# Overnight PR iteration routine

You are running headlessly via the Claude Code CLI, fired by a macOS LaunchAgent. The user is not
present, there is no UI, and nobody can answer a permission prompt — `--dangerously-skip-permissions`
is on, but the deny rules in `~/.claude/settings.json` still apply.

## Why this routine exists

`work-on-task` opens a draft PR. `review-pr` posts findings on it. A human answers a scope question on
it. Then nothing happens, because no routine ever feeds any of that back to a worker.

That is not hypothetical. On `acme/GameTwo#15` the reviewer raised two findings, the worker
escalated both as scope questions, and the human answered them on 2026-08-31 — explicitly granting
permission to use placeholder assets. The answer sat unread for three days until a human ran the skill
by hand. Every review this pipeline produces is worth nothing until something acts on it.

## Step 0 — do not run alongside dispatch or review

`dispatch-tasks-night` (04:10) and `pr-review-night` (05:00) write to the same repos, worktrees and
branches, and `_run.sh` has no lock. Two agents in one checkout corrupt each other's work.

```
pgrep -f "_run.sh dispatch-tasks-night"
pgrep -f "_run.sh pr-review-night"
```

If either matches, print `ITERATE: skipped=<routine>-still-running` and stop. Do not wait and do not
iterate a subset.

This routine starts at 06:05, after review's 3600s timeout expires at 06:00. The check exists because
timeouts do not always kill — dispatch has been measured running 8.9 hours past a 45 minute cap.

## Task

For each repo in `ACTIVE_REPOS` (`launchd-runtime/repos.conf`), find the open draft PRs an agent
shipped that have feedback nobody has acted on, and run the `iterate-on-pr` skill against each:

```
/iterate-on-pr <number> --repo <owner/repo>
```

What it changes, what it refuses to touch and what it posts is the skill's contract. Do not restate
any of it here.

### Selecting candidates

Candidates come only from this list, one call per repo:

```
$AGENTIC_SKILLS_ROOT/launchd-runtime/bin/agent-prs <owner/repo> --draft-only
```

Never iterate on a PR it does not list. On 2026-09-26 this routine was found to have pushed commits
onto two of the human's own GameTwo branches, because it chose every draft with fresh feedback.

Of those, a PR needs iteration when **the newest review comment or review thread is newer than the newest commit
on its head branch**. Something was said after the last push, and nothing has answered it.

Use timestamps, not authorship. The worker, the reviewer and the human all commit and comment as the
same GitHub account, so "was this a human or an agent" is not a question the API can answer here.
Anything said after the last push is unaddressed regardless of who said it.

Skip a PR when:

- Its newest comment predates its newest commit — the feedback was already addressed.
- It carries `review-escalated`. That label means the reviewer gave up and wants a human; iterating
  will not resolve it and burns a slot.
- It is not a draft. A PR the human has marked ready is theirs, not this routine's.

## Constraints (the routine's own, not the skill's)

- **At most 3 PRs per night, across all repos.** Each iteration costs roughly what a dispatch task
  does, and the point is a steady drip a human can keep up with.
- **Oldest unaddressed feedback first.** A question that has waited three nights outranks one asked
  this morning.
- **Never mark a PR ready and never merge.** The skill does not actuate and neither does this routine.
  Promotion stays a human decision.
- **Never force-push.** Iteration adds commits; it does not rewrite what a reviewer already read.
- If the feedback is a question the agent cannot answer without a human decision, it must say so on
  the PR and stop. Guessing at a scope question is worse than leaving it open — that is exactly how
  #15 stalled in the first place.
- Prefix the Telegram digest header with `🔁 Overnight PR iteration`, so the user can tell which run
  sent it.
- Print one `ITERATE:` line per PR handled, so `wake-status-digest` can see the run did something.

## When there is nothing to do

If no repo has a draft PR with unaddressed feedback, print `ITERATE: nothing-to-iterate` and halt
without sending a Telegram message. A quiet night should be quiet.
