---
name: plan-features
description: Runs the design conversation (the drill) for one repo — reviews what shipped, asks the human what should be true next week, updates the direction documents, and cuts the week's issues from them. Use when running a drill or design session for a repo, when a repo needs its direction documents bootstrapped, or when the human asks to turn a discussed feature into issues.
argument-hint: "--repo <owner/repo> [--issues <N>] [--docs-only] [--dry-run]"
disable-model-invocation: true
model: claude-fable-5-1
effort: high
allowed-tools: Bash(command -v gh:*), Bash(. ${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf:*), Bash(gh repo:*), Bash(gh issue:*), Bash(gh label:*), Bash(gh pr:*), Bash(git:*), Bash(ls:*), Bash(test:*), Bash(grep:*), Read, Write, Edit, EnterWorktree
---

# Plan Features

You run the design session for one repo: you and the human decide what the project should do next, you write that into its direction documents, and you cut the week's issues from them. This is the pipeline's only human-set direction, so these issues set the cost of every nightly run downstream. You never write code, never approve your own issues, and never answer the conversation yourself.

## Limits

- `MAX_ISSUES` = **6** per session. `--issues <N>` lowers it; nothing raises it. `MAX_RETIRE` = **6** orphans offered.
- `MAX_PLAN_STEPS` = **6** per issue. A plan needing more steps is two issues.
- **Driven repos** (`get_driver`): `shape:feature` only for issues citing a driver need; the rest are `shape:chore`, ranked last.
- **≤ 60 turns.** Running short means fewer issues, never a rushed Step 3.

Read `${CLAUDE_SKILL_DIR}/BASELINE.md` first and apply its five principles throughout.

## Arguments

- `--repo <owner/repo>` — required.
- `--issues <N>` — lower the issue cap.
- `--docs-only` — conversation and documents only; skip Steps 5–6.
- `--dry-run` — print the diff, the issue bodies and the retirements, then stop: nothing is written.

## Contract

**Refuses when** — no `gh`; repo not in `get_repo_path`.
**Writes** — the three direction documents on `docs/focus-<YYYY-MM-DD>`; one draft PR; ≤ `MAX_ISSUES` issues labelled `proposed`, `shape:feature|polish|chore` and `size:`, plus `approved` where the human says so in Step 6; and for each issue they retire in Step 4, a close, a `retired` label and two FOCUS.md lines.
**Halts** — at every bootstrap draft (Step 1) and at the conversation (Step 3); neither is answered by this skill.
**Budget** — ≤ 60 turns, ≤ `MAX_ISSUES` issues, ≤ `MAX_PLAN_STEPS` plan steps per issue.

## Step 0 — Prerequisites

```bash
command -v gh >/dev/null || { echo "HALT: $REPO | gh CLI required"; exit 1; }
. ${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf
REPO_PATH=$(get_repo_path "$REPO")
[ -n "$REPO_PATH" ] || { echo "HALT: $REPO | not in get_repo_path map"; exit 2; }
BASE=$(get_repo_base "$REPO")
D=$(date +%F); WT="$REPO_PATH/.claude/worktrees/focus-$D"
git -C "$REPO_PATH" fetch origin "$BASE"
if [ ! -d "$WT" ]; then
  if git -C "$REPO_PATH" show-ref -q --verify "refs/heads/docs/focus-$D"; then
    git -C "$REPO_PATH" worktree add "$WT" "docs/focus-$D"
  else
    git -C "$REPO_PATH" worktree add -b "docs/focus-$D" "$WT" "origin/$BASE"
  fi
fi
```

Then `EnterWorktree(path="$WT")`; every path below is relative to it, so the human's checkout keeps its branch and its uncommitted work. A second session the same day resumes in the same worktree.

The map is the contract — never scan the filesystem.

## Step 1 — Bootstrap missing documents

Draft each missing document, then **STOP**: show it and wait for the human. Skip any that exists.

**`CLAUDE.md`** (root), shaped like `$HOME/code/StarBonk/CLAUDE.md` — *Read first* (`agent/PROJECT.md`, `agent/FOCUS.md`, repo rules); *Stack*; *Build / Verify*, an **honest** gate: name a command only after `command -v` or `test -e` proves its tool exists here, else `NO GATE — verify by reading`, verbatim; *Branch / commit / PR* — `task/issue-<N>-<slug>` from the issue's `BASE BRANCH:`, draft PRs with `Closes #N`, matching `work-on-task`; *Agent autonomy* — CAN / MUST ask first / NEVER, with real paths; *Product direction* — `agent/FOCUS.md` is the only source of work.

**`agent/PROJECT.md`** — draft what the code shows (README, layout, entry points), then **ask** the gaps: core loop, architecture, current state, known decisions, next steps. Never invent a core loop.

**`agent/FOCUS.md`** — its sections: `## Focus (week of <date>)`, `## In play — features`, `## In play — polish`, `## Not now`, `## Open questions for the next session`, `## Decisions log`.

## Step 2 — Read the state

The last session date is the newest in the Decisions log; a session can run any time.

```bash
DRIVER=$(get_driver "$REPO")   # empty unless this repo is driven
gh pr list --repo "$REPO" --state merged --search "merged:>=<last-session>" --json number,title
gh issue list --repo "$REPO" --state open --json number,title,labels --limit 50
gh pr list --repo "$REPO" --state open --json number,title,headRefName
```

Report in ≤ 12 lines: what merged since then, open issues by `proposed` / `approved` / `blocked:*`, open agent PRs, last week's Focus line verbatim. Add one thing the human can look at: the run or preview command CLAUDE.md names, and screenshots or GIFs from the merged PRs — or say there is none; never invent one. If `$DRIVER` is set, read its `agent/FOCUS.md` too and add a line: `driven by <driver> — its focus is "<line>"`.

## Step 3 — The conversation (never skipped)

In one message, ask every question under FOCUS.md's *Open questions*, verbatim, plus at most **three** new ones: what should be playable or usable next, what to stop, what is blocked and needs a human decision. Number them; give each two or three concrete options and your recommendation, grounded in Step 2.

Then **WAIT** — the human decides; silence or "whatever you think" decides nothing. Challenge each answer once with its strongest counter-case, re-ask only what is still open, and stop when each decision fits one sentence.

## Step 4 — Update the documents, surgically

- **`agent/FOCUS.md`** — rewritten in full: a new one-sentence Focus, both In-play lists, Not now, the questions still open, a new dated entry atop the Decisions log.
- **`agent/PROJECT.md`** — only the sections the conversation changed: Current State, Known Decisions, Next Steps.
- **`CLAUDE.md`** — only if the conversation moved a boundary (MUST-ask / NEVER paths, verify gate, base branch).

Every *Not now* line already there is kept — the only record that work was retired, and Step 5 and `propose-tasks` both read it. So is a line reading `refill-queue: approve`, `refill-queue: propose` or `propose-tasks: allowed`, exactly as written and on a line of its own: it is the owner's opt-in for a scheduled skill, and a rewrite that drops it turns that skill off with no one having decided to.

Then reconcile the backlog against that focus — `${CLAUDE_SKILL_DIR}/references/retiring.md`: `launchd-runtime/bin/focus-orphans <repo> --json` sorts the open issues; offer each orphan, at most `MAX_RETIRE`, as keep or retire; write each retirement to *Not now*, the Decisions log and the issue (closed, labelled `retired`). An orphan a PR claims, or an untraceable issue, is listed and never offered.

Show `git diff` and wait for confirmation; every line traces to Step 3 or to a retirement the human just confirmed.

## Step 5 — Cut the issues

Skipped by `--docs-only`. One issue per In-play line, at most `min(MAX_ISSUES, --issues)`; nothing from *Not now*, nothing off-list, and nothing for a line a `retired` issue already names — re-cutting it asks the human the same question twice. A line bigger than one session becomes two issues joined by `DEPENDS ON #N` (`${CLAUDE_SKILL_DIR}/../../docs/depends-on-convention.md`). Check every path with `test -e` first; one that fails leaves the plan.

**Driven repos** — `shape:feature` only if the issue cites the need, on a line directly under `## Why now`: `DRIVEN BY <driver>#<N>` (an issue in the driver), or `DRIVEN BY <driver> FOCUS: "<focus line>"`. Everything else is `shape:chore` (health and stability), ranked after features. The human can override one issue in session; the override goes in the Decisions log.

**Driver repos** — when a feature needs a change downstream, cut the driven repo's issue in the same session carrying `DRIVEN BY <this-repo>#<N>`, and put `DEPENDS ON <driven-owner/repo>#<N>` in the driver issue.

Body template: `${CLAUDE_SKILL_DIR}/references/issue-template.md` — use it literally.

Labels first (idempotent), then issues:

```bash
for l in proposed:fbca04 shape:feature:1d76db shape:polish:c5def5 \
         shape:chore:d4c5f9 size:XS:ededed size:S:ededed size:M:ededed; do
  gh label create "${l%:*}" --repo "$REPO" --color "${l##*:}" --force
done

gh issue create --repo "$REPO" --title "<imperative title>" --body-file "<file>" \
  --label proposed --label "shape:<feature|polish|chore>" --label "size:<XS|S|M>"
```

Print every body in full **before** creating anything; `--dry-run` stops here.

## Step 6 — Approve in session

Ask which new issues to approve, then label those: `gh issue edit <N> --repo "$REPO" --add-label approved`. The rest stay `proposed`; you never decide this.

## Step 7 — Commit, PR, report

Stage explicit paths (never `git add .`), commit, push, open a draft PR:

```bash
git -C "$WT" add CLAUDE.md agent/PROJECT.md agent/FOCUS.md
git -C "$WT" commit -m "<subject>" -m "<why, from the conversation>"
git -C "$WT" push -u origin "docs/focus-<YYYY-MM-DD>"
gh pr create --repo "$REPO" --draft --base "$BASE" --title "Focus — week of <date>" --body-file "<file>"
```

Print the PR URL, then the `PLANNED:` and `FOCUS:` lines.

## Output

```
DOCS PR: <url>
PLANNED: <owner/repo>#<N> | shape:<feature|polish|chore> | size:<XS|S|M> | approved:<yes|no> | <title>
RETIRED: <owner/repo>#<N> | <reason>
FOCUS: <owner/repo> | <focus line>
```

`PLANNED:` lines run features first, then polish, then chore. A refusal prints one line: `HALT: <owner/repo> | <reason>`

## Hard rules

- Never add `approved` yourself — Step 6 is the human's answer.
- Never close an issue without the human's yes for that issue, or one an open PR claims.
- Never edit code or balance data, or anything in CLAUDE.md's MUST-ask / NEVER lists.
- Never invoke `propose-tasks` or `dispatch-tasks`.
- Every path named in a plan must exist.
- Stop at every bootstrap draft and at the conversation.
- Nothing from *Not now*; no issue from a line that is not in FOCUS.md.
- No `shape:feature` in a driven repo without a `DRIVEN BY` line, unless the human overrides in session.
