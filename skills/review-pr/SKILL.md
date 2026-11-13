---
name: review-pr
description: Reviews one open pull request against the originating issue's acceptance criteria and the repo's real verify gate, posts findings as inline review threads, and records a machine-readable verdict. Use when an open agent-authored draft PR needs an independent review round before a human or a gate looks at it.
argument-hint: "<pr-number> --repo <owner/repo> [--force] [--dry-run]"
allowed-tools: Bash(gh pr:*), Bash(gh api:*), Bash(gh label:*), Bash(${CLAUDE_SKILL_DIR}/scripts/post-review:*), Bash(${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/pr-review-bundle:*), Bash(git:*), Bash(ls:*), Bash(cat:*), Bash(echo:*), Bash(grep:*), Bash(test:*), Bash(mkdir:*), Bash(cp:*), Bash(npm:*), Bash(pnpm:*), Bash(yarn:*), Bash(make:*), Bash(cargo:*), Bash(forge:*), Bash(xcodebuild:*), Bash(python3:*), Bash(dotnet:*), Bash($HOME/.unity/bin/unity:*), Read, Write
disallowed-tools: Agent
model: claude-opus-4-8
effort: high
---

# Review PR

You are the independent reviewer of one open pull request, working from a bundle that deliberately
withholds the author's framing. You produce one review of evidenced findings, posted as inline
threads, and one verdict recorded where a later gate and a human can both read it.

## Limits

- Rounds per PR: `REVIEW_ROUND_MAX` in `launchd-runtime/repos.conf`.
- New findings per round: `REVIEW_NEW_FINDINGS_BY_ROUND`, indexed by round, from the same file.
- Findings across the PR's life: `REVIEW_FINDINGS_MAX`, same file.
- Verify-gate rules and the retry budget: `BASELINE-CODING.md` — the standard you review against.

Read `${CLAUDE_SKILL_DIR}/BASELINE.md` and `${CLAUDE_SKILL_DIR}/BASELINE-CODING.md`
first; apply their five principles throughout.

## Arguments

Invocation arguments, verbatim: `$ARGUMENTS`

- `$0` — PR number (required)
- `--repo <owner/repo>` — target repo (required)
- `--force` — run by hand, with `ROUTINE` unset
- `--dry-run` — build the bundle, run the gate, print the findings, the verdict JSON and the
  `REVIEW:` line, then return before the first label, comment or file

## Contract

- **Refuses when**: `ROUTINE` is unset without `--dry-run` or `--force` (Step 0); the PR is not
  `OPEN`; its head is not an agent branch; the round would exceed
  `REVIEW_ROUND_MAX`; or `pr-review-bundle` exits 4 (the diff touches the pipeline).
- **Writes**: one review with inline threads, one `review-round-<K>` label (or `review-escalated`),
  `<bundle>/verdict.json` and its copy under `$HOME/.agentic-skills/routines/metrics/`. Nothing else.
- **Halts**: a review already exists for this head SHA; the finding ceiling is reached; the bundle
  cannot be built.
- **Budget**: one PR, one round, one review; findings per the caps above.

## Steps

### Step 0 — Refuse a hand-started run

```bash
echo "routine=${ROUTINE:-interactive} dry_run=${ROUTINE_DRY_RUN:-0}"
```

Only `launchd-runtime/bin/_run.sh` exports `ROUTINE`. When that prints `interactive` and neither
`--dry-run` nor `--force` was passed, print `HALT: review-pr interactive-run-refused
(set --dry-run or --force)` and exit 0 — an interactive session must not fire scheduled work by
accident.

→ verify: the echo named a routine, or a flag was passed.

### Step 1 — Refuse, or find the round

```bash
gh pr view "$PR" --repo "$REPO" --json state,headRefName,headRefOid,labels
gh api "repos/$REPO/pulls/$PR/reviews" --jq '.[].body'
```

Refuse under the reason naming it: `not-open`, `not-agent-pr` (head not `task/issue-<N>-*` or
`worktree-issue-<N>*`), `round-cap`. The round is the
highest `review-round-<N>` label plus one, or 1 if there is none.

Idempotence is `(head SHA, round)`: if any prior review body carries `head=<headRefOid>` in its
first-line marker, this commit has already been reviewed — print
`HALT: review-pr already reviewed at <sha7> round <K>` and exit 0. Reviewing one commit twice in a
round posts duplicate threads.

→ verify: you can state the round number and the head SHA the marker check ran against.

### Step 2 — Build the isolated bundle

```bash
${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/pr-review-bundle "$REPO" "$PR"
```

Exit 4 is a refusal: the diff touches `launchd-runtime/`, a `*.plist`, `.github/` or a `SKILL.md`.
Never review the reviewer — apply `review-escalated` (Step 5's `gh label create --force` first),
print `HALT: review-pr pipeline-diff`, stop. Exits 5 (the PR closes no issue) and 6 (the issue has
no criteria section) are advisory: the bundle is complete, you review against the diff alone, and
the verdict's `reason` says which it was.

Read only what it wrote: `meta.json`, `diff.patch`, `files.json` (the hunk ranges inline comments
anchor to), `tree.txt`, `acceptance-criteria.md`, and the head-SHA tree in `<bundle>/src/`.

**Never fetch the author's framing**: no `gh pr view --json body`, no commit messages, no `git log`
on the head branch, no worker comment. From round 2 you MAY read your own prior review threads and
the worker's replies to them — and only those — to adjudicate each prior finding `fixed`,
`still-open` or `contested`. The PR description stays off-limits in every round.

→ verify: `<bundle>/acceptance-criteria.md` exists, and `meta.json`'s `bundle.src` is a path or
carries the `src_note` saying why not.

### Step 3 — Run the repo's verify gate, in the bundle's own tree

Read `<bundle>/src/CLAUDE.md`, take the gate command it declares, and run it **from
`<bundle>/src`** — that tree *is* the head SHA, so the gate needs no checkout, no branch switch and
no stash in the author's working copy. Record the command, its exit code and the last 20 lines
verbatim.

The four outcomes — `passed`, `failed`, `no-gate`, `could-not-run` — and what each does to the
verdict are in the protocol reference's *Gate outcomes*. Never record a gate as run when it did not.

→ verify: you can quote the command and its exit status, or the `CLAUDE.md` line that made it
`no-gate`.

### Step 4 — Find, adversarially, within budget

Apply the five checks in `${CLAUDE_SKILL_DIR}/references/review-protocol.md` and cite the item
number in each finding's claim. That file also carries the finding schema, the inline tag and the
verdict shape; it is written to be executable by a reviewer that is not this model.

Budget new findings by `REVIEW_NEW_FINDINGS_BY_ROUND[round]` and the PR's life by
`REVIEW_FINDINGS_MAX`; the reference's *Rounds and budgets* has the ranking, the dropped count and
what reaching the ceiling does. A pre-existing defect the diff merely sits near is an issue, not a
finding.

→ verify: every finding has evidence you produced yourself, and a checklist item number.

### Step 5 — Claim the round, then post one review

`--dry-run` prints the findings, the verdict JSON and the `REVIEW:` line and **returns here**,
having written nothing.

```bash
gh label create "review-round-$ROUND" --repo "$REPO" --force --color BFD4F2
gh pr edit "$PR" --repo "$REPO" --add-label "review-round-$ROUND"
${CLAUDE_SKILL_DIR}/scripts/post-review "$REPO" "$PR" "$BUNDLE"
```

Write the body to `$BUNDLE/review/summary.md` and the findings to `$BUNDLE/review/findings.json`
(`[{"path","line","body"}]`, or `[]`) first. Never post with `gh api`: the deny-net refuses file
bodies.

Label before posting (`--force` creates a missing label): if the run dies in between, the round
still advanced.

The summary's **first** line is the verdict marker and its **last** line is the attribution marker:

```html
<!-- review-pr repo=<owner/repo> pr=<N> round=<K> head=<sha> model=<model id> verdict=<pass|changes-needed|escalate> gate=<passed|failed|no-gate|could-not-run> -->
<!-- agentic-skills: skill=review-pr repo=<owner/repo> pr=<N> routine=${ROUTINE:-interactive} run=${ROUTINE_RUN_ID:-none} model=<model id> -->
```

Each inline comment body ends with `<!-- finding:<id> severity:<s> round:<K> -->`.

→ verify: `gh api "repos/$REPO/pulls/$PR/reviews" --jq '.[-1].body'` starts with `<!-- review-pr `
and carries this run's `head=`.

### Step 6 — Record the verdict, print the line, stop

Write `<bundle>/verdict.json` in the shape the protocol reference defines, then copy it where it has
a reader:

```bash
mkdir -p $HOME/.agentic-skills/routines/metrics
cp "$BUNDLE/verdict.json" \
   "$HOME/.agentic-skills/routines/metrics/review-${OWNER}-${NAME}-${PR}-r${ROUND}.json"
```

Then stop. You do not mark the PR ready: a later gate reads the marker, and until that gate exists
the human reads the summary.

→ verify: the metrics file exists and its `head_sha` matches the marker you posted.

## Output contract

```
REVIEW: run=${ROUTINE_RUN_ID:-interactive} repo=<owner/repo> pr=<N> round=<K> head=<sha7> verdict=<pass|changes-needed|escalate> gate=<passed|failed|no-gate|could-not-run> findings=<blockers>/<majors>/<minors>
HALT: review-pr <reason>
```

One `REVIEW:` line per run, `--dry-run` included.

## Hard rules

- Never delegate to a subagent: a forked skill that ends its turn has returned, and a return
  without the `REVIEW:` line counts as a halt. Read the code yourself.
- Never `gh pr ready`, never `gh pr merge`, never push — BASELINE, *Merging and Marking PRs Ready*.
  You review; a separate gate acts.
- Never review a PR that modifies the pipeline, and never fetch the author's framing to break a tie.
- Never raise a finding you cannot evidence with something the author did not write, and never
  record a gate as run when it did not run.
- Sends no Telegram: the `REVIEW:` line and the review itself are the record — BASELINE Principle 5.
- Anything sensitive, irreversible or externally visible goes through `/request-approval`, which
  stops the run.
- A denied command is a stop signal, not a workaround puzzle — BASELINE, *Respect the Denial*.

## Additional resources

- `${CLAUDE_SKILL_DIR}/references/review-protocol.md` — the model-agnostic review contract: finding
  schema, inline tag, adversarial checklist, cap names and verdict shape. Read it at Step 4; a
  second, non-Claude reviewer reads it instead of this file.
- `${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/pr-review-bundle` — builds
  the bundle and defines its exit codes; read it when an exit code is unclear.
