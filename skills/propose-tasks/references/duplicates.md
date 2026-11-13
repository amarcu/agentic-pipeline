# Dropping the duplicates

The issue history is the only memory this skill has. It runs nightly with no state, so a decision a
human made about a piece of work is visible here or nowhere.

Two queries, because the two things being avoided are different:

```bash
# still on the board: proposing it again duplicates live work
gh issue list --repo "<owner/repo>" --state open --limit 500 --json number,title,body

# retired: a human decided this work is not wanted
gh issue list --repo "<owner/repo>" --state closed --label retired --limit 500 \
  --json number,title,body
```

A candidate whose signal — the path and line, issue number or commit it named in Step 4 — appears in
one of those bodies is a duplicate (S7) and is dropped. Name the issue it matched in the run's own
text, so a reader can see which decision stopped it; never in a Telegram message, which BASELINE
Principle 5 reserves for work a human must act on.

## Why the label, and not any closed issue

Both halves of that were once narrower, and each gap let retired work come back (issue #62).

- **Whoever filed it counts.** The body no longer has to carry `skill=propose-tasks`. An issue
  `plan-features` cut, or one a human filed by hand, is as much a decision as one of this skill's own.
- **But a bare close is not a retirement.** Issues close for every reason: done, superseded,
  duplicated, filed in the wrong repo. Treating all of them as decisions would suppress real work on
  a path some old issue happened to mention. `retired` is applied deliberately — by `plan-features`
  Step 4's reconcile, or by a human in an `unstick` sitting — and it is the only closed state that
  speaks here.

An issue closed as completed is not consulted at all. If its work has regressed, the signal is in the
code again and proposing it again is right.

## The bound

`--limit 500` on both, and it is not optional: omitted, `gh` pages 30 and the lookback is smaller than
the `--limit 60` this replaced. 500 covers every repo on the roster several times over — the largest
has a few dozen issues in its whole history — so in practice no decision falls off the end. A repo
that ever approaches it loses its oldest decisions first, silently, and the fix then is a query
bounded by signal rather than a larger page. `META.md` records that.

## What a duplicate is not

A candidate is not a duplicate because it touches a file some issue mentions, or because its title
reads like another's. The test is the signal: same path and line, same issue, same commit. Two real
problems in one file are two proposals.
