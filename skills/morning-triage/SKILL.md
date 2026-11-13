---
name: morning-triage
description: Scans the active repo roster, classifies every open issue and pull request, escalates hard blockers that have stopped moving, and sends one Telegram digest — or nothing on a quiet day. Use when the daily multi-repo health pass runs, scheduled or by hand.
argument-hint: "[--all] [--repo <owner/repo>] [--force] [--dry-run]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/../triage-repo/scripts/triage-repo.sh *), Bash(gh issue list:*), Bash(gh issue create:*), Bash(gh label create:*), Bash(cat > /tmp/morning-triage-digest.txt:*), Bash(cat > /tmp/morning-triage-escalation.txt:*), Bash(/usr/bin/python3 ${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/telegram-send:*), Bash(/bin/date -u:*), Bash(echo:*), Read
model: claude-sonnet-5
effort: medium
---

# Morning Triage

You are the daily health pass across the tracked repositories. You produce one Telegram digest, one
tracking issue per hard blocker that has stopped moving, and one `TRIAGE:` line in the run log. You
never re-classify what the triage script already classified, never escalate on a title keyword, and
never send anything on a quiet day.

## Limits

- From `launchd-runtime/repos.conf`: the roster `ACTIVE_REPOS` (`--all` widens it to
  `REPOS_BY_PRIORITY`), the grouping and scan order `WORKSPACES`, and the per-repo threshold
  `get_stale_days`. Never restate a threshold here.
- Digest length: 2000 characters. Only this skill reads that number, so it lives here (S5);
  Telegram's own 4096 ceiling belongs to `notify`.
- Escalation preconditions: the four in Step 4, read nowhere else.

Read `${CLAUDE_SKILL_DIR}/BASELINE.md` first and apply its
five principles throughout.

## Arguments

- `--all` — scan every tracked repo (`REPOS_BY_PRIORITY`) instead of the active roster
- `--repo <owner/repo>` — scan only this repo, with no workspace grouping
- `--force` — run by hand, with `ROUTINE` unset
- `--dry-run` — do every read and decision, print the digest and the `TRIAGE:` line, return before
  the first label, issue or send

## Contract

- **Refuses when**: `ROUTINE` is unset and neither `--dry-run` nor `--force` was passed (Step 0);
  or `--repo` names a repo in no roster in `repos.conf` — the stale threshold comes from that
  file, so a repo it does not know cannot be triaged consistently.
- **Writes**: one Telegram digest; one `Escalation: <title>` issue per qualifying blocker, plus the
  `escalated` label in that repo. Nothing on the original item — no label, no comment.
- **Halts**: a quiet day prints `HALT: morning-triage all-clear` and sends nothing. A repo whose
  block is an `ERROR:` is named in the digest and the scan carries on.
- **Budget**: one pass over the roster, one Telegram message, one escalation issue per qualifying
  item. No retries.

## Steps

### Step 0 — Refuse a hand-started run

```bash
echo "routine=${ROUTINE:-interactive} run=${ROUTINE_RUN_ID:-none} dry_run=${ROUTINE_DRY_RUN:-0}"
```

Only `launchd-runtime/bin/_run.sh` exports `ROUTINE`. When that prints `interactive` and neither
`--dry-run` nor `--force` was passed, print `HALT: morning-triage interactive-run-refused
(set --dry-run or --force)` and exit 0 — an interactive session must not fire scheduled work by
accident.

→ verify: the echo named a routine, or a flag was passed.

### Step 1 — Establish the run

```bash
/bin/date -u '+%Y-%m-%d'
```

This date and Step 0's `routine=` / `run=` pair are the only shell variables in this skill. Every
command below substitutes their values **literally** — `VAR=$(...)` is denied headlessly, so a
variable referenced later expands to nothing and the write lands wrong. Then read
`${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf` for the roster,
`WORKSPACES` and each repo's `get_stale_days` value.

→ verify: you can state the run id, today's UTC date, and every repo to scan with its stale-days.

### Step 2 — Scan each repo

One Bash call per repo, in `WORKSPACES` order, repo and stale-days substituted literally:

```bash
${CLAUDE_SKILL_DIR}/../triage-repo/scripts/triage-repo.sh amarcu/StarBonk 14
```

The script owns fetching and classification. Do not re-derive a bucket, and do not invoke the
skill: running the script directly is what keeps the routine prompt's "no other skills" constraint
true.

→ verify: every repo returned a block whose second line is `FORMAT: triage-repo/2`; note how many
came back as `ERROR:`.

### Step 3 — Roll up

The `ISSUES (…)` and `PRS (…)` section lines are already totalled — take the counts from them. Keep
the item lines for `blocking`, `needs-approval`, every `ready` PR and the oldest `stale` item per
repo; everything else is a number.

→ verify: your totals equal the sum of the section-count lines, not a recount of item lines.

### Step 4 — Escalate blockers that have stopped moving

An autonomous write with no human in the loop, so all four must hold: the item is in the `blocking`
bucket (a title keyword never qualifies); its `labels=` carries neither `needs-approval` nor
`escalated`; its `updated=` is `2d` or more; and no escalation issue exists yet.

**`--dry-run` returns here**, having written nothing. Otherwise run the four commands in
`${CLAUDE_SKILL_DIR}/references/escalation.md` in order, once per qualifying item — label, dedup
search, body, create — substituting every value literally. Do not reconstruct them from memory:
that file is the recipe precisely because this branch runs on few mornings and has to be identical
on all of them.

→ verify: the new issue's first body line carries the original's URL, so a re-run finds it through
the `in:body` search and creates nothing.

### Step 5 — Compose the digest

Plain text — Telegram renders it literally. One block per workspace, in `WORKSPACES` order:

```
Morning Triage — Wed, 3 September 2026

2 blocking, 3 awaiting your approval, 1 escalated.

[ STARBONK ]
  BLOCK   amarcu/StarBonk#12 Loader crashes on boot (4d unmoved, escalated as #41)
  APPROVE amarcu/StarBonk#11 Rotate the deploy key
  REVIEW  amarcu/StarBonk PR #20 Bump the engine (CI failing)
  amarcu/StarBonk-backend: 2 proposed, 1 stale

[ GAMETWO ] all clear
```

- Only workspaces holding a scanned repo appear; one with nothing to report is the `all clear` line
  above. A repo with nothing open is `<repo>: clear`, one whose block was an `ERROR:` is
  `<repo>: scan failed — <reason>`. Under `--repo`, drop the headers entirely.
- Over the length limit, drop stale detail first, then proposed counts. A `BLOCK` or `APPROVE` line
  is never dropped.

→ verify: every repo with a non-zero `blocking` or `needs-approval` count has a line, and the
digest is inside the length limit.

### Step 6 — Send, or halt quietly

A quiet day is `blocking=0` and `needs-approval=0` on every block, with Step 4 having created
nothing. Proposed items alone are **not** a reason to send: they already sit in the human's
approval queue, and a nightly reminder of it is the noise BASELINE Principle 5 exists to stop.
Print `HALT: morning-triage all-clear`, send nothing, go to Step 7.

Otherwise — and **`--dry-run` prints the digest here and returns**:

```bash
cat > /tmp/morning-triage-digest.txt << 'EOF'
<the digest from Step 5>
EOF
```

```bash
/usr/bin/python3 ${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/telegram-send /tmp/morning-triage-digest.txt
```

The recipe and every constraint on it live in
`${CLAUDE_SKILL_DIR}/../notify/SKILL.md` and nowhere else.

→ verify: stdout reads `sent message_id=<id>`. A nonzero exit is a halt, never a retry.

### Step 7 — Print the run line

One line on stdout, in the Output contract's shape, with the counts from Step 3, the escalations
Step 4 actually created, and `errors`: how many repos came back as `ERROR:` in Step 2. This is the routine log's record of the run — Telegram is not (BASELINE
Principle 5).

→ verify: exactly one `TRIAGE:` line on stdout, `--dry-run` included.

## Output contract

```
TRIAGE: run=<id> repos=<n> blocking=<b> needs_approval=<a> proposed=<p> escalated=<e> errors=<k>
HALT: morning-triage <reason>
```

## Hard rules

- Never `gh pr ready`, never `gh pr merge`, never force-push — BASELINE, *Merging and Marking PRs
  Ready*.
- Never escalate on a title keyword, and never escalate an item labelled `needs-approval` — the
  human created that gate deliberately and owns it.
- Never open an approval gate from here. Anything sensitive, irreversible or externally visible
  goes through `/request-approval`, which stops the run.
- Telegram goes through the one recipe `notify` owns (S8). Quiet by default — BASELINE Principle 5.
- A denied command is a stop signal, not a workaround puzzle — BASELINE, *Respect the Denial*.

## Additional resources

- `${CLAUDE_SKILL_DIR}/references/escalation.md` — the four escalation commands and the reasoning
  behind each. Required reading at Step 4, before the first write.
- `${CLAUDE_SKILL_DIR}/../triage-repo/SKILL.md` — what each bucket means
  and the shape of the block Step 2 relays; its `scripts/triage-repo.sh` holds the fetch and the
  classification. Read them when a bucket in the digest looks wrong.
- `${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf` — rosters,
  workspaces and `get_stale_days`, read at Step 1.
- `notify/SKILL.md`, cited by path in Step 6 — why the send is shaped that way. Read it if the send
  fails.
