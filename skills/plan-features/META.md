---
domain: universal
kind: coding
version: 0.3.0
status: experimental
last-assessed: 2026-09-27
---

## Purpose
The design session (the drill), one repo at a time, on whatever day `unstick` hands it over. The human and Claude discuss what the project should be able to do next week; the outcome is written into the repo's direction documents (`agent/FOCUS.md`, `agent/PROJECT.md`, and `CLAUDE.md` when a boundary moves), the work the new focus drops is retired, and the rest is cut into GitHub issues that the nightly workers implement.

This replaces `propose-tasks` as the source of product work in repos that have a `FOCUS.md`. The TODO-sweep generator is structurally biased toward test-only and cleanup tasks because those are the signals it can see in code; features and polish only come from a human saying what the product should do. The two are not meant to run against the same repo:

```
plan-features (human-led drill) → proposed/approved issues → dispatch-tasks → work-on-task → draft PR
```

## Dependencies
- `gh` CLI, authenticated
- Target repo must be in `get_repo_path` in `launchd-runtime/repos.conf` — the skill refuses rather than scanning the filesystem
- A clean checkout on the default branch (the skill creates `docs/focus-<YYYY-MM-DD>` itself)
- `get_driver` in `launchd-runtime/repos.conf` for the driver relation (see below)
- `docs/depends-on-convention.md` for the `DEPENDS ON #N` grammar used when one In-play line splits into two issues
- Labels `proposed`, `shape:feature`, `shape:polish`, `shape:chore`, `size:XS|S|M` — created idempotently by the skill

## Model / budget
Runs on **`claude-fable-5-1` at `effort: high`** — the only place in the pipeline that uses the expensive model, and deliberately so. Everything downstream (`dispatch-tasks`, `work-on-task`, `iterate-on-pr`) is cheap-model work whose cost is set by how well-specified the issue is; a vague issue is paid for again in every retry, every wrong file touched, and every review round. One good hour here is cheaper than a week of confused nights.

`kind: coding` — by elimination, and it selects the 10 KB `SKILL.md` budget (`readonly` would get 6 KB). The skill never writes code, but it is not `readonly` either: it writes three documents and creates issues. `meta` is for skills operating on this repo's own skills, which this is not.

Budget per run: **≤ 6 issues**, **≤ 6 plan steps per issue**, **≤ 60 turns**. `disable-model-invocation: true` — this skill is never auto-selected; the human starts it, because it is interactive by design and stops twice to wait for them.

## Driver and driven repos
Some repos exist to serve another. `get_driver` in `repos.conf` owns that relation — it is the single source of truth, and only pairs the human has actually stated belong in it:

| Driven repo | Driver | Why |
|---|---|---|
| `acme/game-engine` | `acme/GameTwo` | game → engine |
| `acme/engine-toolkit` | `acme/GameTwo` | game → framework |
| `amarcu/StarBonk-backend` | `amarcu/StarBonk` | game → backend |
| `acme/agent-lab` | `acme/agent-lab-platform` | platform → generated public repo |

A driven repo gets feature work only when its driver needs it. In a driven repo an issue may carry `shape:feature` only if it cites that need on a `DRIVEN BY <driver>#<N>` or `DRIVEN BY <driver> FOCUS: "<line>"` line directly under `## Why now`; everything else is `shape:chore` — health and stability work (tests, chores, reliability) that ranks after features in the session's output. The human can override one issue by saying so in the session, and the override is recorded in FOCUS.md's Decisions log.

Working the other way: in a driver repo, a feature needing a downstream change cuts the driven repo's issue in the same session (carrying `DRIVEN BY`), and the driver issue gets a `DEPENDS ON <driven-owner/repo>#<N>` line so `dispatch-tasks` holds it until the downstream work is closed.

Step 2 reads the driver's `agent/FOCUS.md` alongside the repo's own, so the session can see what the driver is actually asking for this week.

## Halt conditions
1. **`gh` missing** or the repo is not in the `get_repo_path` map

Halts print one line (`HALT: <repo> | <reason>`) and do nothing else.

## Boundaries
- Never adds `approved` on its own — Step 6 asks, and the human answers
- Never closes an issue without the human's yes for that issue, and never one an open PR claims or one no focus line ever named — Step 4's reconcile offers, and the human answers
- Never edits code, balance data, or anything in CLAUDE.md's MUST-ask / NEVER lists
- Never invokes `propose-tasks` or `dispatch-tasks`
- Never cuts an issue from *Not now*, or from anything that is not a line in FOCUS.md
- Never shapes an issue as a feature in a driven repo without a `DRIVEN BY` citation, unless the human overrides in session
- Every path named in an implementation plan is checked with `test -e` before the issue is created — an advisory plan pointing at files that don't exist is worse than no plan

## Known Issues
- Not yet run end to end. StarBonk is the only repo with `agent/FOCUS.md` and `agent/PROJECT.md`; every other active repo will go through the Step 1 bootstrap on its first session, which is the longest and least-tested path.
- `get_driver` is consumed only by this skill so far. `dispatch-tasks` does not yet rank `shape:chore` below features across repos, so the priority half of the rule holds only within a planning session.
- The overlap with `propose-tasks` is documented but not enforced — nothing stops both from running against the same repo. StarBonk's CLAUDE.md handles this in prose ("autonomous proposals are not wanted in this repo").

## Changelog
- 2026-09-27 (v0.3.0): The session is a drill that runs any day. The weekly lockout and the dirty-checkout refusal are gone: the session works in its own worktree off the repo's base branch (`get_repo_base` when present), so the human's checkout is untouched. Step 2 names one thing to look at (the run command or merged-PR screenshots, never invented). Step 3 gives each question options and a recommendation, then challenges each answer once — the same moves as `unstick`'s drill — while still waiting for the human's decision. `unstick` hands the day's drill over at the end of the sitting.
- 2026-09-14 (v0.2.0): Step 4 now reconciles the backlog against the focus it just wrote (`references/retiring.md`), because closing an issue alone reaches nothing that decides what to work on next (issue #62). `launchd-runtime/bin/focus-orphans` sorts the open issues into traces, orphan and untraceable — a script, so the list does not move between runs — and each retirement the human confirms is written to *Not now*, to the Decisions log, and to the issue as a close plus the `retired` label, which is what `propose-tasks` queries. It sits in Step 4 and not with Step 5's issues so retirements appear in the diff the human confirms and survive `--docs-only`. `MAX_RETIRE` is 6. The issue body template moved to `references/issue-template.md`, which made room under the 10 KB budget.
- 2026-09-03 (v0.1.0): Initial version. Human-led weekly planning to replace the TODO sweep as the source of product direction; maintains the direction documents in the same session as the issues it cuts from them. Includes the driver/driven relation (`get_driver` in `repos.conf`) and the `shape:chore` label it implies.
