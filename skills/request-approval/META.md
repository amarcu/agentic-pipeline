---
domain: universal
kind: coding
version: 2.0.2
status: active
last-assessed: 2026-09-04
---

## Purpose
The stack's one approval gate. A routine that reaches something sensitive, irreversible or
externally visible calls this skill instead of doing it: the skill creates a labelled GitHub issue
recording exactly what was proposed, sends the Telegram pointing at it, and stops. Nothing here ever
performs the gated action, before or after approval — the caller re-checks the issue at its next
invocation and acts then, if the human said yes.

`kind: coding` — it writes: two labels and an issue in someone else's repo, and a Telegram message.

## Model / budget
- Model: `claude-sonnet-5` — the turn is one decision (which tier) and three commands. The caller
  has already worked out what it wants to do and why; nothing here re-adjudicates that.
- Effort: `low` — same reason. The judgement this skill carries lives in
  `references/gate-issue.md`'s list, not in a chain of reasoning.
- Typical run: not separately measurable. It runs inside the caller's turn, so its tokens land in
  the caller's `runs.jsonl` row; the work is one `gh issue create`, two `gh label create`, and a
  ~1 s Telegram round trip.

**Why a `model:` pin here is safe, and why `disable-model-invocation` must stay off.** This skill is
invoked through the `Skill` tool from inside `work-on-task` and `iterate-on-pr`, so the obvious
worry is that its `model:` would re-route the rest of the caller's turn. The five-run probe of
2026-09-03 settled it, and `notify/META.md` records the same result: with `context: fork` a nested
skill's `model:` does take effect (the run's `modelUsage` carried both models); **without**
`context: fork` — which is this skill's case — the nested `model:` is silently ignored and the
caller stays on its own model. The pin therefore satisfies S2 without touching any caller.

The same probe re-confirmed that `disable-model-invocation: true` breaks a `Skill`-tool call
outright: the caller is told the skill is `/name`-only and the call silently does nothing, no error
and no work. S1 names this skill explicitly as one that must never carry the flag.

## What "approved" means
Mechanical, because "probably approved" is how a gate becomes decoration. The issue is created with
labels `approval-needed` and `automated`, and exactly two signals clear it:

- a human adds the `approved` label to it, or
- a human comments a line starting with `/approve`.

**Declined** is the issue closed carrying neither. Silence, a reaction emoji and "looks fine" in
some other thread are none of the three and leave the gate shut. The caller re-checks with
`gh issue view <N> --repo <owner/repo> --json labels,state,comments` **at its next invocation** —
it never polls, sleeps or waits, because a headless run that waits is a headless run that has hung.

## Tiers
- **`hard`** (default) — the calling routine stops entirely: nothing further in that run, gated or
  not.
- **`soft`** — the caller may finish the part of its work the gate does not cover, and must not
  start the gated part.

Neither tier expires into a yes. `references/gate-issue.md` lists what falls where, including the
one exemption: a draft PR for an issue already labelled `approved`, where the label is the
authorization and a gate would deadlock `work-on-task` against itself.

## Dependencies
- `gh` CLI, authenticated for the target repo — no `gh` means no audit trail, which means no gate
- `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`, and `launchd-runtime/bin/telegram-send`; a failed send
  is reported and the gate still stands, because the issue is the gate
- `ROUTINE` / `ROUTINE_RUN_ID`, exported by `launchd-runtime/bin/_run.sh`, stamped into the issue
- Callers: `work-on-task` and `iterate-on-pr`, both through the `Skill` tool

## Known Issues
- The `/approve` comment signal is checked by the caller, not enforced by GitHub. A human who
  writes "approved" in prose without the label or the leading `/approve` has not cleared the gate,
  and will reasonably think they have.
- No timer, deliberately (see the changelog): a `soft` gate is not a delayed yes, and a caller that
  wants one has to ask again.
- The skill does not check whether an equivalent gate issue is already open, so a caller that
  re-invokes it for the same action before the human answers creates a second issue. In practice
  the callers stop on the first, which is the point of the gate.

## Changelog
- 2026-09-07 (v2.0.2): Arguments now carries the literal `$ARGUMENTS` placeholder. Both
  `work-on-task` and `iterate-on-pr` reach this gate through `Skill(name="request-approval", …)`,
  and a skill with no placeholder receives none of the arguments it is called with — the 2026-09-07
  dispatch outage. A gate that loses the action it was asked to gate is worse than a noisy one.
  Enforced by `test_contract_skills_invoked_with_arguments_carry_the_arguments_token`.
- 2026-09-04 (v2.0.1): Review fix on PR #24. The title rule contradicted the template: Limits
  capped the issue title at 80 characters while the `gh issue create` line allowed an 80-character
  action on top of the fixed 17-character `Approval needed: ` prefix, so nothing said what to
  truncate. The action is now truncated to 63 characters and both places say so.
- 2026-09-04 (v2.0.0): Rewritten to `docs/skill-standard.md`; off the contract-exceptions list.
  Frontmatter keeps `disable-model-invocation` **off** (S1: this skill is invoked through the
  `Skill` tool), gains `model: claude-sonnet-5` / `effort: low` justified by the 2026-09-03 nested-
  skill probe above, and scopes `allowed-tools` to the five command prefixes the body issues,
  replacing bare `Bash`. Body reordered into the S3 sequence with a Contract block and a check on
  every step; SKILL.md 6,097B → 5,119B, with the issue body, the Telegram message and the gated-
  action list moved to `references/gate-issue.md`. **"Approved" is now defined**: labels
  `approval-needed,automated` on creation, cleared only by the `approved` label or a `/approve`
  comment, declined by closing, re-checked by the caller at its next invocation with the exact
  command. **Shell forms fixed**: the old Step 2 built the body with `$(date -u …)` inside a
  `BODY="…"` assignment and captured the URL with `VAR=$(gh issue create …)`; both are denied
  headlessly, so the documented procedure could not have run under the routine it exists for. The
  model now writes the literal timestamp and reads the URL off the command's output. Added
  `--dry-run` (prints the body, creates and sends nothing) and the `APPROVAL:` output line; the
  label is `approval-needed` where v1 used `needs-approval`, created with `--force` alongside
  `automated` rather than only after a failure. **Removed**: the soft-tier "auto-proceed after 4
  hours" promise — nothing ever implemented the wait, so it documented a behaviour the stack did
  not have.
- 2026-07-14 (v1.1.1): Telegram send rewritten to the shared `launchd-runtime/bin/telegram-send`
  two-command form (literal /tmp path + single unchained send); removed the inline python-urllib
  copy, `mktemp`, and `rm` cleanup — those forms are permission-denied in headless runs (2026-07-14
  audit).
- 2026-07-09 (v1.1.0): Tightened the hard-gate list's PR bullet — all PR-opening gates, with a
  single exemption: a draft PR for an issue carrying the `approved` label (the label is the
  authorization; work-on-task's contract). Ad-hoc draft PRs still gate; marking ready always gates.
  Replaces the blanket "Opening a pull request", which contradicted work-on-task.
- 2026-05-06: Initial version
