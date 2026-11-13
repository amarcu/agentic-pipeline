---
name: unstick
description: The daily review sitting — walks the human through everything waiting on them, most-unblocking first, acting only on their explicit yes per item. Use when the human sits down to review, asks what is waiting on them, or wants the pipeline unstuck.
argument-hint: "[--host <ssh-alias>]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/agenda:*), Bash(${CLAUDE_SKILL_DIR}/scripts/log-session:*), Bash(gh issue:*), Bash(gh pr:*), Bash(gh label:*), Bash(ssh pipeline-host:*), Skill
model: claude-opus-5
effort: high
---

# Unstick

You walk the human through everything the pipeline is waiting on, one item at a time, in the order that frees the most work. You produce only the decisions they make, and one dated line in the session log. You never decide for them: nothing is approved, closed, marked ready or merged without their explicit yes for that item.

## Limits

- Roster: `ACTIVE_REPOS` in `${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf`, plus this repo's PRs; `DISPATCH_PER_REPO_MAX` and `get_driver` there feed the order.
- Never batched. The 19:00 `daily-review-nudge` reports this queue; this drains it and sends nothing.

Read `${CLAUDE_SKILL_DIR}/BASELINE.md` first and apply its five principles throughout.

## Arguments

`$ARGUMENTS`

- `--host <ssh-alias>` — the pipeline host that answers HOST (default: `pipeline-host`); the agenda falls back to this machine and says so.

## Contract

- **Refuses when**: `agenda` exits 2 — print `HALT: unstick agenda-unavailable`.
- **Writes**: only what the human confirmed per step (label, close, ready, merge, unblock, decision comment), plus one line appended to `$HOME/.agentic-skills/routines/logs/unstick.log`.
- **Halts**: on anything that needs the pipeline host changed (Xcode, a clone) — hand it back with the item's `hints`.
- **Budget**: one agenda per sitting, one drill per undecided item.

## Steps

### Step 0 — Build the agenda

```bash
${CLAUDE_SKILL_DIR}/scripts/agenda --host pipeline-host --json
```

(`--host` replaces `pipeline-host`.) Show the header, notes and errors, the numbered items one line each, then each `more` line — counted, not walked. Ask where to start (default: item 1).

→ verify: the count shown equals the number of `items`; each repo in `errors` is named as missing.

### Step 1 — Walk the items, one at a time

Describe the item in one sentence (`gh issue view` / `gh pr view` if needed) and offer its choices; any item can be left or drilled (Step 2):

- **HOST** — hand back what is missing and its hint; once fixed, recheck: `ssh pipeline-host '<agentic-skills checkout>/launchd-runtime/bin/check-requirements <repo>'`.
- **MERGE** — run its `steps` in order, each its own question: `ready` asks "mark #N ready?", then `gh pr ready <n> --repo <r>`; `merge` asks "merge #N?", then `gh pr merge <n> --repo <r>`. Marking ready is a prior step the human confirms, never a fallback after a refused merge.
- **REVIEW** — a comment on what it still needs, or print `launchd-runtime/bin/cursor-review <r> <n> --post` for after the sitting. No `gh pr ready`: only a passed adversarial review moves it to MERGE.
- **APPROVE** — `gh issue edit <n> --repo <r> --add-label approved`, or retire it (below).
- **BLOCKED** — once the human says the cause is fixed, `gh issue edit <n> --repo <r> --remove-label <label>`; or retire it.
- **DIRECTION** — Step 2.

Retiring is a close **and** a label — `gh label create retired --repo <r> --color 6e7781 --force` (it may not exist yet; `--add-label` fails when it does not), then `gh issue close <n> --repo <r> --reason "not planned" --comment "<the reason>"`, then `gh issue edit <n> --repo <r> --add-label retired`. `propose-tasks` reads that label and nothing else, so a bare close leaves the work proposable and the human answers the same question next week. Where the repo has an `agent/FOCUS.md`, print the *Not now* line the next `/plan-features` session should carry: `- <title> (#<n>, retired <date>) — <reason>`; this skill never edits a repo's documents itself.

Act only on an explicit yes for that step; for ready and merge the yes names the PR number. Print its `UNSTUCK:` line.

→ verify: re-read it (`gh pr view <n> --json state,isDraft`, `gh issue view <n> --json state,labels`) before the next step.

### Step 2 — Route what needs a decision

- **DIRECTION** — `/plan-features` is human-typed only: print `/plan-features --repo <owner/repo>` for after the sitting. An open focus PR in the detail takes its own MERGE or REVIEW route first, not re-planned.
- **Undecided** (a design ambiguity, a hesitant approve-or-close) — drill. For design-heavy items prefer `mattpocock-skills:grilling` if this session lists it (bare `grilling` will not resolve); otherwise:
  1. Name the decision in one line. Look facts up yourself; ask the human only for decisions.
  2. Ask one round of numbered questions, each with your recommended answer.
  3. Challenge each answer with its strongest counter-case.
  4. Ask again only about what is still open; stop the moment the decision fits one sentence.
  5. On a yes, post that sentence (`gh issue comment` / `gh pr comment`) with the marker below, then act on it after its own yes.

→ verify: the comment shows in `gh issue view <n> --comments`; each routed repo has its command printed.

### Step 3 — Close the sitting

Print what was unstuck and what remains, by id. If the agenda held a DIRECTION item whose detail names no open focus PR, hand over to it: print its `DRILL:` line and offer to start now — the human types the command. An open focus PR takes its MERGE or REVIEW route first, so that day has no drill. Then:

```bash
${CLAUDE_SKILL_DIR}/scripts/log-session "items=<N> unstuck=<n> routed=<n> skipped=<n> remaining=<n> host=<pipeline-host|local>"
```

→ verify: it printed the `SESSION:` line it appended.

## Output contract

```
UNSTUCK: <id> action=<approved|retired|ready|merged|unblocked|commented|routed|handed-back|skipped>
DRILL: /plan-features --repo <owner/repo> | <the DIRECTION item's detail>
SESSION: <timestamp> <the fields given to log-session>
HALT: unstick <reason>
```

## Hard rules

- `gh pr ready` / `gh pr merge` only on this conversation's explicit yes naming that PR — BASELINE, *Merging and Marking PRs Ready*. Never force-push.
- Never add `approved` on the human's behalf; a yes covers one step, never the next.
- Never close an issue without the `retired` label following it, and never either without their yes.
- Never edit a repo's code, `repos.conf` or `permissions/`; never change the pipeline host.
- A denied command is a stop signal — BASELINE, *Respect the Denial*.
- Comments end `<!-- agentic-skills: skill=unstick repo=<owner/repo> issue|pr=<n> routine=interactive run=none model=claude-opus-5 -->`.

## Additional resources

- `${CLAUDE_SKILL_DIR}/scripts/agenda` (read-only; its docstring defines each section and the order) and `${CLAUDE_SKILL_DIR}/scripts/log-session` (append-only).
