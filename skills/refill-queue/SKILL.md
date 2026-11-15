---
name: refill-queue
description: Cuts the next issues from the In-play lines of a repo's `agent/FOCUS.md` when its approved queue has run low, and approves them only where the repo's own focus file allows it. Use when a scheduled run finds a human-led repo with nothing left to dispatch.
argument-hint: "--repo <owner/repo> [--max <N>] [--force] [--dry-run]"
model: claude-opus-4-8
effort: medium
allowed-tools: Bash(command -v gh:*), Bash(gh issue:*), Bash(gh label:*), Bash(. ${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf:*), Bash(${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/focus-queue:*), Bash(git -C * fetch origin *), Bash(git -C * show origin/*), Bash(grep:*), Bash(cat:*), Bash(echo:*), Bash(test:*), Read
disallowed-tools: Agent
---

# Refill Queue

You are the headless half of the design session for one repo whose direction is human-led. You produce at most `MAX_PER_RUN` GitHub issues, each cut from one In-play line of that repo's `agent/FOCUS.md` and quoting it. You never change the focus, never cut an issue from anything that is not an In-play line, and never approve an issue the repo's own focus file has not let you approve.

## Limits

- `MAX_PER_RUN` = **2** issues per run: the ceiling and the default. `--max <N>` may only lower it.
- `QUEUE_MIN` = **2** approved issues waiting. At or above it the queue is not low, and the run halts.
- `MAX_HELD` = **2** unapproved `proposed` issues open in this repo. At or above it, halt: the human has not answered the last ones.
- `MAX_PLAN_STEPS` = **6** per issue, as `plan-features` sets it. A plan needing more is two issues.
- The cross-repo gate is `PROPOSED_BACKLOG_MAX` in `launchd-runtime/repos.conf`: the routine's number, read there and never restated here.

Read `${CLAUDE_SKILL_DIR}/BASELINE.md` first and apply its five principles throughout.

## Arguments

`$ARGUMENTS`

- `--repo <owner/repo>` — required.
- `--max <N>` — lower `MAX_PER_RUN`. A larger value is clamped to it, never obeyed.
- `--force` — run by hand, with `ROUTINE` unset.
- `--dry-run` — every read and decision, each issue body and its `PLANNED:` line, then return before the first `gh issue create`.

## Contract

- **Refuses when**: `ROUTINE` is unset without `--dry-run` or `--force` (Step 0); no `gh`; repo not in `get_repo_path`; no root `CLAUDE.md` or no `agent/FOCUS.md` on the base branch.
- **Writes**: the `proposed`, `shape:*` and `size:*` labels (idempotent) and up to `MAX_PER_RUN` issues carrying them, with the repo's existing `approved` label where Step 5 allows it. No label on an existing issue, no comment, no file in the repo.
- **Halts**: the focus file has no `refill-queue:` line; GitHub could not be read; `QUEUE_MIN` approved issues already wait; `MAX_HELD` proposals await the human; no In-play line is left to cut.
- **Budget**: one repo, `MAX_PER_RUN` issues, no Telegram. The digest belongs to the routine.

## Steps

Shell state does not survive between commands, so every value below is substituted literally, never `VAR=$(...)`. `<owner/repo>` is `--repo`; Step 1 reads `<repo path>` and `<base>`.

### Step 0 — Refuse a hand-started run

```bash
echo "routine=${ROUTINE:-interactive} dry_run=${ROUTINE_DRY_RUN:-0}"
```

Only `launchd-runtime/bin/_run.sh` exports `ROUTINE`. When that prints `interactive` and neither `--dry-run` nor `--force` was passed, print `HALT: refill-queue interactive-run-refused (set --dry-run or --force)` and exit 0. `dry_run=1` is `--dry-run`.

→ verify: the echo named a routine, or a flag was passed.

### Step 1 — Resolve the repo and read its two authorities from the base branch

Sourcing dies with the call, so this is one command; it prints `<repo path>` then `<base>`:

```bash
command -v gh
. ${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf
get_repo_path "<owner/repo>"
get_repo_base "<owner/repo>"
```

An empty path is `HALT: <owner/repo> | not in get_repo_path map`, never a filesystem search. Then read the focus and the constraints as the base branch has them, not as the checkout happens to:

```bash
git -C "<repo path>" fetch origin "<base>"
```

```bash
git -C "<repo path>" show "origin/<base>:agent/FOCUS.md" > /tmp/refill-queue-focus.md
```

```bash
git -C "<repo path>" show "origin/<base>:CLAUDE.md" > /tmp/refill-queue-claude.md
```

A `show` that fails is `HALT: <owner/repo> | no agent/FOCUS.md on <base>` or `HALT: <owner/repo> | no CLAUDE.md on <base>`. Read both files: the focus is what you may cut from, and CLAUDE.md's CAN, MUST-ask-first and NEVER lists are what Step 5 decides on.

→ verify: both `/tmp/refill-queue-*.md` files are non-empty.

### Step 2 — Ask the script whether to run, and from which lines

```bash
${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/focus-queue "<owner/repo>" --focus /tmp/refill-queue-focus.md
```

It prints `MODE:`, `QUEUE:`, one `UNCUT:` line per In-play line no issue was cut from, and `FOCUSQUEUE:`. Its answers are final: never decide for yourself that a line is or is not already covered. Halt, in this order, on the first that applies:

| The script says | Print and exit 0 |
|---|---|
| exit 1, or an `ERROR:` line | `HALT: <owner/repo> \| GitHub could not be read` |
| `MODE: … \| off` | `HALT: <owner/repo> \| refill not enabled (no refill-queue: line in agent/FOCUS.md)` |
| `approved_waiting` at or above `QUEUE_MIN` | `HALT: <owner/repo> \| queue holds <n> approved issues` |
| `proposed_unapproved` at or above `MAX_HELD` | `HALT: <owner/repo> \| <n> proposals await approval` |
| no `UNCUT:` line | `HALT: <owner/repo> \| in play is exhausted — a planning session is due` |

→ verify: a `HALT:` line was printed and the run ended, or the mode is `approve` or `propose` and at least one `UNCUT:` line is in hand.

### Step 3 — Take the lines in order

Take `UNCUT:` lines from the top, in the order printed, until the issues they need reach `min(MAX_PER_RUN, --max)`. Do not skip ahead to a line that looks easier: the order is the human's. One line is one issue, or two joined by a `DEPENDS ON #N` line when it is more than one session (`${CLAUDE_SKILL_DIR}/../../docs/depends-on-convention.md`); a line that needs two when one slot is left waits for the next run.

→ verify: every issue to be cut names the one `UNCUT:` line it comes from.

### Step 4 — Compose each issue

The body template is `plan-features`' own, used literally: `${CLAUDE_SKILL_DIR}/../plan-features/references/issue-template.md`. Read it here. Three things are fixed on top of it:

- `## Why now` holds the `UNCUT:` line **whole, verbatim, on one line**, as `FOCUS.md In play: "<line>"`. That quote is what tells the next run the line is cut; a paraphrase cuts it again tomorrow.
- The plan is written from the code as it is in `<repo path>`. Check every path it names with `test -e`; one that fails leaves the plan.
- When the line does not settle something the worker would have to guess (which of two behaviours, a number, an asset nobody has bought), add a `## Open question` section that asks it, with your recommendation. Never guess it into the acceptance criteria.

End every body with the template's `plan-features run:` comment and then the attribution marker:

```
<!-- agentic-skills: skill=refill-queue repo=<owner/repo> issue=- routine=${ROUTINE:-interactive} run=${ROUTINE_RUN_ID:-none} model=claude-opus-4-8 -->
```

→ verify: each body's `## Why now` contains its `UNCUT:` line character for character, every `test -e` passed, no "depends on" in a plan.

### Step 5 — Decide which issues may carry `approved`

Under `MODE: propose`, none. Under `MODE: approve`, an issue is approved only when **every** line below is true; otherwise it is created as `proposed` alone and its body gains a `## Held for the owner` section naming the line that failed.

1. Its `## Why now` quotes one `UNCUT:` line verbatim (Step 4).
2. Its size is `XS`, `S` or `M`.
3. Nothing in its Breakdown or plan touches a path or a system on CLAUDE.md's MUST-ask-first or NEVER lists, and it carries no pre-approval line such as `SCENE: allowed`. A FOCUS.md Decisions-log entry that records the owner's yes for this feature by name lifts this for that feature only.
4. It has no `## Open question` section.

When in doubt about line 3, the issue is held. A held issue costs the owner one label; a wrongly approved one costs a nightly run and a review.

→ verify: each issue is marked approved or held, and each held one names the failed line.

### Step 6 — Create the labels, then the issues

`--dry-run` prints each body and its `PLANNED:` line and returns here, before any mutation.

```bash
for l in proposed:fbca04 shape:feature:1d76db shape:polish:c5def5 shape:chore:d4c5f9 size:XS:ededed size:S:ededed size:M:ededed; do
  gh label create "${l%:*}" --repo "<owner/repo>" --color "${l##*:}" --force
done
gh label list --repo "<owner/repo>" --search approved --json name --jq '[.[] | select(.name == "approved")] | length'
```

`approved` is the owner's label and is never created or recoloured here. When that last command prints `0`, the repo has no such label: every issue this run is held, with that as the reason.

Write each body to a literal path, `/tmp/refill-queue-issue-1.md` and `-2.md`, then:

```bash
gh issue create --repo "<owner/repo>" --title "<imperative title>" --body-file "/tmp/refill-queue-issue-<k>.md" \
  --label proposed --label "shape:<feature|polish|chore>" --label "size:<XS|S|M>"
```

with `--label approved` added for an issue Step 5 approved, and for no other. `shape:` is `feature` for a line under *In play — features* and `polish` for one under *In play — polish*.

→ verify: `gh issue view <N> --repo "<owner/repo>" --json labels` lists the labels, and `approved` only where Step 5 said so.

### Step 7 — Report

One `PLANNED:` line per created issue, in creation order, as the last lines of the final message.

→ verify: one `PLANNED:` line per issue, and nothing was sent.

## Output contract

```
PLANNED: <owner/repo>#<N> | shape:<feature|polish|chore> | size:<XS|S|M> | approved:<yes|no> | <title>
HALT: <owner/repo> | <reason>
```

`PLANNED:` is the line `plan-features` prints for the same thing. A run that creates nothing prints one `HALT:` line and no `PLANNED:`. Every halt is clean — print the line, exit 0 — so the routine moves to its next repo.

## Hard rules

- Never cut an issue from anything but an `UNCUT:` line the script printed this run; nothing from *Not now*, nothing off-list.
- Never add `approved` under `MODE: propose`, or to an issue that fails any line of Step 5, or to any existing issue. The opt-in is the repo's, in a file only the owner merges.
- Never edit `agent/FOCUS.md`, `CLAUDE.md` or any other file in the repo; never close, edit or re-label an existing issue.
- Never invoke `dispatch-tasks`, `work-on-task` or `plan-features`.
- No Telegram: the routine sends the one digest. Quiet by default — BASELINE Principle 5.
- Anything sensitive, irreversible or externally visible goes through `/request-approval`, which stops the run.
- A denied command is a stop signal, not a workaround puzzle — BASELINE, *Respect the Denial*.

## Additional resources

- `${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/focus-queue` — the opt-in, the queue counts and the uncut lines. Its header says how a line counts as cut.
- `${CLAUDE_SKILL_DIR}/../plan-features/references/issue-template.md` — the issue body, shared with `plan-features` and `propose-tasks`.
