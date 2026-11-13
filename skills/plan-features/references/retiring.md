# Retiring work the focus has dropped

Closing an issue stops `dispatch-tasks` from working it, and nothing else. `propose-tasks` reads
closed issues, not their comments, and it only honours a closure carrying the `retired` label. So a
retirement survives when three things are true: the issue is closed **and** labelled, its reason is a
line in *Not now* — the one list this skill may never cut from — and the Decisions log says why.

This runs inside **Step 4**, with the documents, not with Step 5's issues. Two reasons: a retirement
is a direction change, so it belongs in the `git diff` the human confirms; and `--docs-only` skips
Step 5, while a session that rewrites the focus without reconciling the backlog leaves exactly the
drift this step exists to close.

## 1. Read the list, do not assemble it

```bash
launchd-runtime/bin/focus-orphans <owner/repo> --json
```

Run it after FOCUS.md is written, so it judges against the focus the human just agreed. A non-zero
exit, or a non-empty `errors`, means it could not read something it needed: say so and retire nothing
this session. It sorts every open issue into three states, and its docstring defines them:

- **traces** — the focus still asks for it. Not shown, not offered.
- **orphan** — it quotes a focus line, or names one in its `focus:` comment, and that line is gone.
  These are the candidates, `approved` ones included: that is the set `unstick` never surfaces.
- **untraceable** — it carries no focus reference at all, so nothing can say whether the focus wants
  it. Counted in one line, never offered. A backlog written before the template is not evidence that
  its work is unwanted, and offering it hands the human the whole repo.

An orphan with `claimed_by` set is listed with its pull request number and **not offered**: the pull
request is the decision, and closing the issue under a running worker strands the branch.

At most `MAX_RETIRE` = 6 orphans are offered in one session, the issue cap's twin — a sitting that
answers more than six of these has stopped reading them. Say how many were left for next time.

## 2. Ask, one at a time

Each candidate is its own question: keep, or retire with a reason. Recommend an answer and say why;
the human answers. A yes covers that issue alone — never read it as covering the rest of the list.
This is the rule that governs `approved` in Step 6, for the same reason: what work exists is theirs.

An issue kept stays exactly as it is. Do not relabel it, re-scope it, or move it to *Not now*.

→ verify, once the answers are in and before Step 5: for every orphan the human kept,
`gh issue view <N> --repo "$REPO" --json state,labels` still reports `OPEN` and no `retired` label,
and `grep -n "#<N>" agent/FOCUS.md` finds it on no *Not now* line. A kept issue that moved is a
decision nobody made, and the next night's proposer would read it as one.

## 3. Write the retirement in three places

Per retired issue, in this order, so a failure leaves the record rather than a silent close:

1. **FOCUS.md — *Not now***: `- <title> (#<N>, retired <YYYY-MM-DD>) — <reason>`.
2. **FOCUS.md — Decisions log**, on the session's own dated entry: `retired #<N> — <reason>`.
3. **The issue**, closed and labelled:

```bash
gh label create retired --repo "$REPO" --color 6e7781 --force
gh issue close <N> --repo "$REPO" --reason "not planned" --comment "<the reason, one line>

<!-- agentic-skills: skill=plan-features repo=<owner/repo> issue=<N> routine=interactive run=none model=claude-fable-5-1 -->"
gh issue edit <N> --repo "$REPO" --add-label retired
```

The label is what `propose-tasks` queries; a closure without it is invisible to the next night's run.

Then print `RETIRED: <owner/repo>#<N> | <reason>`.

→ verify: `gh issue view <N> --json state,labels` shows CLOSED and `retired`, and the Not-now and
Decisions-log lines both name `#<N>`. The counts add up too: retired plus kept equals the orphans
offered, and every one of those was answered.

## What --dry-run does here

Nothing. It prints the orphan list and the three writes it would make for each retirement, and
performs none of them: no document edit, no label, no comment, no close.

## What this step is not

- Not a re-scoping pass. An issue still wanted but wrong in its details stays open; the conversation
  changes the focus line, not this step.
- Not a backlog cleanup. Age retires nothing: the test is whether the focus still asks for the work.
- Not a way to close somebody else's work. A hand-filed issue is untraceable, so this step never
  offers it at all — a human retires that one in an `unstick` sitting, where the same label is applied.
