---
name: daily-summary
description: Evening Telegram digest of the whole pipeline — what shipped, what waits on the human, and whether the queue is moving or deadlocked. Use when a scheduled end-of-day run has to report the day, including a day on which nothing moved because nothing could.
argument-hint: "[--days <N>] [--force] [--dry-run]"
allowed-tools: Bash(command -v gh:*), Bash(gh auth status:*), Bash(gh pr list:*), Bash(gh issue list:*), Bash(gh api:*), Bash(. ${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf:*), Bash(date:*), Bash(test:*), Bash(cat:*), Bash(echo:*), Bash(${CLAUDE_SKILL_DIR}/scripts/ledger-lines:*), Bash(/usr/bin/python3 ${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/telegram-send:*)
model: claude-sonnet-5
effort: medium
---

# Daily Summary

You are the evening reporter for the whole pipeline, not only for its output. You produce one
Telegram digest and one summary line saying what shipped, what waits on the human, and whether the
queue is moving. You never write a GitHub object, never invoke another skill, never send twice.

## Limits

- Repo roster: `ACTIVE_REPOS` from `launchd-runtime/repos.conf` — those repos and no others.
- Caps: `DISPATCH_TOTAL_MAX` (open agent PRs across the roster) and `DISPATCH_PER_REPO_MAX` (the
  same count inside one repo) from the same file. Read them at runtime; never restate them, never
  change them from here.
- Stale threshold: `get_stale_days` from the same file, called once per repo. It already differs by
  workspace, and `morning-triage` and `triage-repo` read the same function — read it, never restate
  either number.

Read `${CLAUDE_SKILL_DIR}/BASELINE.md` first and apply its
five principles throughout.

## Arguments

- `--days <N>` — the shipped window in days, ending today (default: `1`, today only). Step 1 turns
  it into the literal date the shipped queries use.
- `--force` — run by hand, with `ROUTINE` unset
- `--dry-run` — every read and decision, the digest printed to stdout and the summary line, then
  return before `telegram-send`.

## Contract

- **Refuses when**: `ROUTINE` is unset without `--dry-run` or `--force`; `gh` is missing or
  unauthenticated; `TELEGRAM_BOT_TOKEN` / `TELEGRAM_CHAT_ID` is unset; or `repos.conf` is
  unreadable — all checked first, so a run that could not deliver spends nothing.
- **Writes**: one Telegram message. No issue, PR, comment or label, ever.
- **Halts**: `quiet-day` when every bucket and pipeline count is zero — the one-line message still
  goes out, BASELINE Principle 5's named exception; `starved` in its place when a repo has nothing
  in flight and nothing waiting; `github-unreachable` when every repo fails.
- **Budget**: one survey pass over `ACTIVE_REPOS`, one comment fetch per draft PR, one send.

## Steps

### Step 0 — Preconditions, before any `gh` traffic

```bash
echo "routine=${ROUTINE:-interactive} dry_run=${ROUTINE_DRY_RUN:-0}"
test -n "${TELEGRAM_BOT_TOKEN:-}"
test -n "${TELEGRAM_CHAT_ID:-}"
test -r ${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf
command -v gh
gh auth status
```

Run them in that order and read each result; the free checks come first so a run that could not
deliver never reaches the network. The **first** failure ends the run: print its reason as
`HALT: daily-summary <reason>`, then Step 6's line, and issue no `gh pr list`. The reasons, in
check order — `interactive-run-refused (set --dry-run or --force)` when `ROUTINE` is unset and
neither flag was passed, `missing-telegram-env` (either variable), `missing-repos-conf`,
`missing-gh`, `gh-unauthenticated`.

→ verify: all six passed — or exactly one `HALT:` line was printed and no `gh` list call ran.

### Step 1 — Compute the date literals

```bash
date +%F
. ${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf
```

`<TODAY>`, then `get_stale_days <owner/repo>` for each repo in `ACTIVE_REPOS`. Each distinct answer
becomes one `date -v-<N>d +%F` call with the number written in literally, giving every repo its own
`<STALE_BEFORE>` — two calls today, since `ACTIVE_REPOS` spans two of the function's answers.
`<SINCE>` is `<TODAY>` at the default `--days 1`; for a larger `N` run `date -v-<N-1>d +%F`, again
with the number literal. Put every date into the later commands as a **literal string** —
`$(date …)` inside a `gh` command is denied headlessly, and a denial there costs the whole survey.

→ verify: no `gh` command in this run contains `$(`, and every repo has a `<STALE_BEFORE>`.

### Step 2 — Survey each repo, one Bash call per repo

One call per repo in `ACTIVE_REPOS`, never one loop over all of them, so a repo whose `gh` fails
costs that repo and not the survey:

```bash
gh pr list --repo <owner/repo> --state merged --search "merged:>=<SINCE>" --json number,title,author --limit 20
gh pr list --repo <owner/repo> --state open --json number,title,isDraft,reviewDecision,updatedAt,headRefName,body --limit 30
gh issue list --repo <owner/repo> --state open --json number,title,labels,updatedAt --limit 50
gh issue list --repo <owner/repo> --state closed --search "closed:>=<SINCE>" --json number,title --limit 20
```

A repo whose calls fail is `(error)`, contributes zero to every count and is not re-scanned. Every
repo failing is `HALT: daily-summary github-unreachable`, then Step 6.

From one repo's four responses:

- **shipped** — merged PRs and closed issues in the window, less bots and less issues a listed PR
  closes.
- **needs review** — open, not draft, `reviewDecision != APPROVED`; plus a draft PR whose newest
  human comment postdates its newest `Addressed in <sha>:` comment
  (`gh api repos/<owner/repo>/issues/<n>/comments` per draft PR — that prefix is `iterate-on-pr`'s
  contract with this skill, and such a PR is `/iterate-on-pr` work).
- **ready to merge** — open, not draft, `reviewDecision = APPROVED`.
- **in flight** — open PR whose `headRefName` starts with `task/issue-` or `worktree-issue-`, or
  whose body contains `Closes #<n>`.
- **waiting** — open issue labelled `approved` with no in-flight PR for it.
- **blocked** — open issue carrying any `blocked:*` label, grouped by the reason after the colon.
- **proposed** — open issue labelled `proposed` and not `approved`.
- **starved** — the repo has zero in flight and zero waiting. Tonight's dispatch has no work for it,
  so every night routine will halt on an empty queue, although each other count reads zero.
- **stale** — open issue or PR whose `updatedAt` predates that repo's own `<STALE_BEFORE>`.

→ verify: every active repo is represented in the counts or named `(error)`.

### Step 3 — Pipeline state

```bash
. ${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf
```

Sum **in flight** across repos and report it against `DISPATCH_TOTAL_MAX` as read from that file,
with **waiting** and **blocked** grouped by reason. Name any repo whose own in-flight count has
reached `DISPATCH_PER_REPO_MAX`: it is skipped by tonight's dispatch even when the roster total sits
under the ceiling, which is a stall the global figure alone cannot show.

Name every starved repo too, with its **proposed** count. Nothing waits and nothing is blocked
there, because nothing was approved, so no other count shows this stall. The fix is upstream of
dispatch: approve a proposed issue, or run `/plan-features --repo <owner/repo>`.

→ verify: the pipeline line appears in every digest, quiet or active, and every starved repo has
its own line.

### Step 4 — Spend, friction and review

```bash
${CLAUDE_SKILL_DIR}/scripts/ledger-lines <TODAY>
```

One command, which runs `spend-today`, `friction` and `review-line` and prints up to three lines:
`SPEND:`, `FRICTION:`, `REVIEW:`. A line that is absent means the digest omits it silently — never a
warning, never a zero.

→ verify: the command ran once; each line it printed appears in the digest exactly once.

### Step 5 — Compose the digest, then send it

`${CLAUDE_SKILL_DIR}/references/digest-format.md` holds the one template, the section order, the
caps and the attribution marker that closes every message. Read it here; nothing below restates it.

The quiet-day rule stays here because the halt turns on it: when shipped, needs-review,
ready-to-merge, in-flight, waiting and blocked are **all** zero, the bucket sections collapse to
`All quiet — nothing shipped, nothing waiting, nothing in flight.`, the pipeline, spend, friction,
review and marker lines still follow, the message still goes out, and the run prints `HALT: daily-summary quiet-day`.
A starved repo is never quiet: its line stays above the collapsed sections, and when any repo is
starved the halt is `HALT: daily-summary starved` instead of `quiet-day`.

Send it — literal path, two unchained commands, per `notify`:

```bash
cat > /tmp/daily-summary-digest.txt << 'EOF'
<the digest, exactly as it should appear>
EOF
```

```bash
/usr/bin/python3 ${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/telegram-send /tmp/daily-summary-digest.txt
```

**`--dry-run` prints the digest to stdout and returns here**, before the send.

→ verify: stdout reads `sent message_id=<id>` once — or `--dry-run` printed the digest and
`telegram-send` never ran.

### Step 6 — The summary line

Run id: `$ROUTINE_RUN_ID`, or `daily-summary-<TODAY>` when unset.

→ verify: `SUMMARY:` is the last line of stdout, on a halted run too.

## Output contract

```
SUMMARY: run=<id> shipped=<s> review=<r> in_flight=<n>/<cap> waiting=<w> blocked=<k> starved=<z> spend_usd=<x|->
HALT: daily-summary <reason>
```

`SUMMARY:` closes every run and a `HALT:` sits immediately before it. `review` counts needs-review
and ready-to-merge together; `spend_usd=-` when Step 4 printed nothing.

## Hard rules

- Never create or mutate an issue, PR, comment or label — this skill reads and sends, nothing else.
- Never invoke another agentic skill. A stalled pipeline is reported here and unstuck elsewhere.
- Never more than one Telegram per run, and never a retry on a perceived failure (`notify`, S8).
  The quiet-day message is Principle 5's named exception, not licence for a second send.
- Never restate either dispatch cap; source `repos.conf` and read them (S5).
- Never `gh pr ready`, `gh pr merge` or force-push — BASELINE, *Merging and Marking PRs Ready*.
- A denied command is a stop signal, not a workaround puzzle — BASELINE, *Respect the Denial*.

## Additional resources

- `${CLAUDE_SKILL_DIR}/references/digest-format.md` — the template, section order and caps. Read at
  Step 5, and before changing what a digest looks like.
- `${CLAUDE_SKILL_DIR}/scripts/ledger-lines` — Step 4's one command. It runs the three scripts
  below and prints their lines; a script that fails or prints nothing does not stop the next.
- `${CLAUDE_SKILL_DIR}/scripts/spend-today` — turns today's `runs.jsonl` and `sends.jsonl` rows into
  one `SPEND:` line, or nothing. Read before changing what the spend line claims.
- `${CLAUDE_SKILL_DIR}/scripts/friction` — one `FRICTION:` line for a block that stopped the same
  routine in two or more runs this week, or nothing.
- `${CLAUDE_SKILL_DIR}/scripts/review-line` — turns `review-rollup`'s week into one `REVIEW:` line,
  or nothing. Read before changing what the review line claims.
- `${CLAUDE_SKILL_DIR}/../notify/SKILL.md` — the stack's one send recipe
  and its constraints. Read before touching Step 5's send.
