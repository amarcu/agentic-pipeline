# Queue building — the rationale behind Steps 1 to 3

`SKILL.md` states the rules. This file states why they are the rules, so a future edit does not
undo a fix by making the body look tidier.

## One repo per Bash call

Step 1 fetches one repo's issues and PRs per Bash invocation and never loops over the roster inside
a single call. A nine-repo mega-loop once hit one `gh` TLS flake partway through, lost every repo's
data with it, and spent the run's whole budget re-scanning. Isolating the call means a flake costs
one repo, which is then reported as `skipped: gh error` rather than silently widening the gate.

Shell state does not persist between Bash calls, so each call re-sources `repos.conf`.

**Shell portability.** Headless runs execute under zsh or macOS bash 3.2, which has no `declare -A`.
Track the in-progress, deferred and skipped sets as plain space- or newline-separated lists and test
membership with `case` or `grep`. `get_repo_path` and `get_driver` in `repos.conf` are `case`-based
functions for the same reason.

## Step 1 drops at two levels: whole repos, then issues inside them

Step 1's verify line asks that every active repo end up in one of three buckets, and they are not
interchangeable — each names a different thing to fix.

- **in the queue counts** — the repo was scanned and its surviving approved issues are queued.
- **`unmet`** — `check-requirements <repo>` exited 1, so this host is missing tooling the project
  declared, or the manifest has a line nobody can parse. The whole repo is dropped before any of
  its issues are considered: every worker it could take would halt at the verify gate, and
  discovering that costs a full forked session per issue. `unmet` is reported on the gate line and
  is deliberately not a halt — one repo without its tooling must not stop the other six.
- **`skipped:`** — the repo could not be *read*: a `gh` call failed, or `check-requirements` exited
  2. Exit 2 is a `repos.conf` error — the repo is not in `get_repo_path`, or resolves to a
  directory that is not there — and not a host gap, which is why it is not `unmet`. The fix is a
  line in `repos.conf`, not a `brew install`, and putting it in `unmet` would send a human hunting
  for a tool that was never the problem.

A repo in any of the three is accounted for. A repo in none of them was silently lost, which is
what the verify line exists to catch.

Two exit codes are deliberately NOT drops. Exit 0 dispatches, and it covers three different
reports: `ok`, `no-manifest` (no `agent/requirements.conf` in the checkout and no staged template),
and `advisory` (the manifest failed but the project has already said what to do without the
tooling, so the worker proceeds with its verify gate fixed at `no-gate`).

`advisory` does not cover everything that manifest can fail on. A `cmd` that is installed but below
its declared `>=` floor exits 1 whatever the gate says — `REQ: … below-floor=<names>` — and lands
in `unmet` like any other unmet requirement. The tool is present and the project has declared its
output untrustworthy, so downgrading to `no-gate` would skip the very check the floor was written
for. `bin/check-requirements`' module docstring has the StarBonk case that made this concrete.

## What Step 1 drops, the test for each, and why

These are the ISSUE-level drops, applied inside a repo that survived the paragraph above.

- **in progress** — an open PR whose `headRefName` matches `task/issue-<N>-*` or
  `worktree-issue-<N>*`, or whose body holds `Closes #<N>` or `Refs #<N>`. Idempotence lives here
  rather than in the worker: `work-on-task` refuses an issue that already has a PR anyway, but
  refusing it costs a whole forked session to find out.
- **blocked** — it carries a label starting `blocked:`. Count it, never dispatch it.
  `work-on-task` writes that label on a hard refusal, so re-dispatching such an issue buys a
  guaranteed second refusal. Only a human clears it.
- **deferred** — an unmet `DEPENDS ON` per `docs/depends-on-convention.md`; see below for the
  grammar and the 404 rule.
- **unanchored** — `shape:feature` in a repo `get_driver` names, with no `DRIVEN BY <driver>#<N>`
  line in its body. Report it in the plan as `skipped: driven repo, no DRIVEN BY`. It gets no
  label because the issue is not defective, only unanchored, and labelling it would need a human to
  clear it later for a problem no human caused.

## Why the gate counts open agent PRs and nothing else

The nightly dispatch deadlocked on 2026-09-02. The cap then in force counted open agent PRs **plus**
approved-but-unstarted issues, so two open PRs and seven approved issues read as nine against a cap
of six: the run dispatched nothing, and the approved issues had no other way out of the queue. The
queue was blocking the only gate that could drain it.

The cap now counts open agent PRs only, is named `DISPATCH_TOTAL_MAX`, and is defined once in
`repos.conf`. It had previously existed under four names with four different values across
`repos.conf`, `SKILL.md`, `META.md` and the night prompt, which is why `test_cap_names.sh` now fails
the suite if a skill or prompt names a `*_MAX` that `repos.conf` does not define.

`slots <= 0` is reachable *below* zero, not just at zero: a hand-written PR whose body says
`Closes #<n>` matches the agent-PR rule and counts. That is deliberate — the cap measures review
load, and a human PR awaiting review is review load.

## Why one global count was a weakest-link gate

A single global count made every active repo share one fate. Two or three unreviewed PRs in one
repo consumed `DISPATCH_TOTAL_MAX` on their own, and from then on the gate was shut for all seven
active repos — including the ones with zero open PRs and approved work sitting ready. The pipeline
ran at the speed of its most-neglected project, which is the opposite of what a roster of
independent repos should do.

`DISPATCH_PER_REPO_MAX` gives each repo its own count, so a repo that stops draining stalls only
itself. `DISPATCH_TOTAL_MAX` stays, but its job narrowed: it is now purely a ceiling on the human's
total review load, and no single repo can reach it alone. `DISPATCH_RUN_MAX` is the third and
different kind of bound — a rate limit on one night's batch rather than a cap on standing state, so
a morning that starts with several free slots still gets a batch a person can read.

The gate therefore halts on `no repo is eligible`, never on one repo being full, and the halt names
each at-limit repo with the oldest agent PR to land in it. A human reading the log sees which
review reopens which repo, instead of one number that says only "everything is stuck".

The ceiling-bound halt is the case that needs saying separately. When `DISPATCH_TOTAL_MAX` is what
closed the gate, no repo need be at its own limit, so `at_limit` is empty and the per-repo pointers
have nothing to name. That halt reports the oldest agent PR across the active repos instead, as
`global ceiling: land <owner/repo>#<n>` — otherwise the one halt a human cannot act on locally is
also the one the log gives no lead for.

## `DEPENDS ON` and driver/driven

Two different lookups run over an approved issue's body, and they answer different questions.

- **`DEPENDS ON`** — is this issue's prerequisite finished? The grammar, the parsing order
  (cross-repo `owner/repo#N` extracted and stripped first, so `acme/foo#7` is not also matched as
  same-repo `#7`) and the cross-repo failure modes live in
  `docs/depends-on-convention.md` at the root of this repository. Read it before
  parsing. A dep is satisfied only when `gh issue view` reports `CLOSED`; a 404 on a cross-repo
  lookup is unmet with a warning, never silently satisfied.

  A closed dependency means the dep's PR merged. It does **not** mean the change is deployed. Where
  deploy-before-consume matters, the human verifies deployment before approving the dependent issue.

- **`DRIVEN BY <driver>#<N>`** — does this feature have a reason to exist yet? Some repos drive the
  features needed in others: `get_driver <owner/repo>` in `repos.conf` prints a repo's driver, or
  nothing when it is undriven. A driven repo earns feature work only when its driver needs it, so a
  `shape:feature` issue in a driven repo with no `DRIVEN BY` line is skipped and reported, not
  dispatched. It gets no `blocked:` label: the issue is not defective, it is unanchored, and the
  planner is what supplies the anchor. Labelling it would need a human to clear it later for a
  problem no human caused.

  Health and stability work in a driven repo is secondary rather than forbidden, which is why
  `shape:polish` there still dispatches — just after the driver and undriven repos are served.

## Ordering: shape bands, then round-robin

Step 3 orders by shape band first (features and polish in driver and undriven repos, then features
and polish in driven repos, then chores anywhere), and round-robins across repos inside each band.

Round-robin rather than strict priority order because strict priority starves the tail: if the
top-priority repo always has approved work, the last repo never gets a cycle. Round-robin gives a
busy repo no head start over a quiet one while never refusing its work — if only one repo has
approved issues it takes every slot its own `slots_r` allows, which is normal and must still drain.

Ordering and the per-repo cap do different jobs and both are needed. Round-robin decides who goes
first inside a round; `slots_r` decides who is still in the round at all, and drops a repo out of
the rotation the moment its share is spent. Without the cap, ordering alone let one repo fill the
global ceiling; without the ordering, the cap alone would still serve the priority list top-down
until the run's budget ran out.

## Why sequential, not parallel

The measured bottleneck is human review, not agent execution: across 57 agent PRs, merge outcome was
explained entirely by whether a review session happened that week. Dispatching in parallel would
produce PRs faster into a queue that is already the constraint, which is the failure
`DISPATCH_TOTAL_MAX` exists to prevent. Sequential is also the simplest thing that works at solo-dev
pace (BASELINE Principle 2), and the queue-building logic in Steps 1 to 3 is unchanged if a future
version ever does run workers concurrently.

The dispatcher itself never enters a worktree. `work-on-task` creates and enters its own inside its
fork, and leaves it with `ExitWorktree(action: "keep")`; a stale absolute path into the main
checkout from a caller that had entered one was a failure mode worth designing out entirely.
