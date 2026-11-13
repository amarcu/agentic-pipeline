---
name: dispatch-tasks
description: Dispatches approved GitHub issues to `work-on-task` one at a time, bounded per repo and overall by how many open agent PRs already await review. Use when a scheduled run has to turn the human's approvals into draft PRs.
argument-hint: "[--repos a,b,c] [--force] [--dry-run]"
allowed-tools: Bash(gh issue list:*), Bash(gh issue view:*), Bash(gh pr list:*), Bash(. ${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf:*), Bash(${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/check-requirements:*), Bash(${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/telegram-send:*), Bash(${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/jev-route:*), Bash(cat:*), Bash(echo:*), Bash(date:*), Skill, Read
model: claude-sonnet-5
effort: medium
---

# Dispatch Tasks

You are the dispatcher between the human's `approved` label and a draft pull request. You produce
one `work-on-task` worker per slot the gate leaves free and one digest of what they did, and never
do a worker's job inline.

## Configuration

- Repo roster and order: `REPOS_BY_PRIORITY` and `ACTIVE_REPOS` in `launchd-runtime/repos.conf`;
  `is_active_repo` decides membership, and a dormant repo is never dispatched.
- Caps, all in the same file, read at runtime and never restated here: `DISPATCH_TOTAL_MAX` is the
  global ceiling on open **agent PRs**, `DISPATCH_PER_REPO_MAX` the same count inside one repo, and
  `DISPATCH_RUN_MAX` the number of new dispatches one run may make.
- `get_driver <owner/repo>`, same file, prints a repo's driver or nothing — Step 1 filters and
  Step 3 orders by it.

Read `${CLAUDE_SKILL_DIR}/BASELINE.md` first and apply its
five principles throughout.

## Arguments

- `--repos a,b,c` — dispatch only these repos, in this order (default: `REPOS_BY_PRIORITY`)
- `--force` — run by hand, with `ROUTINE` unset
- `--dry-run` — every read and decision, every contract line, and Step 4's forks with `--dry-run`
  appended; no Telegram, label, comment or PR

## Contract

- **Refuses when**: `ROUTINE` is unset without `--dry-run` or `--force` (Step 0). Nothing else.
- **Writes**: no GitHub object and no attribution marker — one forked `work-on-task` per dispatched
  issue, and at most one Telegram digest per run.
- **Halts**: no eligible repo; an empty queue; every approved issue in progress, blocked, deferred
  or unanchored; three consecutive worker failures of one kind.
- **Budget**: `budget` issues per run; one `claude -p` session, one `--max-budget-usd` (`META.md`).

## Steps

### Step 0 — Refuse a hand-started run

```bash
echo "routine=${ROUTINE:-interactive} dry_run=${ROUTINE_DRY_RUN:-0}"
```

Only `launchd-runtime/bin/_run.sh` exports `ROUTINE`. When that prints `interactive` and neither
`--dry-run` nor `--force` was passed, print `HALT: dispatch-tasks interactive-run-refused
(set --dry-run or --force)` and exit 0 — an interactive session must not fire scheduled work by
accident.

→ verify: the echo named a routine, or a flag was passed.

### Step 1 — Build the queue, one repo per Bash call

For each repo in `--repos` or `REPOS_BY_PRIORITY` where `is_active_repo` succeeds, one Bash call
per repo — never one loop over all of them:

```bash
. ${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf
gh issue list --repo "$REPO" --state open --label approved --json number,title,createdAt,labels --limit 30
gh pr list --repo "$REPO" --state open --json number,headRefName,body,createdAt --limit 30
${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/check-requirements "$REPO" --quiet
```

Exit 1 drops the whole repo into `unmet`. Exit 0 dispatches normally.

A repo whose `gh` calls fail, or whose check exits 2, is recorded as `skipped:`, contributes zero
to the gate and is never re-scanned this run. If every repo fails, print the gate line, then
`HALT: dispatch-tasks github-unreachable`, then Step 5's end line.

Drop the approved issues `${CLAUDE_SKILL_DIR}/references/queue-building.md` names, by the tests
and labels it holds. Read it here.

→ verify: every active repo is in the queue counts, `unmet` or `skipped:` — three buckets, and
`references/queue-building.md` says which failure lands in which.

### Step 2 — The gate, before anything else

An **agent PR** is a Step 1 open PR whose `headRefName` starts with `task/issue-` or
`worktree-issue-`, or whose body contains `Closes #<n>`. Count them overall as `open_agent_prs`
and per repo as `open_agent_prs_r`, then:

- `slots = DISPATCH_TOTAL_MAX - open_agent_prs`
- `slots_r = DISPATCH_PER_REPO_MAX - open_agent_prs_r`, one per active repo
- `budget = min(slots, DISPATCH_RUN_MAX)`

A repo is **eligible** only when `budget > 0`, `slots_r > 0` and Step 1 left it an issue — a spent
`budget` empties `eligible` whatever room the repos have. `at_limit` names repos with
`slots_r <= 0`, `unmet` those Step 1's check dropped. `blocked` = the issues dropped for
a `blocked:` label — reported, never arithmetic.

Print the gate as the **first line of stdout on every run**, whatever the queue holds:

```
DISPATCH GATE: open_agent_prs=<n> cap=<N> per_repo=<P> run_max=<R> budget=<b> blocked=<k> unmet=<repo,repo|-> at_limit=<repo,repo|-> eligible=<repo,repo|->
```

Halt only when **no repo is eligible**, naming what reopens the gate: the oldest agent PR to land
in each `at_limit` repo, plus `global ceiling: land <owner/repo>#<n>` — the oldest agent PR across
the active repos — whenever `budget <= 0`. Then `HALT: dispatch-tasks gate-closed` and Step 5's
end line.

→ verify: `DISPATCH GATE:` is line one of the run's stdout.

### Step 3 — Plan

Run id: `$ROUTINE_RUN_ID`, or `dispatch-$(date +%Y%m%d)-$(date +%s)` when unset (interactive).

Order by shape band, then round-robin across **eligible** repos in priority order, taking each
repo's oldest remaining issue and decrementing its `slots_r` until `budget` is spent or no repo is
eligible. Bands and round-robin: `references/queue-building.md`. Print:

```
DISPATCH PLAN: run=<id> <m> issue(s) <owner/repo>#<N>,<owner/repo>#<N>
```

or `DISPATCH PLAN: run=<id> empty` when `m` is zero. Follow it with the in-progress, blocked,
deferred, skipped and at-limit lists as prose — log context, not output-contract lines.

An empty plan halts: `HALT: dispatch-tasks empty-queue`, or `all-blocked` when every approved issue
was dropped rather than there being none. Then Step 5's end line.

**Shadow routing, log only.** For each planned issue, run:

```bash
${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/jev-route <owner/repo> <N> --run <id>
```

Keep each `JEV-ROUTE:` line in the log. It never changes the plan, the order, or the worker's model,
and a `skipped` or `error` result changes nothing either: the line is evidence for a later decision.

→ verify: the plan names at most `budget` issues and none from a repo listed `at_limit`, and there
is one `JEV-ROUTE:` line per planned issue.

### Step 4 — Dispatch, one isolated worker per issue

For each planned issue, in order:

```
Skill(name="work-on-task", args="<N> --repo <owner/repo>")
Skill(name="work-on-task", args="<N> --repo <owner/repo> --dry-run")   # under a dry run
```

**A dry run still forks**, on the worker's own `model:` and `effort:` —
`${CLAUDE_SKILL_DIR}/references/worker-isolation.md` says why, and what read-only means here.

Print one `DISPATCH:` line per worker, its fields from the line the fork returned:

```
DISPATCH: run=<id> repo=<owner/repo> issue=<N> outcome=<pr-opened|dry-run|halted|refused> gate=<g> pr=<url|->
```

- fork returned `WORK:` — copy its `outcome`, `gate` and PR URL unchanged; never re-derive them.
- fork returned `PLANNED:` — `outcome=dry-run gate=- pr=-`.
- fork returned neither — `outcome=halted gate=- pr=-`; a missing line is never an assumed success.

One failure never aborts the run; **three consecutive** `halted`/`refused` outcomes sharing a
`gate=` value or halt reason do — a `dry-run` is a rehearsal that worked — print `HALT:
dispatch-tasks systemic-failure` and stop dispatching (BASELINE Principle 4).

→ verify: one `DISPATCH:` line per planned issue, or a halt line accounting for the shortfall.

### Step 5 — Digest, then the end line

Send Telegram only when at least one task changed state — a `pr-opened`, or a `refused`/`halted`
that left a `blocked:` label. A run whose workers changed nothing is silent (BASELINE Principle 5).

```bash
cat > /tmp/dispatch-digest.txt << 'EOF'
<digest text>
EOF
```

```bash
${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/telegram-send /tmp/dispatch-digest.txt
```

Literal path, one unchained command, no `rm`; the constraints live in `notify` only.

Close every run, halted or not, with:

```
DISPATCH END: run=<id> dispatched=<d> halted=<h> refused=<r>
```

A worker that planned is `dry-run`; one that refused or halted keeps that outcome, and `<d>` counts
the rehearsed.

→ verify: `DISPATCH END:` is the last line of stdout, and telegram-send ran at most once.

## Output contract

```
DISPATCH GATE: open_agent_prs=<n> cap=<N> per_repo=<P> run_max=<R> budget=<b> blocked=<k> unmet=<repo,repo|-> at_limit=<repo,repo|-> eligible=<repo,repo|->
DISPATCH PLAN: run=<id> <m> issue(s) <owner/repo>#<N>,…
DISPATCH PLAN: run=<id> empty
DISPATCH: run=<id> repo=<owner/repo> issue=<N> outcome=<pr-opened|dry-run|halted|refused> gate=<g> pr=<url|->
HALT: dispatch-tasks <reason>
DISPATCH END: run=<id> dispatched=<d> halted=<h> refused=<r>
```

Emitted in that order, with `HALT:` immediately before the end line. A dry run emits the same
lines.

## Hard rules

- Never hardcode a cap here or in a routine prompt — `repos.conf` holds it, others name it.
- Never `gh pr ready`, `gh pr merge` or force-push — BASELINE, *Merging and Marking PRs Ready*.
- Anything sensitive, irreversible or externally visible goes through `/request-approval`, which
  stops the run.
- A denied command is a stop signal, not a workaround puzzle — BASELINE, *Respect the Denial*.

## Additional resources

- `${CLAUDE_SKILL_DIR}/references/queue-building.md` — the Step 1 drop tests, the Step 3 bands and
  round-robin, and why one repo per Bash call; read it when Step 1 or Step 2 surprises you.
- `${CLAUDE_SKILL_DIR}/references/worker-isolation.md` — what `context: fork` was measured to
  isolate, why a dry run still forks, and the two ways the hand-off has failed; read it before
  changing how Step 4 invokes a worker.
- `${CLAUDE_SKILL_DIR}/../../docs/depends-on-convention.md` — the `DEPENDS ON`
  grammar; read at Step 1.
