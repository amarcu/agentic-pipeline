---
domain: universal
kind: coding
version: 0.2.0
status: experimental
last-assessed: 2026-09-27
---

## Purpose
The daily review sitting, as a skill. By 2026-09-06 the pipeline's automation worked and its human
loop did not: proposals sat unapproved for days, host blockers surfaced only in digests, and one of
seven active repos had ever had a direction session. The 19:00 `daily-review-nudge` already tells
the human what is waiting; nothing helped them drain it. `unstick` is that counterpart.
`scripts/agenda` builds the list deterministically and orders it by what each item unblocks, and the
skill walks it one item at a time, acting only on the human's explicit yes and routing real
decisions to a drill or to `/plan-features`.

## Model / budget
- Model: `claude-opus-5` — interactive and judgement-heavy (is this PR mergeable, is this proposal
  worth a worker), but it plans nothing itself; Fable is reserved for the `plan-features` session it
  routes to.
- Effort: `high` — every action it takes is externally visible and most are irreversible, and the
  drill needs the strongest counter-case rather than the first one.
- Typical run: the sitting is not yet measured; record it here after the first real one. The agenda
  spends no model budget: 13 s of `gh` reads and one ssh, measured on 2026-09-11 against 7 active repos.

`kind: coding` — by elimination, as for `plan-features`: it writes no code, but it is not `readonly`
(it labels, closes, merges and comments) and it is not `meta`. That kind selects the 10 KB budget;
the body is kept under the 6 KB one anyway.

## Dependencies
- `gh`, authenticated — every read, and every confirmed action
- `launchd-runtime/repos.conf` — `ACTIVE_REPOS`, `DISPATCH_PER_REPO_MAX`, `REPOS_BY_PRIORITY`, `get_driver`
- `launchd-runtime/bin/check-requirements` — run on the pipeline host over `ssh pipeline-host`, or locally
- `launchd-runtime/bin/pr-review-round` — optional. Not on `main` until PR #36 merges; until then a
  draft counts as green only on a cursor-review pass, and the agenda prints a NOTE saying so
- `/plan-features` — the DIRECTION route; human-typed only (`disable-model-invocation`)
- `mattpocock-skills:grilling` — optional drill for design-heavy items. Installed on the workstation
  by decision (v1.2.3, user scope) and deliberately absent from the pipeline host, where 11 of its
  25 skills are model-invocable (`tdd`, `code-review`) and would compete with the routine workers

## Known Issues
- Every agent pushes as the human's own account, so an agent's draft is told apart only by its
  branch (`task/issue-<N>-`, `worktree-issue-`) or work-on-task's attribution marker. REVIEW lists
  those; every other open draft is counted on one `more` line, still named but not walked.
- A draft in MERGE carries `steps: [ready, merge]`. GitHub refuses to merge a draft, so marking it
  ready is a step the human confirms first, never a retry after a refused merge (Grok, PR #41 f1).
- A REVIEW draft carries `steps: []`. Ready waits for a passed adversarial review, which is what
  moves a draft to MERGE, so the sitting offers a comment or the cursor-review command (Grok, PR #41 f3).
- `plan-features` opens its focus PR with `--draft`, so DIRECTION never merges it directly: the
  focus PR takes its own MERGE or REVIEW route like any other PR (Grok, PR #41 f2).
- DIRECTION lists one repo per agenda (a driver repo first, then the most approved or proposed
  issues, then `REPOS_BY_PRIORITY`), because each is a half-hour `plan-features` session; the rest
  are counted, one session per day.
- DIRECTION reads `agent/FOCUS.md` from the default branch. A session whose focus PR is still open
  therefore reads as due, which is why the item's detail names the open focus PR.
- The minutes for HOST and BLOCKED are this skill's own estimates, and DIRECTION's 25 is one
  planning session. APPROVE, REVIEW and MERGE are the nudge's, held equal by
  `test_unstick_agenda_minutes_are_the_review_nudges`.

## Changelog
- 2026-09-27 (0.2.0): The sitting ends by handing over to the day's drill — a `DRILL:` line naming the DIRECTION repo and its `/plan-features` command — so cleanup leads into creative direction instead of stopping at chores. The agenda's DIRECTION window is now the rotation: one day per drilled repo (the active repos minus those another repo drives, whose driver's drill covers them). With one drill a day, every drilled repo comes round within that many days whatever the pick order — five with today's roster. No drill is offered while a focus PR is open.
- 2026-09-14 (0.1.1): Retiring an issue in a sitting is now a close plus the `retired` label, and the
  sitting prints the *Not now* line the next `plan-features` session should carry. `propose-tasks`
  reads that label and nothing else, so before this a closure here left the work proposable and the
  human answered the same question the following week (issue #62). The `UNSTUCK:` action is
  `retired`, not `closed`.
- 2026-09-11: Initial version (0.1.0)
