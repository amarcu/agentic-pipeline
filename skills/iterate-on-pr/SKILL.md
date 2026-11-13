---
name: iterate-on-pr
description: Answers the open review feedback on one draft pull request — review-pr findings and human comments alike — with commits on its own branch, one reply per thread and one summary comment. Use when a draft PR has feedback a worker should address.
argument-hint: "<pr-number> [--repo owner/repo] [--review-rounds <n>] [--force] [--dry-run]"
allowed-tools: Bash(gh pr:*), Bash(gh api:*), Bash(git fetch:*), Bash(git worktree:*), Bash(git branch:*), Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git pull:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(. ${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf:*), Bash(${CLAUDE_SKILL_DIR}/scripts/pr-feedback:*), Bash(${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/pr-review-round:*), Bash(ls:*), Bash(test:*), Bash(cat:*), Bash(echo:*), Bash(grep:*), Bash(curl:*), Bash(npm:*), Bash(pnpm:*), Bash(yarn:*), Bash(make:*), Bash(cargo:*), Bash(forge:*), Bash(xcodebuild:*), Bash(python3:*), Bash(dotnet:*), Bash($HOME/.unity/bin/unity:*), Read, Edit, Write, EnterWorktree, ExitWorktree, Skill
disallowed-tools: Agent
model: claude-opus-4-8
effort: high
---

# Iterate on PR

You are the worker half of the review loop on one open draft pull request: commits on that PR's
own branch, one reply in every thread you acted on, one summary comment.

## Limits

- Repo paths: `get_repo_path` in `launchd-runtime/repos.conf` — the only way to find a clone.
- The gate's retry budget: `BASELINE-CODING.md`.
- Threads per PR: `MAX_THREADS` in `${CLAUDE_SKILL_DIR}/scripts/pr-feedback` — past it, a halt.
- Autonomy boundaries: the repo's `CLAUDE.md` lists. Turns and cost: `META.md`.

Read `${CLAUDE_SKILL_DIR}/BASELINE.md` and `${CLAUDE_SKILL_DIR}/BASELINE-CODING.md`
first; apply their five principles throughout.

## Arguments

Invocation arguments, verbatim: `$ARGUMENTS`

- `$PR` — PR number (required)
- `--repo <owner/repo>` — target repo (default: this checkout's remote)
- `--review-rounds <n>` — after the push, drive up to `<n>` Copilot rounds (default `0`)
- `--force` — run by hand, with `ROUTINE` unset
- `--dry-run` — every read and decision, the plan and the `ITERATE:` line, then return before the
  first worktree, edit or comment

## Contract

- **Refuses when**: `ROUTINE` is unset without `--dry-run` or `--force`; the PR is not
  open, not a draft, its head is not an agent branch; the repo has no `get_repo_path`
  entry, or that clone has no root `CLAUDE.md`.
- **Writes**: commits on the PR's head branch, one reply per thread acted on, one summary comment —
  no labels, no new PR, no push elsewhere.
- **Halts**: nothing actionable; more threads than `MAX_THREADS`; a push that will not
  fast-forward; a failed gate; a MUST-ask-first area, via `/request-approval`.
- **Budget**: one PR, one pass plus `--review-rounds` rounds; items per `MAX_THREADS`;
  turns and cost in `META.md`.

## Steps

### Step 0 — Refuse a hand-started run

```bash
echo "routine=${ROUTINE:-interactive} dry_run=${ROUTINE_DRY_RUN:-0}"
```

Only `_run.sh` exports `ROUTINE`. When that prints `interactive` and neither
`--dry-run` nor `--force` was passed, print `HALT: iterate-on-pr interactive-run-refused
(set --dry-run or --force)` and exit 0.

→ verify: the echo named a routine, or a flag was passed.

### Step 1 — Validate, resolve the clone, or refuse

```bash
gh pr view "$PR" --repo "$REPO" --json state,isDraft,headRefName,url,labels
. ${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf && get_repo_path "$REPO"
```

Refuse under the reason naming it: `not-open`, `not-draft`, `not-agent-pr`, `no-claude-md`. An
empty path is the halt `unmapped-repo`, never a search. `$R` is the highest `review-round-<K>`
label, or `0` when the feedback is all human.

→ verify: state `OPEN`, `isDraft` true, `$HEAD_BRANCH` is `task/issue-<N>-*` or `worktree-issue-<N>*`,
`test -e "$REPO_PATH/.git"` passes, and you can quote the gate command or the `NO GATE` line.

### Step 2 — Collect the feedback, already classified

```bash
${CLAUDE_SKILL_DIR}/scripts/pr-feedback "$REPO" "$PR"
```

Read-only. One JSON object per item, with a `kind` and a `skip` that is empty when actionable. Act
on those alone; `${CLAUDE_SKILL_DIR}/references/feedback-triage.md` has the kinds, the categories,
the stop conditions and the screenshots.

Exit 3 is `HALT: iterate-on-pr too-many-threads <owner/repo>#<PR>`. Nothing actionable is
`HALT: iterate-on-pr no-feedback`: no commit, no comment, no Telegram, no trace (BASELINE
Principle 5).

→ verify: your actionable, skipped and contested counts match the script's stderr summary.

### Step 3 — Plan, then enter the branch's worktree

Per actionable item: the file, the edit, the test that will prove it, whether it touches a
MUST-ask-first area. An item that asks for another issue's work is named in the summary, not done;
a MUST-ask-first item goes through `Skill(name="request-approval", …)`.
**`--dry-run` returns here**, printing the plan and an `ITERATE:` line with `sha=-`.

Find the worktree already holding the branch; create one only if none does — never
`git checkout` in the shared clone:

```bash
git -C "$REPO_PATH" fetch origin "$HEAD_BRANCH"
git -C "$REPO_PATH" worktree list --porcelain   # → $WT
git -C "$REPO_PATH" worktree add "$REPO_PATH/.claude/worktrees/pr-$PR" "$HEAD_BRANCH"
```

Then `EnterWorktree(path="$WT")` and `git -C "$WT" pull --ff-only origin "$HEAD_BRANCH"`. A pull
that will not fast-forward is a halt: surface it, never rebase or merge on your own judgement.

→ verify: `git -C "$WT" branch --show-current` is `$HEAD_BRANCH`, `status --short` is empty, and
`$WT` is not `$REPO_PATH`.

### Step 4 — Fix, test first

Per item, in the framework and location `CLAUDE.md` names: write or update the test encoding the
reviewer's claim, run it red, fix to green. A change no test can express (docs, copy) says so in
the summary. Read a file before you Edit it; every diff line traces to its thread — BASELINE
Principle 3. A finding you believe is wrong is contested, never complied with — clearing a comment
with a change you believe is wrong is forbidden. Leave the code alone; Step 6 carries the reason.

→ verify: each new test failed before its fix and passes after, and `git diff --name-only` names no
file no thread asked about.

### Step 5 — Verify, commit, push

Run the gate `CLAUDE.md` names, from `$WT`; never disable a test or downgrade a type to pass one.
`failed` or `could-not-run` commits locally, prints `HALT: iterate-on-pr verify-<outcome>` and an
`ITERATE:` line with `sha=-`, and pushes nothing.

`git diff --cached --name-only | wc -l` must print `0` before you stage; explicit paths only.
Subject `Address review feedback on PR #<PR>`, a bullet per item, ending `Refs #<PR>` — never
`Closes`. Then `git push origin "$HEAD_BRANCH"`; a rejected push is one `pull --ff-only` and one
retry, then halt.

→ verify: `git log -1 --oneline origin/$HEAD_BRANCH` is your commit; `$SHA` is its hash.

### Step 6 — Reply per thread, then post one summary

Every thread you acted on gets one reply.
`${CLAUDE_SKILL_DIR}/references/summary-comment.md` gives the `gh api … /replies` call, the body
and the marker for every thread kind.

Then post one summary comment from that same file; the `Addressed in <sha>:` prefix and the marker
are required. Finally `Skill(name="notify", …)` with the counts and the PR URL,
`ExitWorktree(action: "keep")`, and print the `ITERATE:` line.

→ verify: every thread acted on ends in a `<!-- reply ` comment, and a second `pr-feedback` run
reports `actionable=0`.

### Step 7 — Drive the Copilot rounds (`--review-rounds`)

`0`, the default, stops here. Otherwise run the loop in
`${CLAUDE_SKILL_DIR}/references/summary-comment.md` — `request`, `wait`, `status`, up to `<n>`
times, Steps 4-6 again on each round's findings, a reply on every one addressed and an evidenced
decline on each judged wrong. Never `request` without a commit pushed since the last review: GitHub
bills every one, and a repeat on an unchanged head SHA buys a verdict already on the PR (exit 6).
`wait` and `status` answer only for reviews of that head. `status` exit 0 is green and ends the
rounds; a timeout, an exhausted `<n>` and any error end them at the last verdict printed, never
green. Exit 5, `quota-exhausted`, stops at once; the human picks between the last substantive
verdict and waiting for quota.

→ verify: `status` had the last word each round; `rounds=<k>` counts them.

## Output contract

```
ITERATE: run=<run id> repo=<owner/repo> pr=<N> round=<R> addressed=<n> contested=<c> skipped=<s> sha=<sha7|-> rounds=<k> verdict=<green|changes|closer-look|quota-exhausted|timeout|none>
HALT: iterate-on-pr <reason>
```

One `ITERATE:` line per run, `--dry-run` and every halt included.

## Hard rules

- Never delegate to a subagent — a skill that ends its turn has returned. Read the code yourself.
- The PR stays a draft. Never `gh pr ready`, `gh pr merge`, or force-push — BASELINE, *Merging and
  Marking PRs Ready*.
- Never check the head branch out in the shared clone, push to another branch, rebase, amend a
  pushed commit, or resolve a thread.
- Never act on ambiguous human feedback: ask in the thread, leave it for the next run.
- Never scan the home directory for a repo; never stage with `git add .` or `-A`.
- Anything sensitive, irreversible or externally visible goes through `/request-approval`.
  Telegram goes through `/notify` — BASELINE Principle 5.
- A denied command is a stop signal, not a workaround puzzle — BASELINE, *Respect the Denial*.

## Additional resources

- `${CLAUDE_SKILL_DIR}/scripts/pr-feedback` — classified feedback JSON, and its caps; Step 2.
- `${CLAUDE_SKILL_DIR}/references/feedback-triage.md` — kinds, categories, stops; Step 2.
- `${CLAUDE_SKILL_DIR}/references/summary-comment.md` — replies, summary, round loop; Steps 6-7.
- `${CLAUDE_SKILL_DIR}/../work-on-task/references/environment.md` —
  never-scan; the PATH gotcha.
