# Daily review nudge (launchd-driven, 19:00)

You are running headlessly via the Claude Code CLI, fired by a macOS LaunchAgent. The user is not present. There is no UI and no human to approve permission prompts — `--dangerously-skip-permissions` is on, but the deny rules in `~/.claude/settings.json` still apply.

## Why this routine exists

The pipeline's bottleneck is review, not proposal and not execution. Measured across 57 agent PRs, merge outcome was explained entirely by whether a review session happened that week — no property of the issue text had any residual effect once date was controlled for. Draft PRs have sat for 85 days while the generator kept producing.

So this routine is not a digest. It is a prompt to sit down for 30–60 minutes and drain the queue. Write it so that a person reading it on their phone knows exactly what to open and how long it will take.

## Task

Assemble the review queue for **active repos only** and send exactly one Telegram.

1. Source the roster:

       . $AGENTIC_SKILLS_ROOT/launchd-runtime/repos.conf

   Iterate `ACTIVE_REPOS`. Ignore every other repo — dormant repos are deliberately excluded and must not appear in the message.

2. For each active repo, collect via `gh`:
   - **Approve**: issues labelled `proposed` and not `approved`, open. Note the count and the age of the oldest.
   - **Mark ready**: open PRs with `isDraft: true`. Count, plus the age of the oldest.
   - **Merge**: open PRs with `isDraft: false`. Count, plus the age of the oldest.

3. Compute work-in-flight against the two PR caps in repos.conf, the overall one and the per-repo one. An agent PR is an open PR whose head branch starts with `task/issue-` or `worktree-issue-`, or whose body contains `Closes #<n>`. Approved-but-unstarted issues do not count here — they are the queue the caps admit, and dispatch-tasks reads the same numbers the same way.

   - **Overall**: open agent PRs across the active repos against `DISPATCH_TOTAL_MAX`, reported as `<n>/<N>`.
   - **Per repo**: open agent PRs in that repo against `DISPATCH_PER_REPO_MAX`, reported as `<n>/<P>` beside the repo's name. Name only the repos at or above their per-repo cap; the rest are implied by the overall figure.

   A repo at or above `DISPATCH_PER_REPO_MAX` is skipped by tonight's dispatch and blocks only itself, so name it with the one PR to land that reopens it. Dispatch stops for the whole roster only when every repo holding queued work is at its per-repo cap, or the overall count has reached `DISPATCH_TOTAL_MAX` — when that happens it is the single most important thing in the message, because nothing new goes out until a PR clears. Being at or above either cap is reachable rather than hypothetical: a hand-written PR whose body says `Closes #<n>` counts like any other, so a count can sit past its cap without dispatch ever having put it there.

4. Estimate the sitting: roughly 2 minutes per item to approve, 5 per draft to mark ready, 5 per PR to merge. Round to the nearest 5 minutes. If the estimate exceeds 60 minutes, say which section to do first and explicitly tell the user to stop at the hour.

5. Send one Telegram via the `notify` skill.

## Message shape

Keep it under about 12 lines. Lead with the time estimate and the single first action, then the sections. Name the oldest item in each section with its number, title and age; give a bare count for the rest. Never list more than three items in a section.

Include these direct links, which the local Makefile targets mirror:
- approvals: `https://github.com/issues?q=is%3Aopen+label%3Aproposed+-label%3Aapproved+user%3A%40me`
- your PRs: `https://github.com/pulls?q=is%3Aopen+is%3Apr+author%3A%40me`

## Quiet-day behaviour

If all three queues are empty across every active repo, send exactly one short line saying the queue is clear.

Then check the previous three daily-review-nudge logs in `$HOME/.agentic-skills/routines/logs/`. If the queue was also empty on all three, add one sentence: the queue being empty three days running means the generator has stalled, not that the work is done. Name the likely cause if the logs make it obvious (saturation halt, missing CLAUDE.md, a repo whose path no longer resolves).

## Constraints (do not deviate)

- **Read-only.** No issue mutations, no PR mutations, no labels, no comments, no pushes. This routine only reports.
- Exactly one Telegram per run.
- Do not invoke `propose-tasks`, `dispatch-tasks`, `work-on-task` or `iterate-on-pr`. Assembling the queue is the whole job.
- If a repo errors, count it as `(error)` in the message and continue with the rest.
- Do not restate what the 18:05 daily summary already said. That routine reports what happened; this one asks for a decision.
