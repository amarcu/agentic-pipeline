# Review protocol

A model-agnostic contract for reviewing one pull request: any reviewer that can read a diff, run a
command and emit text can execute it. It yields findings and a verdict; it never merges, marks
ready, pushes or approves.

Input is an isolated bundle: the diff at the head SHA, per-file hunk ranges, the tree at that SHA,
and the issue's acceptance criteria as `- [ ]` items. The PR's description, commit messages and
author comments are deliberately absent and must not be fetched; from round 2 the reviewer may read
its own prior findings and the replies to them — nothing else.

A bundle containing `pipeline-notice.md` is a PR that modifies the pipeline itself, and the two
lanes part company here. A non-Claude reviewer may review it: a change to the guardrails is exactly
what most deserves an outside reader. A Claude reviewer must not, and never sees one —
`pr-review-bundle` refuses to build such a bundle unless the caller passes `--allow-pipeline`, which
only `cursor-review` does, and only after proving its own model is not an Anthropic one.

## Finding schema

- `id` — `f<n>`, stable for the PR's life
- `severity` — `blocker` (must change), `major` (unproven or unsafe), `minor`
- `path`, `line` — at the head SHA, so it anchors to a diff line
- `claim` — one sentence: what is wrong
- `evidence` — a command's output, a symbol it resolved, a file+line it read
- `what-settles-it` — the observation that would close it

A finding without evidence the author did not write is not a finding. Every inline comment ends with
a tag so the next round can match replies:

    <!-- finding:<id> severity:<blocker|major|minor> round:<K> -->

When the gate prints a machine-readable verdict, quote it verbatim as the `evidence` — never
paraphrase it. An author can dispute your reading of their code, and sometimes should; they cannot
dispute `error CS0246` or a named failing test. A finding carrying the gate's own words is the one
kind that ends in a fix instead of an argument, so prefer a finding the gate can settle over one
only prose can.

## Adversarial checklist

Run all five; cite the item number in each claim.

1. **Every `- [ ]` criterion maps to a hunk AND to a test or a stated manual check** — otherwise
   `major: criterion unproven`.
2. **Any deleted, skipped or weakened test is `major`** — a loosened assertion or an ignore
   annotation counts.
3. **Changes outside the issue's scope are flagged** — `minor` when inert, `major` when they alter
   behaviour.
4. **A gate that ran and failed is a `blocker`** — no argument settles it, only a passing gate.
5. **Claims in the PR body, commit messages or code comments are never evidence** — "tested
   manually" is an assertion to verify.

## Gate outcomes

| Outcome | Condition |
|---|---|
| `passed` | it ran and reported success |
| `failed` | it ran and reported failure — a `blocker` finding on its own |
| `no-gate` | `CLAUDE.md` says `NO GATE — verify by reading` |
| `could-not-run` | no `src/`, no `CLAUDE.md`, or the tool is absent on this host |

`no-gate` and `could-not-run` can never verdict `pass` — at most `changes-needed` or `escalate`,
with the reason stated. Never record a gate as run when it did not run.

## Posting a review

`event: COMMENT` is the only usable event: every PR here is `viewerDidAuthor: true` under one
account and GitHub rejects `APPROVE`. Inline threads are load-bearing: `iterate-on-pr` Step 2
consumes exactly `reviewThreads(isResolved, isOutdated, path, line, comments)`, so a finding posted
that way is picked up unchanged and one posted as prose is not.

## Rounds and budgets

Rounds number from 1 to `REVIEW_ROUND_MAX`; the final one adjudicates, concedes or escalates but
raises no new finding. `REVIEW_NEW_FINDINGS_BY_ROUND` caps new findings per round and is zero there;
`REVIEW_FINDINGS_MAX` caps them for the PR's life, and reaching it is `escalate`, reason `resplit`:
the PR is too large to review incrementally. Values come from the deployment (here, `repos.conf`).
From round 2, adjudicate each prior finding `fixed`, `still-open` or `contested`.

Rank new findings by severity and record in the verdict how many you dropped to the per-round cap,
rather than dropping them silently. Reaching `REVIEW_FINDINGS_MAX` also applies the
`review-escalated` label.

## Verdict

```json
{ "repo": "owner/name", "pr": 15, "head_sha": "...", "round": 1, "model": "...",
  "gate": {"outcome": "passed|failed|no-gate|could-not-run", "command": "...", "exit": 0},
  "findings": [{"id": "f1", "severity": "blocker", "path": "...", "line": 42, "state": "new"}],
  "open": {"blocker": 1, "major": 2, "minor": 0},
  "verdict": "pass|changes-needed|escalate", "reason": "..." }
```

`pass` requires gate outcome `passed` and no open `blocker` or `major`. A gate that did not run —
`no-gate` or `could-not-run` — has `command` and `exit` `null`, and caps the verdict at
`changes-needed`, naming which: "I read it and it looked fine" is not a verification.

A gate that ran but verified nothing is `passed` for outcome and no support for any claim about
behaviour. `unity-gate`'s `pass-no-tests` — the project compiles, the suite is empty — is not
`pass` with a footnote: an empty suite reports `result="Passed"` and exits 0, so it is
indistinguishable from a green one by exit code alone. Say which of the two you got.
