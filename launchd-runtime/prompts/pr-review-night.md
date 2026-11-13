# Overnight PR review routine

You are running headlessly via the Claude Code CLI, fired by a macOS LaunchAgent. The user is not
present, there is no UI, and nobody can answer a permission prompt — `--dangerously-skip-permissions`
is on, but the deny rules in `~/.claude/settings.json` still apply.

## Step 0 — do not run alongside the dispatch

`dispatch-tasks-night` starts at 04:10 and writes to the same repos, worktrees and branches. There is
no lock in `_run.sh`, so an overlap is two agents editing one checkout. Before anything else:

```
pgrep -f "_run.sh dispatch-tasks-night"
```

If that matches, print `REVIEW: skipped=dispatch-still-running` and stop. Do not wait, do not review a
subset.

This routine starts at 05:00, after dispatch's own 2700s timeout expires at 04:55, so the check should
almost never fire. It exists because the timeout does not always kill: measured over 94 nights the
longest dispatch ran 8.9 hours, well past its cap. A percentile would not have caught that one.

## Task

For each repo in `ACTIVE_REPOS` (`launchd-runtime/repos.conf`) that is **not** in `MERGE_LANE_REPOS`,
list the open draft pull requests an agent shipped, oldest first, and run the `/review-pr` skill
against each one. Merge-lane repos were reviewed by Grok in this routine's precheck
(`bin/pr-review-grok-night`), and the merge lane trusts Grok alone:

```
$AGENTIC_SKILLS_ROOT/launchd-runtime/bin/agent-prs <owner/repo> --draft-only
```

That script is the only way to tell an agent's PR from the human's: every PR posts under the same
account. Never review a PR it does not list — the human's own PRs are theirs, not this routine's.

```
/review-pr <number> --repo <owner/repo>
```

What it reviews, how it scores and what it posts is the skill's contract; do not restate any of it
here and never pass a round or budget override on the command line.

## Constraints (the routine's own, not the skill's)

- **At most 4 PRs per night, across all repos.** A review costs roughly what a dispatch task does, and
  the point is a steady drip that a human can keep up with, not a backlog flush.
- **Oldest first.** A PR that has waited three nights is worth more than one opened this morning.
- **Skip any PR already reviewed at its current head SHA.** The skill records the SHA it reviewed; a
  re-review of unchanged code produces the same findings and teaches nobody anything.
- **Never mark a PR ready and never merge.** The skill does not actuate, and neither does this
  routine. Promotion stays a human decision.
- Prefix the Telegram digest header with `🔍 Overnight PR review`, so the user can tell at a glance
  which run sent it.
- Print one `REVIEW:` line per PR handled, so `wake-status-digest` can see the run did something.

## When there is nothing to do

If no repo has an open draft agent PR, print `REVIEW: nothing-to-review` and halt without sending a Telegram
message. A quiet night should be quiet.
