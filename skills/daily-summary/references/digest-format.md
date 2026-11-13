# The digest: one template, one order, one set of caps

Read this at Step 5. It is the only place the digest's shape is stated — the quiet day and the
busiest day use the same template, because two templates drift into two different answers to
"what happened today".

## Template

```
🌙 Daily summary — <Day, Month D>

⛔ Starved: <owner/repo> — nothing approved, nothing in flight (<p> proposed). Approve one, or run /plan-features --repo <owner/repo>.
👀 Needs your review (<n>):
  • <owner/repo> PR #<n> — <title>
✅ Ready to merge (<n>):
  • <owner/repo> PR #<n> — <title>
⏸ Blocked (<k>):
  • <owner/repo> #<n> — blocked:<reason>
✅ Shipped (<s>):
  • <owner/repo> PR #<n> — <title>
🔇 Stale (>7d) (<n>):
  • <owner/repo>: <count>, oldest "<title>" (<n>d)

⚙ Pipeline: in flight <n>/<cap> · at limit <repo,repo> · waiting <m> · blocked <k> (<reason>: <n>, …)
💸 Spend: $<total> (<routine> $<x>, …) · <m> sends
🧱 Friction: <n> repeated in 7 days — <kind> <routine> <tool> "<what>" ×<runs>; …
🔁 Review: <r> reviewed of <n> agent PRs opened in 7 days — <c> clean, median <m> rounds, <k> at the round cap, merged today on an unpassed commit: <owner/repo>#<n>, … · (error) <owner/repo>
<!-- agentic-skills: skill=daily-summary repo=- routine=${ROUTINE:-interactive} run=${ROUTINE_RUN_ID:-none} model=claude-sonnet-5 -->
```

On a quiet day the five bucket sections are replaced by the single line SKILL.md Step 5 gives; the
header, the starved lines, the pipeline line, the spend line, the friction line, the review line
and the marker are
unchanged. They are
never skipped when their script printed one.

## Order, and why

0. **Starved** — one line per starved repo, first, because it is the one state in which every
   other count reads zero and the night will do nothing. Five nights of `empty-queue` once
   rendered as `waiting 0 · blocked 0`, which reads as healthy.
1. **Needs your review** — the largest call to action, so it goes where a phone notification
   preview shows it.
2. **Ready to merge** — the cheapest thing the human can do.
3. **Blocked** — work that a label says is stopped until a human clears it.
4. **Shipped** — the day's output. Retrospective, no action.
5. **Stale** — background. Reported by count and the oldest item, never enumerated.

The pipeline line comes after the sections rather than before them because it answers a different
question — "is the machine moving?" rather than "what do I do next?" — and because it is the line
that must be present even when every section above it is gone. That is the whole reason it exists:
a day with no merges and no closes still has a state, and five of five slots in flight behind seven
approved issues is a deadlock that the digest used to render as "All quiet today".

Since dispatch gained a per-repo cap, the roster total is no longer the whole state: two repos at
their own limit stall those repos while the overall figure still reads under the ceiling. That is
why the line names the at-limit repos rather than only counting PRs — the number says how full the
review queue is, the names say which repo a review would restart.

## Caps and filters

- Ten lines per section, then `… and <n> more`. A section that needs more than ten lines is a
  section the human will skim.
- Under 2000 characters overall. Telegram allows 4096; readability does not.
- Plain text, no `parse_mode`, so `<`, `>` and `&` need no escaping and the attribution marker
  renders literally. That is deliberate: the marker is what joins a message in `sends.jsonl` back
  to the run that composed it.
- No bot-authored item under Shipped — a login ending `[bot]` (`vercel[bot]`, `dependabot[bot]`)
  is deploy noise, not the day's work.
- An issue a listed PR closes with `Closes #<n>` appears once, as the PR.
- `(error)` beside a repo whose `gh` calls failed, so a missing repo is never read as a quiet one.
- **in flight** counts what `dispatch-tasks` calls an agent PR, and nothing else. Any other
  definition makes the two skills disagree about one queue.
- The `at limit` segment of the pipeline line is dropped entirely when no repo has reached
  `DISPATCH_PER_REPO_MAX` — on most days it is absent, and printing `at limit -` nightly would
  teach the reader to skip the line that matters on the day it is not.

## Spend line

Rendered from the `SPEND:` line `scripts/spend-today` prints, and omitted entirely when it prints
nothing. The script already caps itself at the three costliest routines, so render the names it
gives and no more. `total_usd` is the authoritative figure and the named costs are a sample of it;
they are not expected to sum to it.

## Friction line

Rendered from the `FRICTION:` line `scripts/friction` prints, and omitted entirely when it prints
nothing — which is most days. Each entry is a denied command or a failed tool call that stopped the
same routine in two or more runs this week. That is either a rule that makes no sense or a skill
reaching for something it should not, and the human decides which; the line exists to put it in
front of them, not to explain it. Render the entries the script names, verbatim and no more. A
failed call carries its error after a colon. A path keeps its end, because the end names the file.

## Review line

Rendered from the `REVIEW:` line `scripts/review-line` prints, and omitted entirely when it prints
nothing: no agent PR opened this week has a marked review yet, or the rollup did not run. It says
what review cost the week's PRs, where the pipeline line says only whether they are moving. Render
the counts and the named PRs verbatim and no more. `clean` is a PR on which every review passed.
The `at the round cap`, `merged today on an unpassed commit` and `(error)` segments are absent when
they have nothing to name. A PR named after `merged today on an unpassed commit` merged today with
no pass on the commit that merged. The merge lane never does that, so the merge was made outside
it: by the owner, or by an interactive session on the owner's word, as when the review rounds run
out and the pipeline asks for the owner's merge. GitHub cannot tell the two apart, because both
post as one account. It is named on the evening it happened and not again. `(error)` names a repo
the rollup could not read, so its silence is not taken for a quiet week; when no other repo has a
review to report, the script prints `REVIEW: no review read in 7 days · (error) <owner/repo>` and
that is rendered as it stands.
