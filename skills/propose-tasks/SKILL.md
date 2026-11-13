---
name: propose-tasks
description: The maintenance sweep for a repo whose direction is not human-led — surveys its signals and cuts at most two `proposed` chore issues for human approval. Use when a repo needs its nightly chore proposals; features come from `plan-features` instead.
argument-hint: "--repo <owner/repo> [--max <N>] [--notify] [--force] [--dry-run]"
model: claude-sonnet-5
effort: medium
allowed-tools: Bash(command -v gh:*), Bash(gh issue:*), Bash(gh label:*), Bash(gh repo view:*), Bash(. ${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf:*), Bash(git log:*), Bash(grep:*), Bash(cat:*), Bash(echo:*), Bash(test:*), Bash(/usr/bin/python3 ${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/telegram-send:*), Read
---

# Propose Tasks

You are the autonomous maintenance sweep for one repo whose direction is not human-led. You produce
at most `MAX_PER_RUN` GitHub issues labelled `proposed`, `shape:chore` and `size:`, each one
session's work and reviewable in under a minute. You never propose a feature — features come from
the weekly design session `plan-features` runs — and you never approve, close or re-scope an issue.

## Limits

- `MAX_PER_RUN` = **2** issues per run: the ceiling *and* the default. `--max <N>` may only lower it.
- `MIN_TO_PROPOSE` = **1**. Below it the run creates nothing.
- `SATURATION` = **2** unapproved `proposed` issues open in this repo. At or above it, halt.
- The cross-repo gate is `PROPOSED_BACKLOG_MAX` in `launchd-runtime/repos.conf` — the routine's
  number, read there and never restated here.
- Repo paths: `get_repo_path` in the same file — the only way to find a clone.

Read `${CLAUDE_SKILL_DIR}/BASELINE.md` first and apply its five principles throughout.

## Arguments

- `--repo <owner/repo>` — required.
- `--max <N>` — lower `MAX_PER_RUN`. A larger value is clamped to it, never obeyed.
- `--notify` — send one Telegram for this run (default: off). Leave it off under a routine: the
  digest belongs to `morning-proposals`, and a send per repo is one event as many messages.
- `--force` — run by hand, with `ROUTINE` unset
- `--dry-run` — every read and decision, each issue body and its `PROPOSED:` line, then return
  before the first `gh issue create`.

## Contract

- **Refuses when**: `ROUTINE` is unset without `--dry-run` or `--force` (Step 0); no `gh`; repo not
  in `get_repo_path`; no root `CLAUDE.md`; `agent/FOCUS.md` present without a `propose-tasks:
  allowed` line.
- **Writes**: the `proposed`, `shape:chore` and `size:*` labels (idempotent) and up to
  `MAX_PER_RUN` issues carrying them. No label on an existing issue, no comment.
- **Halts**: saturation; fewer than `MIN_TO_PROPOSE` candidates after ranking; every candidate left
  already proposed by an earlier run.
- **Budget**: one repo, `MAX_PER_RUN` issues, one Telegram only under `--notify`.

## Steps

Shell state does not survive between commands, so every value below is substituted literally, never
`VAR=$(...)`. `<owner/repo>` is `--repo`; Step 1 reads `<repo path>` and `<base>`.

### Step 0 — Refuse a hand-started run

```bash
echo "routine=${ROUTINE:-interactive} dry_run=${ROUTINE_DRY_RUN:-0}"
```

Only `launchd-runtime/bin/_run.sh` exports `ROUTINE`. When that prints `interactive` and neither
`--dry-run` nor `--force` was passed, print `HALT: propose-tasks interactive-run-refused
(set --dry-run or --force)` and exit 0 — an interactive session must not fire scheduled work by
accident.

→ verify: the echo named a routine, or a flag was passed.

### Step 1 — Resolve the repo, or refuse

Sourcing dies with the call, so this is one command; it prints `<repo path>` then `<base>`:

```bash
command -v gh
. ${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf
get_repo_path "<owner/repo>"
get_repo_base "<owner/repo>"
```

Substitute both from here on, starting with the constraints file: `test -f "<repo path>/CLAUDE.md"`.

An empty path is `HALT: <owner/repo> | not in get_repo_path map` — never a filesystem search. No
root `CLAUDE.md` is `HALT: <owner/repo> | no CLAUDE.md`: its CAN / MUST ask first / NEVER lists are
what Step 5 filters on, and a proposal made without them is blind.

→ verify: `<repo path>/.git` exists, `<base>` is a branch, `CLAUDE.md` is readable.

### Step 2 — Defer to a human-led direction

```bash
test -f "<repo path>/agent/FOCUS.md" \
  && ! grep -qx "propose-tasks: allowed" "<repo path>/agent/FOCUS.md" \
  && echo halt || echo proceed
```

One word, exit 0 in all three cases: the decision is the output, never the status. `halt` means the
file exists without a line reading exactly `propose-tasks: allowed` — this repo's issues come from
the weekly design session, so stop with no signals, no issues and no Telegram, printing verbatim:

```
HALT: <owner/repo> | direction is human-led (agent/FOCUS.md present) — use /plan-features
```

`morning-proposals` matches that prefix and counts it a quiet repo, not a failure.

→ verify: the command printed `proceed`, or it printed `halt` and that exact line followed.

### Step 3 — Saturation check

```bash
gh issue list --repo "<owner/repo>" --state open --label proposed --json number,title,labels --limit 30 \
  --jq '[.[] | select((.labels | map(.name) | index("approved")) | not)] | length'
```

At or above `SATURATION`: `HALT: <owner/repo> | saturated (<n> unapproved proposals)`, and send
nothing — the routine carries the backpressure into its digest.

→ verify: the count printed, and is below `SATURATION`.

### Step 4 — Gather signals

Take the four signals in the order `${CLAUDE_SKILL_DIR}/references/signal-recipes.md` sets out,
stopping once `MAX_PER_RUN` candidates are in hand. Read it here: it holds each signal, its command
and filters, and the grep recipes.

Every proposal needs a concrete trigger from a signal. Imagination is not one.

#### Hard exclusion: file-splits based on line count

Line count is not a quality signal — BASELINE Principle 2. A split needs an observable coupling
problem; `signal-recipes.md` says what counts as one.

→ verify: every candidate names its signal — a path and line, an issue number, a commit.

### Step 5 — Rank, then drop the duplicates

Score each candidate on value, on whether its acceptance criteria fit in three sentences, on
single-session size, and on whether `CLAUDE.md`'s CAN list covers it. Failing either of the last
two drops it.

Then drop the duplicates: `${CLAUDE_SKILL_DIR}/references/duplicates.md` holds the two queries and
the rule. A candidate whose signal appears in an open issue, or in a closed one labelled `retired`,
is a duplicate (S7) — whoever filed it, because a retirement is a decision a human made. If fewer
than `MIN_TO_PROPOSE` survive: `HALT: <owner/repo> | no candidate above the bar`, no other trace
(BASELINE Principle 5).

→ verify: the list is at most `MAX_PER_RUN` long, and each dropped candidate names the issue it
matched.

### Step 6 — Compose each issue

`${CLAUDE_SKILL_DIR}/references/issue-template.md` holds the body template — Goal, Why now,
Breakdown, Implementation plan (advisory), Acceptance criteria, Estimated size, `BASE BRANCH:`,
Reference files, and the two trailing comments — with the rules governing it and the bar a proposal
must clear. Use it literally: it is the shape `plan-features` also cuts from.

Check every path the body names with `test -e` before the issue is created; one that fails leaves
the plan.

→ verify: every `test -e` passed, no "depends on" in the plan, the two comments last.

### Step 7 — Create the labels, then the issues

`--dry-run` prints each body and its `PROPOSED:` line and returns here, before any mutation.

```bash
for l in proposed:fbca04 shape:chore:d4c5f9 size:XS:ededed size:S:ededed size:M:ededed; do
  gh label create "${l%:*}" --repo "<owner/repo>" --color "${l##*:}" --force
done

gh issue create --repo "<owner/repo>" --title "<imperative title>" --body-file "<file>" \
  --label proposed --label shape:chore --label "size:<XS|S|M>"
```

`gh issue create` prints the issue URL; read the number off its end for the `PROPOSED:` line.

→ verify: `gh issue view <N> --repo "<owner/repo>" --json labels` lists all three labels.

### Step 8 — Report

One `PROPOSED:` line per created issue, in creation order. Under `--notify` only, write a
digest — the repo, the count, one line per issue — then send it unchained:

```bash
cat > /tmp/propose-tasks-digest.txt << 'EOF'
<the digest>
EOF
```

```bash
/usr/bin/python3 ${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/telegram-send /tmp/propose-tasks-digest.txt
```

The recipe and its constraints live in `notify/SKILL.md` only.

→ verify: one `PROPOSED:` line per issue, and `telegram-send` run zero times without `--notify`.

## Output contract

```
PROPOSED: <owner/repo>#<N> | shape:chore | size:<XS|S|M> | <title>
HALT: <owner/repo> | <reason>
```

A run that creates nothing prints one `HALT:` line and no `PROPOSED:`. Every halt is clean —
print the line, exit 0 — so the routine moves to its next repo rather than logging a failure.

## Hard rules

- Never propose where direction is human-led; `plan-features` cuts those issues.
- Never `shape:feature` — this skill proposes chores.
- Never propose work in `CLAUDE.md`'s MUST-ask-first or NEVER lists, or anything cross-repo or
  production-only; those go through `/request-approval`, which stops the run.
- Never add `approved`, close, edit or re-label an existing issue — the lifecycle is the human's.
- Telegram goes through the one recipe (S8), and only under `--notify`. Quiet by default —
  BASELINE Principle 5.
- A denied command is a stop signal, not a workaround puzzle — BASELINE, *Respect the Denial*.

## Additional resources

- `${CLAUDE_SKILL_DIR}/references/signal-recipes.md` — the per-stack grep recipes and exclusions,
  what makes a hit a candidate, and what counts as a real coupling problem; read it in Step 4.
- `${CLAUDE_SKILL_DIR}/references/issue-template.md` — the issue body template, the rules it answers
  to, the title form and the quality bar; read it in Step 6.
