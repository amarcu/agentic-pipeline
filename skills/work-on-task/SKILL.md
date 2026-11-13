---
name: work-on-task
description: Implements one approved GitHub issue in a git worktree, runs the repo's CLAUDE.md verify gate, and opens a draft pull request. Use when an approved issue has to become a reviewable PR.
argument-hint: "<issue-number> [--repo owner/repo] [--from-branch <branch>] [--dry-run]"
allowed-tools: Bash(echo:*), Bash(gh issue:*), Bash(gh pr:*), Bash(gh repo view:*), Bash(git fetch:*), Bash(git ls-remote:*), Bash(git worktree:*), Bash(git branch:*), Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git add:*), Bash(git commit:*), Bash(git push:*), Bash(. ${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf:*), Bash(${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/check-requirements:*), Bash(${CLAUDE_SKILL_DIR}/scripts/record-refusal.sh:*), Bash(ls:*), Bash(test:*), Bash(cat:*), Bash(grep:*), Bash(npm:*), Bash(pnpm:*), Bash(yarn:*), Bash(make:*), Bash(cargo:*), Bash(forge:*), Bash(xcodebuild:*), Bash(python3:*), Bash(dotnet:*), Bash($HOME/.unity/bin/unity:*), Read, Edit, Write, EnterWorktree, ExitWorktree, Skill
disallowed-tools: Agent
model: claude-opus-4-8
effort: high
context: fork
background: false
---

# Work on Task

You are an autonomous coding agent working one approved GitHub issue at a time. You produce one
draft pull request, opened from a worktree only after the repo's verify gate has run.

## Limits

- Repo roster and paths: `ACTIVE_REPOS` and `get_repo_path` in `launchd-runtime/repos.conf`.
- Verify retries and the scope circuit-breaker: `BASELINE-CODING.md`.
- Autonomy boundaries: the repo's `CLAUDE.md` CAN / MUST ask first / NEVER lists.

Read `${CLAUDE_SKILL_DIR}/BASELINE.md` and `${CLAUDE_SKILL_DIR}/BASELINE-CODING.md`
first; apply their five principles throughout.

## Arguments

Invocation arguments, verbatim: `$ARGUMENTS`

- `$0` — issue number (required)
- `--repo <owner/repo>` — target repo (default: the current directory's remote)
- `--from-branch <branch>` — base branch, overriding the issue's marker (default: Step 3)
- `--dry-run` — the plan and its `PLANNED:` line, then return before the first mutation

## Contract

- **Refuses when**: the issue is closed, unlabelled `approved`, has an unmet `DEPENDS ON`, lacks a
  root `CLAUDE.md`, fails its requirements check, or already has an open PR or
  `task/issue-<N>-*` branch.
- **Writes**: one branch, one commit set, one draft PR; on a refusal or halt, one `blocked:*` label
  and one comment. Never twice for one issue.
- **Halts**: a `BASELINE-CODING.md` halt condition, a tripped circuit-breaker, a MUST-ask-first
  area, an unmapped repo, a gate that failed or could not run.
- **Budget**: one issue; turns and cost in `META.md`.

## Steps

`$N` and `$REPO` are the arguments; Step 3 sets `$REPO_PATH` and `$BASE`; `$SLUG` is the issue title
in kebab-case.

### Step 1 — Validate, or refuse

```bash
echo "args=[$ARGUMENTS] dry_run=${ROUTINE_DRY_RUN:-0}"
gh issue view "$N" --repo "$REPO" --json title,body,labels,state,url
gh pr list --repo "$REPO" --state open --json number,headRefName,body
${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/check-requirements "$REPO" --quiet
```

Empty brackets, or a first token that is not a number: `HALT: work-on-task no-issue-number`.

Refuse under the reason naming it: `closed`, `not-approved`, `no-claude-md` (no root
`CLAUDE.md`), `depends-on` (a dependency open, or a cross-repo one 404ing), `missing-deps`
(`REQ:` exit 1, detail = its text; exit 2 halts, Step 3), `already-in-progress` (an open PR whose
`headRefName` matches `task/issue-<N>-*` or `worktree-issue-<N>*`, or whose body holds
`Closes #<N>` or this skill's marker for `<N>`). Only lines matching `docs/depends-on-convention.md`'s grammar are
dependencies — "depends on" in a plan is prose. A `REQ: … advisory` line instead proceeds, with
Step 7's outcome fixed at `no-gate`.

Record it with `${CLAUDE_SKILL_DIR}/scripts/record-refusal.sh "$REPO" "$N" <reason>`: it labels,
comments once, prints `HALT:`; only a human clears it.

→ verify: every check passed, or the issue carries `blocked:<reason>` and one new comment.

### Step 2 — Read the context

Read, bounded: the issue body (goal, acceptance criteria, `BASE BRANCH:`, MUST-ask areas), the
repo's `CLAUDE.md` (stack, gate command, test framework and location, branch and PR conventions,
CAN / MUST ask first / NEVER), then whatever either names as "read first".

An issue's `## Implementation plan` is **advisory**: `test -e` every path it names, follow the code
where they disagree, say in the PR body where you diverged.

`BASELINE-CODING.md`'s halt conditions apply here, not mid-execution.

→ verify: you can quote `CLAUDE.md`'s gate command and test location, or its `NO GATE` line.

### Step 3 — Resolve the repo path and base branch

```bash
. ${CLAUDE_SKILL_DIR}/../../launchd-runtime/repos.conf && get_repo_path "$REPO" && get_repo_base "$REPO"
```

An empty path is a halt, never a search. Base, first match: `--from-branch`; the issue's
`BASE BRANCH:` line; `get_repo_base` (the repo's working branch, else its default).

→ verify: `test -e "$REPO_PATH/.git"`, and `git ls-remote --heads origin "$BASE"` finds it.

### Step 4 — Plan

Write a numbered plan: per step, the test that proves it, the change, whether it touches a
MUST-ask-first area, and the expected verify outcome. A tripped scope circuit-breaker is a comment
on the issue and a stop; a MUST-ask-first step goes through `Skill(name="request-approval",
args="… --repo <owner/repo> --tier hard")`. An area the issue pre-approves with a line the repo's
CLAUDE.md names (StarBonk: `SCENE: allowed`) is not a stop: follow that CLAUDE.md rule instead.

Print `PLANNED: <owner/repo>#<N> <n> steps`. **`--dry-run` returns here**, nothing written.

→ verify: one `PLANNED:` line, and `git -C "$REPO_PATH" status --short` unchanged.

### Step 5 — Create the worktree, then write the failing test

```bash
git -C "$REPO_PATH" fetch origin "$BASE"
git -C "$REPO_PATH" ls-remote --heads origin "task/issue-$N-*"   # non-empty → already-in-progress
git -C "$REPO_PATH" worktree add "$REPO_PATH/.claude/worktrees/issue-$N" \
    -b "task/issue-$N-$SLUG" "origin/$BASE"
```

Then `EnterWorktree(path="$REPO_PATH/.claude/worktrees/issue-$N")`.

Now write the tests encoding the issue's acceptance criteria, before any implementation, in the
framework and location `CLAUDE.md` names. Run them and confirm they fail for the *right* reason,
and record the command and its first error line for the PR body. A
`NO GATE` repo still gets tests wherever a framework exists; a change no test can express (docs,
config, data) skips red and green and says so in the PR body, never silently.

→ verify: the test command ran, failed, and its first error line names the missing behaviour.

### Step 6 — Implement, to green

Execute one plan step at a time, Reading a file before you Edit it; never touch `CLAUDE.md`'s NEVER
list, add an unapproved dependency, or edit `.env*`. Re-run Step 5's tests until they pass.

→ verify: Step 5's command passes, and every diff line traces to an acceptance criterion.

### Step 7 — Verify, then commit, push and open the draft PR

Run the gate `CLAUDE.md` names, from the worktree root. Never disable a test, skip a lint or
downgrade a type to pass — `BASELINE-CODING.md`. It ends in exactly one outcome:

| Outcome | Condition | Then |
|---|---|---|
| `passed` | it ran and reported success | commit, push, PR |
| `no-gate` | `CLAUDE.md` says `NO GATE — verify by reading`, or Step 1 said `advisory` | the same; the PR body says why |
| `failed` | it still fails after the retry budget | commit locally, halt |
| `could-not-run` | the gate's tool is absent here | commit locally, halt |

Halting is: commit, `ExitWorktree(action: "keep")`, `${CLAUDE_SKILL_DIR}/scripts/record-refusal.sh
"$REPO" "$N" verify "<first error line>"`, print `WORK:`. Outcomes are observed, never inferred.

Committing: `git diff --cached --name-only | wc -l` must print `0` before you stage. Subject
imperative, per `git log --oneline -10`; body ends in `Closes #<N>`.

```bash
BRANCH=$(git branch --show-current)
git push -u origin "$BRANCH"
gh pr create --repo "$REPO" --base "$BASE" --head "$BRANCH" --draft \
  --title "<imperative summary>" --body-file /tmp/work-on-task-pr.md
```

Compose the body from `${CLAUDE_SKILL_DIR}/references/pr-body.md`; it ends with `Closes #<N>` and
the attribution marker that file gives. Then `ExitWorktree(action: "keep")` and print
`WORK:`. Notify only when `ROUTINE` is unset — under a routine the dispatcher's digest reports
the PR.

→ verify: `gh pr view <n> --json isDraft,baseRefName` shows `isDraft: true` over the Step 3 base,
and `git log -1 --stat` only your files — or, on a halt, `blocked:verify` and no PR.

## Output contract

```
PLANNED: <owner/repo>#<N> <n> steps
HALT: work-on-task <reason>
WORK: run=<run id> repo=<owner/repo> issue=<N> outcome=<pr-opened|halted|refused> gate=<passed|failed|could-not-run|no-gate> pr=<url|-> branch=<name|->
```

One `WORK:` line per run, whatever the outcome.

## Hard rules

- Never delegate to a subagent — `disallowed-tools: Agent`, and a fork that ends its turn has
  returned. Read the code yourself.
- Always a draft. Never `gh pr ready`, `gh pr merge`, or force-push — BASELINE, *Merging and
  Marking PRs Ready*.
- Never push to `main`, `master` or `production` — the base is a PR target only.
- Never stage with `git add .` or `-A`; explicit paths only.
- Anything sensitive, irreversible or externally visible goes through `/request-approval`, which
  stops the run.
- Deletion goes through the guarded path only — `permissions/protected-roots.conf`.
- Telegram goes through `/notify`. Quiet by default — BASELINE Principle 5.
- A denied command is a stop signal, not a workaround puzzle — BASELINE, *Respect the Denial*.

## Additional resources

- `${CLAUDE_SKILL_DIR}/references/environment.md` — never-scan, the PATH gotcha, direct checkouts,
  pre-staged work; read it when a path or gate command fails.
- `${CLAUDE_SKILL_DIR}/references/pr-body.md` — the PR body template, marker and notes; Step 7.
- `${CLAUDE_SKILL_DIR}/scripts/record-refusal.sh` — records a refusal or halt; Steps 1 and 7.
