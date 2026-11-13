# Week 37 pipeline audit

Pipeline host, Monday 7 – Sunday 13 September 2026. Every figure and claim below is checkable against
`2026-09-13-week-37-pipeline-audit.data.json`; the key in brackets after a figure names where in that
file it comes from. The data file is kept beside this one in the working repository and left out of
published snapshots, because it quotes issue titles and message text from private repositories.

The routines were **reliable and almost idle**. All 55 scheduled runs fired and exited 0, but in
seven nights dispatch forked five workers and only one produced a pull request, and no merged pull
request that week came from a routine. The pipeline was not broken; it was waiting — on a host that
cannot build GameTwo, on proposals nobody approved, and on repos with no `CLAUDE.md`. It was also
partly blind: spend was recorded for two of nine routines, which is fixed as of today.

## The week in figures

| Figure | Value | Source in the data file |
|---|---|---|
| Routine runs | 55, none with a non-zero exit | `derived.routine_runs`, `derived.runs_with_nonzero_exit` |
| Pull requests from dispatch | 1, from five workers forked on three nights | `derived.pull_requests_from_dispatch`, `derived.worker_forks_by_night` |
| Issues proposed by routines | 2 (GameTwo #26 and #30) | `sends[].refs` on the 8th and 11th; `github` issue lists |
| Telegram messages | 29 | `derived.telegram_messages` |
| Routine run time | 2.72 hours | `derived.run_time_hours` |
| Routines whose spend was recorded | 2 of 9 | `derived.routines_with_recorded_spend` |
| Measured spend | $3.63 of an unknown total | `derived.measured_spend_usd` |

Sunday's `daily-summary-routine` (18:05) and `daily-review-nudge` (19:00) had not run when the data
was extracted, so they are not among the 55.

## Night by night

What each run concluded, read from its log — not whether the process exited cleanly, since every one
did. **ok** did its job · **halt** work existed but could not proceed · **fail** failed ·
**quiet** correctly had nothing to do.

| Routine | Mon 7 | Tue 8 | Wed 9 | Thu 10 | Fri 11 | Sat 12 | Sun 13 |
|---|---|---|---|---|---|---|---|
| `wake-status-digest` 04:00 | ok · digest sent | ok · digest sent | ok · digest sent | ok · digest sent | ok · digest sent | ok · digest sent | ok · digest sent |
| `morning-triage` 04:02 | quiet · 0 blocking | quiet · 0 blocking, 5 proposed | quiet · 0 blocking, 5 proposed | quiet · 0 blocking, 4 proposed | quiet · 0 blocking, 4 proposed | quiet · 0 blocking, 5 proposed | quiet · 0 blocking, 5 proposed |
| `morning-proposals` 04:05 | quiet · no issue created | ok · proposed GameTwo #26 | halt · none, StarBonk saturated | halt · none, StarBonk saturated | ok · proposed GameTwo #30 | halt · none, digest sent | halt · none, StarBonk saturated |
| `dispatch-tasks-night` 04:10 | fail · worker got no arguments | fail · 2 workers halted, host cannot build GameTwo | quiet · empty queue | ok · 1 worker, StarBonk #45 → PR #49 | halt · all repos blocked | halt · all repos blocked | halt · all repos blocked |
| `pr-review-night` 05:00 | quiet · nothing to review | fail · bundle failed, `gh` too old | quiet · nothing to review | ok · reviewed #49 and #9, escalated #93 | quiet · already reviewed | quiet · already reviewed | quiet · nothing new |
| `pr-iterate-night` 06:05 | quiet · no feedback | quiet · no feedback | quiet · no feedback | quiet · no feedback | quiet · no feedback on #49 | quiet · no feedback | quiet · no feedback on #49 |
| `skill-assess-weekly` Mon 04:20 | ok · 1 finding, no issue filed, $1.26 | — | — | — | — | — | — |
| `daily-summary-routine` 18:05 | ok · sent, spend shown $1.60 | ok · sent, spend shown $0.31 | ok · sent, spend shown $0.40 | ok · sent, spend shown $0.31 | ok · sent, 6 shipped | ok · sent, spend shown $0.38 | due that evening |
| `daily-review-nudge` 19:00 | ok · sent | ok · sent | ok · sent | ok · sent | ok · sent | ok · sent, approve 5, ready 3 | due that evening |

Sources: each run's `contract` lines in `runs[]`. Where a run printed none, the matching entry in
`log_excerpts` — `morning-proposals` every day, `dispatch-tasks-night` on the 7th, 8th and 10th,
`pr-review-night` on the 12th and 13th, and `daily-review-nudge` Monday to Saturday — or in
`sidecar_results` for the two routines that captured their envelope all week, `wake-status-digest` and
`skill-assess-weekly`, whose final messages never reached their logs. Spend from `runs_jsonl`; each send
is also in `sends`.

## Blockers, most work freed first

1. **The pipeline host cannot build GameTwo.** Eight approved issues wait: #18–#24 and #26
   (`github.gametwo_open_approved`). On Tuesday dispatch spent twelve minutes (736 s) on #18 and #19:
   #18 stopped before any change because the game-engine checkout the Mac client links against is missing and
   full Xcode is not installed; #19's 8-line change could not pass its `xcodebuild` gate
   (`log_excerpts` for 2026-09-08). From Wednesday the requirements check marked the repo `unmet` every
   night — the `DISPATCH GATE` lines on the 9th, 11th, 12th and 13th, and the excerpt for the 10th. With
   GameTwo out, dispatch had nothing to run on the 9th and from the 11th to the 13th; on the 10th it
   worked StarBonk's one approved issue. **Unblock:** install full Xcode on the pipeline host and clone
   game-engine beside GameTwo.

2. **StarBonk's proposals have waited since Monday.** Five Phase 0 issues were opened on the 7th; only
   #45 was approved, and it became the week's one agent pull request. #44, #46, #47 and #48 are still
   unapproved (`github.starbonk_44_to_48`), so `morning-proposals` counted StarBonk as saturated and sent
   a reminder on the 9th, 10th and 13th, while the evening nudge listed the same issues.
   **Unblock:** approve or close #44, #46, #47 and #48, and GameTwo #30.

3. **The week's one agent pull request waits for you.** StarBonk #49, from #45, passed the nightly review on Thursday with its Unity gate really running,
   three EditMode tests (`reviews`). It has been a draft since, waiting for a human decision.
   **Unblock:** mark StarBonk #49 ready and merge it, or send it back.

4. **Three repos give the proposer nothing to read.** StarBonk-backend, agent-lab-platform and
   strategy-game have no root `CLAUDE.md`, so `morning-proposals` skipped them on every morning in the
   excerpts. Bootstrap pull requests for the first two, #9 and #93, have been open since Wednesday.
   agent-lab is a generated mirror with nothing an agent may change; whether it belongs on the roster is
   still open. **Unblock:** merge or close #9 and #93, and decide agent-lab's place in `ACTIVE_REPOS`.

## Findings about the pipeline itself

- **Fixed today — spend was invisible for seven of nine routines.** Only `wake-status-digest` and
  `skill-assess-weekly` captured their run envelope, so the daily summary showed about $0.31 a day — the
  wake digest alone — while dispatch ran for 44 minutes and proposals for 40 across the week
  (`derived.run_time_minutes_by_routine`). Measured spend is $3.63; the real figure is unknown. PR #51
  turned capture on for every routine (`deploy_2026_09_13.pulled_2026_09_13`).
- **Open, issue #52 (`github.issues_filed_2026_09_13`) — routines summarise instead of printing their
  contract lines.**
  `morning-proposals` never printed a `PROPOSED:` or `HALT:` line of its own in any of the seven runs:
  it put each repo's outcome in a table cell or a bullet, and on Tuesday the cell held the `PROPOSED:`
  line itself. PR review wrote prose on the 12th and 13th. Dispatch lost `DISPATCH GATE` and `DISPATCH PLAN`
  on both long runs, Tuesday (736 s) and Thursday (1223 s). Today's smoke rehearsal of `morning-triage`
  scanned all seven repos cleanly and then left out `TRIAGE:` altogether (`deploy_2026_09_13`).
- **Open — the review lane cannot run StarBonk-backend's gate.** #9 came back "changes needed" with no
  findings because `npm install` is denied in the headless review environment (`reviews`). Every backend
  pull request will be capped the same way until that gate can run there.
- **Fixed Wednesday — Tuesday's review night failed on an old `gh`.** `gh` 2.63.2 rejected
  `closingIssuesReferences`, so no bundle could be built for StarBonk #43. The host now runs `gh`
  2.100.0, installed on the 9th at 09:21 (`host`), and Thursday's reviews ran.
- **Fixed Monday — dispatch's worker arrived with no arguments.** "The worker starts with no issue number
  and writes nothing" (`log_excerpts` for 2026-09-07). PR #31, which gave every argument-taking skill the
  `$ARGUMENTS` placeholder, merged at 10:38 UTC that day (`github.agentic_skills_pr31`), after the 04:10
  run.
- **No action — launchd error files.** Four of the nine `launchd-*.stderr` files are non-empty. Each holds a
  bash "Terminated" notice for the runner's watchdog subshell, a side effect of a normal finish. Three
  were last written between 30 August and 4 September; `launchd-pr-review-night.stderr` on Wednesday the
  9th at 05:00 (`stderr_files`).

## Deployed to the pipeline host today

The four pull requests merged and pulled on 13 September (`deploy_2026_09_13.pulled_2026_09_13`):

- **#51** — every routine captures its run envelope, so tomorrow's summary reports the whole pipeline's
  spend; a successful run's final text stays in its log.
- **#49** — each denial and each failed tool call is recorded, and a block that recurs across runs appears
  as one friction line in the evening summary.
- **#48** — smoke rehearsals run each routine with its own launchd environment; triage's contract line
  counts repos whose scan failed.
- **#50** — a stray non-UTF-8 byte in a gate's output can no longer cap a review.

All nine LaunchAgents were reloaded with capture on, and the host's test suites passed, 327 and 100
tests. The `daily-summary-routine` rehearsal passed with the new friction step. The `morning-triage`
rehearsal confirmed the environment fix and failed only on the missing contract line above
(`deploy_2026_09_13`, recorded from this session's commands rather than the routine logs).

## For the next sitting, in order of work freed

1. Install full Xcode on the pipeline host and clone game-engine beside GameTwo — eight approved issues.
2. Approve or close StarBonk #44, #46, #47 and #48, and GameTwo #30.
3. Decide on StarBonk #49: mark it ready and merge it, or send it back.
4. Merge or close StarBonk-backend #9 and agent-lab-platform #93.
5. Decide whether agent-lab stays in `ACTIVE_REPOS`.
6. Tomorrow morning, read the first complete `runs.jsonl`, `denials.jsonl` and `tool-failures.jsonl`.

`/unstick` walks items 1 to 5 in this order.

## Sources and limits

All 55 routine logs in `~/.agentic-skills/routines/logs` on the pipeline host, Monday 04:00 to Sunday 06:05.
Each run's start, end, exit code, duration, runner notes and contract lines were extracted by script, and
the raw log was read wherever a claim needed more than its contract lines; for `wake-status-digest` and
`skill-assess-weekly`, the final message came from their run envelopes. Ledgers: `runs.jsonl` (8 rows),
`sends.jsonl` (29), two review verdicts. GitHub: pull requests and issues created in the window across the
seven active repos.

A log holds only each run's final message, so a decision a run made and did not report is invisible.
Telegram texts are not stored, only their length and the issues they cite. Spend is measured for two
routines.
