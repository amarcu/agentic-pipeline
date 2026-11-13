---
name: triage-repo
description: Classifies one GitHub repo's open issues and pull requests into fixed urgency buckets and prints a versioned, byte-stable block. Use when a repo's open work has to be summarised for a digest or a human without anyone re-deriving the classification by hand.
argument-hint: "<owner/repo> [--days-stale <N>]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/triage-repo.sh *)
model: claude-sonnet-5
effort: low
---

# Triage Repo

You are the classifier for one repository's open work. You produce exactly one `triage-repo/2`
block: every open issue and pull request in its bucket, with its labels and its age. You never
write to GitHub, never send a message, and never re-decide a bucket the script already decided.

## Limits

- Stale threshold: `get_stale_days` in `launchd-runtime/repos.conf` holds the per-workspace
  default; `--days-stale` overrides it for one run.
- Fetch ceiling: `ISSUE_LIMIT` and `PR_LIMIT` in `${CLAUDE_SKILL_DIR}/scripts/triage-repo.sh`.
  Only this script reads them, so they live beside it rather than in `repos.conf` (S5).

Read `${CLAUDE_SKILL_DIR}/BASELINE.md` first and apply its five
principles throughout.

## Arguments

- `$0` — `owner/repo` (required)
- `--days-stale <N>` — days without activity before an item counts as stale (default: `14`, the
  same default `get_stale_days` returns). The script also accepts the number as a bare second
  argument, which is how `morning-triage` passes it; give one spelling or the other, never both.

## Contract

- **Refuses when**: `$0` is not `owner/repo`, or `--days-stale` is not a whole number — the script
  prints a usage line and exits 2 without calling GitHub.
- **Writes**: none. Read-only against GitHub; the one file touched is
  `/tmp/triage-repo-gh-stderr.txt`, overwritten in place so a failed `gh` call can be quoted.
- **Halts**: never mid-flight. A missing or failing `gh` yields an `ERROR:` block and exit 0, so a
  caller part-way through a roster keeps going.
- **Budget**: one repo, two `gh` calls, `ISSUE_LIMIT` issues and `PR_LIMIT` pull requests.

## Steps

### Step 1 — Run the classifier

```bash
${CLAUDE_SKILL_DIR}/scripts/triage-repo.sh <owner/repo> --days-stale <N>
```

Substitute both literally. The script computes its own cutoff and calls `gh` twice with the
classification embedded as a `--jq` expression, so nothing here needs a date, a shell variable or
`jq` on `PATH`.

→ verify: stdout opens with `REPO: <owner/repo>` then `FORMAT: triage-repo/2`, and stderr carries
the single `triage-repo: … gh_calls=2` line.

### Step 2 — Relay the block unchanged

Print what the script printed. Do not re-read titles for urgency, do not merge buckets, do not drop
the `labels=` field: a caller that wants a different bucketing changes the script, so that every
consumer changes with it.

→ verify: the block you relayed is byte-identical to the script's stdout.

## Output contract

```
REPO: <owner/repo>
FORMAT: triage-repo/2
Scanned: <UTC timestamp>
Stale-days: <N>
Precedence-issues: blocking > needs-approval > proposed > informational > active > stale (first match wins)
Precedence-prs: draft-agent > ready > stale > draft (first match wins)

ISSUES (<total>): blocking=<n> needs-approval=<n> proposed=<n> informational=<n> active=<n> stale=<n>
  <bucket>:
    - #<n> <title> [age=<n>d updated=<n>d] <url> labels=[<a>,<b>]

PRS (<total>): draft-agent=<n> ready=<n> stale=<n> draft=<n>
  <bucket>:
    - #<n> <title> [branch=<name> age=<n>d updated=<n>d ci=<pass|fail|pending|none>] <url> labels=[<a>,<b>]
```

Every bucket is counted on its section line; only non-empty buckets list their items. On stderr,
once: `triage-repo: <owner/repo> issues=<n> prs=<n> gh_calls=<n>`. On failure, the first three
lines followed by `ERROR: <reason>` and nothing else, still exit 0.

**Buckets.** Issues: `blocking` is a `blocker`, `critical` or `security` label; `needs-approval` is
that label; `proposed` is `proposed` without `approved`; `informational` is `documentation`,
`question`, `discussion` or `enhancement`; `active` is anything touched inside the window, plus
anything carrying `proposed` or `approved`; `stale` is the rest. PRs: `draft-agent` is a draft on a
`task/issue-` or `worktree-issue-` branch, `ready` is any non-draft, `stale` is a draft untouched
for longer than the window, `draft` is every other draft.

A `proposed` or `approved` issue is never `stale` however old it is — it is waiting on the human,
not rotting, and the two read completely differently in a morning digest.

## Hard rules

- Read-only: never `gh issue create`, never `gh issue edit`, never a label. Escalation belongs to
  the caller, which has the human's context for it.
- Never let a title keyword ("broken", "failing", "urgent") change a bucket. Labels only — a
  keyword match is not evidence, and it must never reach an autonomous write.
- Sends no Telegram: the block is the output — BASELINE Principle 5, quiet by default.
- A denied command is a stop signal, not a workaround puzzle — BASELINE, *Respect the Denial*.

## Additional resources

- `${CLAUDE_SKILL_DIR}/scripts/triage-repo.sh` — the fetch and the classification, and the only
  place either is defined. Read it when a bucket looks wrong or a `gh` field needs adding.
- `${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf` — `get_stale_days`,
  the per-workspace threshold to pass as `--days-stale`. Read it when triaging a roster.
