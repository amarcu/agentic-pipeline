# Replies, the summary comment, and the Copilot review rounds

Read this at Step 6, after the push — one summary comment per run, on the PR, and nothing
else — and again at Step 7 when `--review-rounds` is above zero.

## Shape

The first line is load-bearing: `daily-summary` finds this run by the literal prefix
`Addressed in `, and uses its timestamp as the "new comments since" cut-off it reports to the human.
Changing the prefix silently breaks it.

`pr-feedback` keys on the same comment for its `addressed` cut-off, but finds it by the attribution
marker at the bottom, never by that prefix — the human writes under the same login, so a human
comment opening "Addressed in the release notes…" would otherwise retire every thread older than
it. Both lines are required: the prefix is the contract with `daily-summary`, the marker is the
signature.

```markdown
Addressed in <sha7>:

- f1 (blocker, src/loader.ts:88) — added the guard; `npm test` covers it in loader.test.ts
- f3 (minor, docs/README.md) — reworded as asked
- "swap the order, Chivu first" — done in pages/about.tsx
- CSS spacing under the name — changed; needs human verification on rendered output

Contested:

- f2 (major) — the manifest is parsed once already, at startup: `Loader.init()` line 34 runs before
  any frame. Left unchanged.

Skipped:

- the screenshot on src/hud.tsx:12 — asked in the thread what should change

Verify: `<gate command>` passed.

<!-- agentic-skills: skill=iterate-on-pr repo=<owner/repo> pr=<N> round=<R> sha=<sha> addressed=<n> skipped=<n> routine=${ROUTINE:-interactive} run=${ROUTINE_RUN_ID:-none} model=<id> -->
```

Every section is optional except the first line, the items and the marker. An empty section is
omitted, not printed empty.

## The Copilot review rounds (Step 7)

`--review-rounds <n>` is `0` by default, and `0` means none of this runs: the skill pushes, replies,
summarises and stops, exactly as it did before the flag existed. Above zero, it drives the loop a
human used to drive by hand — four rounds on `amarcu/agentic-pipeline#35` in a single day, each one a
person reading comments, handing them to a worker, and re-requesting a review.

One round is three commands and nothing else — no clock, no timestamp, no shell of your own. Step 5
must have pushed a commit since the last review, or `request` refuses at cost of nothing (exit 6);
`wait` bounds itself, waiting for a review of the head commit submitted from the moment it starts.

Spell the path out on each line — `allowed-tools` pre-approves that literal prefix, and a shell
variable holding it does not match. This file is read, not expanded, so write
`${CLAUDE_SKILL_DIR}` out as this skill's folder, the value SKILL.md was loaded with:

```bash
${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/pr-review-round request "$REPO" "$PR"
${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/pr-review-round wait "$REPO" "$PR"
${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/pr-review-round status "$REPO" "$PR"
```

Never reach for anything the skill's `allowed-tools` does not name to feed these. A headless run is
deny-closed, so a command with no grant does not fail loudly — the step simply never happens, and
the round with it. That is what an earlier draft of this file cost: it told the worker to compute a
`--since` with `date -u`, which `iterate-on-pr` never granted, so the loop could not have run at
all. `wait` takes an optional `--since` for a human reconstructing a round by hand; the loop passes
none.

- `request` prints `requested` or `already-pending`, and exits 0 for both. **Exit 3 means no request
  was created** — it verified rather than trusting the HTTP status, because the plain `Copilot`
  reviewer form returns success and does nothing. Exit 3 ends the loop; do not retry it blind.
- **Exit 6 is `already-reviewed-at <sha7>`: this head SHA already carries a Copilot verdict.** A
  review is metered per invocation — GitHub bills it in AI credits to whoever requested it, roughly
  $0.05-$1 on Lite effort and $0.25-$5 on Balanced, "each time Copilot reviews a pull request", with
  no de-duplication for a repeat on an unchanged SHA. The allowance resets at 00:00 UTC on the first
  of the calendar month, so an exhausted one does not come back the same day. `amarcu/agentic-pipeline`
  \#35 carries two reviews against commit `01ba178b`, twelve minutes apart: the second was bought
  with the human's allowance and said what the first already said. So **never open a round without
  having pushed a commit for it** — a rehearsal that re-requests on an unchanged SHA spends real
  money on a verdict already sitting on the PR. `--force` overrides the guard, and is for a human
  who has decided to pay for a second opinion, never for the loop.
- `wait` prints `ROUND: <owner/repo>#<n> review <submitted_at> <verdict>` and exits 0 — but only
  for a review **of the head commit**, submitted after the wait began. A review of any other commit
  does not end the wait, however recently it was posted: Copilot answers late, and #35 has two
  reviews against one commit twelve minutes apart, so without that rule a verdict on the previous
  push satisfies a round opened for this one and `status` then reports on code nobody reviewed.
  **Exit 4 is a timeout, and a timeout is not a green light** — this commit was not reviewed, so it
  was not approved. It ends the loop at `verdict=timeout`. Seeing only reviews of older commits is
  a timeout too, never a verdict.
- `status` exits 0 only when **the head commit's** verdict is 🟢 and no root review comment is
  still unanswered. It reads the same review `wait` does, by the same lookup, so the two cannot
  disagree. Anything else is exit 1, `no-review` included — and `no-review` covers both "nobody has
  reviewed this PR" and "the reviews on it are of commits you have since replaced". A 🟢 against
  the commit before your push is not this push's 🟢, and exit 0 is what stops the loop. Its stdout
  lists each unanswered finding as `<id> <path>:<line> <first line>`.
- **Exit 5, from `wait` or `status`, is `quota-exhausted`.** Copilot answered the request with
  "Copilot was unable to review this pull request because the user who requested the review has
  reached their quota limit" — no verdict line, no findings. It is the shape most likely to be
  misread: as a verdict it looks like silence, as a comment count it is zero unanswered, and it is
  neither. The round did not happen. **Stop the loop immediately** — do not spend the remaining
  rounds, and do not re-request. Print `verdict=quota-exhausted`, say in the summary comment which
  verdict was the last substantive one, and leave the human to decide between acting on that verdict
  and waiting for quota to reset. It is what happened on `amarcu/agentic-pipeline#35` on 2026-09-08,
  after four rounds in one day.

Exit 2 from any of the three is a gh failure — a named error, never an empty result. It ends the
loop too. None of these codes is ever read as green.

### What each round does

Each subcommand asks one question — is there a Copilot review of THIS commit — through one shared
lookup. Nothing in the loop should ever compare "the newest review" against anything: a review of an
older commit can arrive after the one that matters, and every silent green this script has had came
from treating the two as the same thing.

`status` exit 0 → print the `ITERATE:` line with `verdict=green` and stop; the rounds are done.
Anything else → the findings `status` listed, plus whatever the new review body raised, are the next
round's work: Steps 4, 5 and 6 again over those items **alone**, then `request` again. Stop when
`status` is green, when `<n>` rounds have run, on a `wait` timeout, or on `quota-exhausted` — and in
every case but the first the `ITERATE:` line carries the verdict `status` actually printed, never
`green`.

The rounds change nothing else about the skill. The PR stays a draft, `gh pr ready` and `gh pr merge`
stay forbidden, and green is a thing to report, not a thing to act on.

It is also only this lane's green. `launchd-runtime/bin/cursor-review` drives a second reviewer lane
with rounds of its own, `review-pr` is a third, and neither gates the others. `verdict=green` here
says Copilot is satisfied with this commit; it does not say the PR is reviewed, and it is never a
reason to stop reading what another lane has posted.

### Every finding gets an answer

A round is only over when every finding has a reply — the same rule as Step 6, applied per round:

| Outcome | Reply |
|---|---|
| fixed | what changed, and the test that proves it, plus `<!-- reply finding:<id> outcome:fixed -->` |
| declined | why the finding is wrong, with the evidence, plus `<!-- reply finding:<id> outcome:contested -->` |

**Clearing a comment by making a change you believe is wrong is forbidden.** It is the one way this
loop can do real damage: an edit made to silence a reviewer looks identical, in the diff and in the
round count, to an edit that fixed something — and the next round reads that record as settled. If
you judge a finding invalid, decline it and say why. A decline carries a symbol, a file and line, or
a command's output; "I disagree" is not evidence. Copilot adjudicates it in the next round of this
lane, and a decline that turns out to be wrong costs one round. A wrong change costs the code.

## The attribution marker

The last line, verbatim, with the placeholders filled:

```html
<!-- agentic-skills: skill=iterate-on-pr repo=<owner/repo> pr=<N> round=<R> sha=<sha> addressed=<n> skipped=<n> routine=${ROUTINE:-interactive} run=${ROUTINE_RUN_ID:-none} model=<id> -->
```

`ROUTINE` and `ROUTINE_RUN_ID` are exported by `_run.sh`; the defaults are what an interactive run
gets. `round` is the review round this pass answers, `sha` the commit that answers it. The marker
renders as nothing on GitHub and greps as an exact string, which is how the next run recognises its
own work (skill standard S6, S7).

## The in-thread replies

Posted before the summary, one per thread acted on — the summary comment is not a substitute,
because nothing joins it back to a thread:

```bash
gh api "repos/$REPO/pulls/$PR/comments/<id>/replies" \
  -f body="Added the guard in parse(); loader.test.ts covers it. <!-- reply finding:f1 outcome:fixed -->"
```

| Thread | Marker |
|---|---|
| reviewer finding, fixed | `<!-- reply finding:<id> outcome:fixed -->` |
| reviewer finding, contested | `<!-- reply finding:<id> outcome:contested -->` |
| human, acted on | `<!-- reply iterate-on-pr outcome:addressed -->` |
| human, question asked back | `<!-- reply iterate-on-pr outcome:clarify -->` |

The reviewer rows are the same for both lanes, and the reply must be a **threaded reply** on the
finding's own comment — `gh api "…/comments/<id>/replies"` — never a new top-level comment. Since PR
\#37 `cursor-review` re-reads the PR's review comments at the start of each round, matches its own
prior findings by id, and follows `in_reply_to_id` to see what was said about each; a reply that is
not on the thread is invisible to it, and its next round re-raises a finding you already fixed. The
`<!-- reply … -->` marker serves a different reader — `pr-feedback`, which uses it to know the
thread is answered — so both halves are required: on the thread, and marked.

A contested reply carries the evidence that settles it — a symbol, a file and line, a command's
output — not an opinion. Contesting is a legitimate outcome; the reviewer adjudicates it next round.

The marker is what makes a second run idempotent. `resolveReviewThread` is deny-listed for scheduled
runs (`launchd-runtime/bin/_run.sh`), so a resolved thread is not available as the record and the
reply has to be it.
