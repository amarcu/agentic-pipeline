---
domain: universal
kind: coding
version: 1.0.0
status: experimental
last-assessed: 2026-11-14
---

## Purpose
The headless half of the design session. A repo whose direction is human-led gets its issues from
`plan-features`, which is interactive, so when a session is missed the nightly loop has nothing to
dispatch. StarBonk sat idle from 20 October to 4 November 2026 with zero approved issues, and
again from 11 November with twelve In-play lines nobody had cut. This skill cuts the next issues
from those lines when the approved queue runs low.

It decides nothing about direction. The human writes the In-play lines; this turns the next ones
into issues, in the human's order, and stops when they run out.

```
plan-features (session: direction + first issues) ─┐
                                                   ├─→ dispatch-tasks → work-on-task → review
refill-queue (nightly: next issues from In play)  ─┘
```

`kind: coding` — it writes: labels and issues in someone else's repo.

## Model / budget
- Model: `claude-opus-4-8` — an issue's plan sets the cost of the worker run and the review behind
  it, so the body is written by the model the routines already run on, not a cheaper one.
- Effort: `medium` — the lines are chosen by a script and the order is fixed, so what is left is
  reading the code for one or two plans.
- Typical run: not yet measured. It rides `morning-proposals`, whose cap is the runner's default.

## Limits (named here, valued in SKILL.md and repos.conf)
- `MAX_PER_RUN`, `QUEUE_MIN`, `MAX_HELD` — this skill's own, stated once in SKILL.md's `## Limits`.
- `MAX_PLAN_STEPS` — `plan-features`' number, the same six.
- `PROPOSED_BACKLOG_MAX` — the cross-repo gate in `launchd-runtime/repos.conf`, read by the
  `morning-proposals` routine. A held issue counts toward it; an approved one does not.

## Halt Conditions
Every one leaves a single `HALT:` line on stdout and nothing else.

1. **Not enabled** — the base branch's `agent/FOCUS.md` has no line reading exactly
   `refill-queue: approve` or `refill-queue: propose`.
2. **GitHub could not be read** — without the issue list every line looks uncut.
3. **The queue is not low** — `QUEUE_MIN` or more approved issues wait, unclaimed and unblocked.
4. **The human has not answered** — `MAX_HELD` or more unapproved proposals are open.
5. **In play is exhausted** — every line has an issue. A planning session is due; the evening
   digest's starved line is what tells the human.

## Dependencies
- `gh` CLI, authenticated for the target repo
- Target repo mapped in `get_repo_path`, with `CLAUDE.md` and `agent/FOCUS.md` on its base branch
- `launchd-runtime/bin/focus-queue` — the opt-in, the queue counts and the uncut lines
- `plan-features/references/issue-template.md` — the issue body
- `ROUTINE` / `ROUTINE_RUN_ID`, exported by `launchd-runtime/bin/_run.sh`

## Design notes
**The repo opts in, in a file only its owner merges.** Whether a headless run may cut issues, and
whether it may approve them, is one line in the target repo's `agent/FOCUS.md`. A model cannot
grant itself that: this skill never edits the file, and a change to it is a pull request the owner
merges. `approve` and `propose` are separate words so that a repo can take the refill without
giving up the approval.

**Approval moved, it was not removed.** The rule was that a human applies `approved`. Under
`refill-queue: approve` the human's approval is the In-play line itself: an issue is approved only
when it quotes one verbatim, is one session's size, touches nothing on the repo's MUST-ask or
NEVER lists and asks no open question. Anything else is created as `proposed` with the failed
condition named, and waits for a label.

**The script decides what is already cut.** A model judging whether an existing issue covers a
line files it differently on two runs, and the second run cuts a duplicate. `focus-queue` counts a
line as cut when it names an issue or when any issue, open or closed, quotes it whole under
`## Why now`. That is why Step 4 requires the quote character for character.

**Lines are taken in order.** The order of the In-play lists is the human's priority. A run that
skipped to an easier line would reorder the project one night at a time.

**It reads the focus from the base branch.** The checkout on the pipeline host can lag; an issue
cut from a stale focus is work the human already moved to *Not now*.

## Known Issues
- It rides `morning-proposals`, which starts five minutes before `dispatch-tasks-night` and has a
  fifteen-minute watchdog. An issue cut tonight is normally dispatched tomorrow night, and a run
  that reads a lot of code for two plans can be killed before it reports. Both numbers are in the
  plists, which are the owner's to change.
- `pipeline-metrics` counts every `approved` label as an approval, so an issue this skill approved
  is in the funnel's approval figure beside the ones a human labelled.
- Not yet run headless. `make smoke` has not rehearsed it and no typical cost is recorded.
- The plan is written from the checkout, which can lag the base branch. The plan is advisory and
  `work-on-task` re-checks every path, so a stale path costs a line in the PR body, not a run.
- A line edited in FOCUS.md after its issue was cut no longer matches that issue's quote, and is
  offered again. Appending the issue number to the line (`Issue #82.`) marks it cut for good.
- Condition 3 of the approval rule is the model's reading of CLAUDE.md. It is told to hold when
  unsure, and no script checks it.

## Changelog
- 2026-11-14 (v1.0.0): Initial version, with `launchd-runtime/bin/focus-queue`.
