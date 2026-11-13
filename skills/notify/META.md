---
domain: universal
kind: coding
version: 2.0.2
status: active
last-assessed: 2026-09-03
---

## Purpose
Owner of the stack's single Telegram send recipe (S8) and of the reasons it is shaped the way it
is. Two callers, two shapes: a scheduled skill runs
`launchd-runtime/bin/telegram-send` itself and cites this skill for the constraints, while a coding
skill mid-turn invokes it through the `Skill` tool. Either way the sender appends one row to
`sends.jsonl`, which is what makes "did the pipeline tell me about this?" answerable after the fact.

`kind: coding` — it writes: a Telegram message the human sees, and a ledger row on disk.

## Model / budget
- Model: `claude-sonnet-5` — the work is writing a file and running one command; the caller has
  already decided what to say.
- Effort: `low` — same reason. No search, no judgement calls beyond truncation.
- Typical run: not separately measurable. notify runs inside the caller's turn, so its tokens land
  in the caller's `runs.jsonl` row; the send itself is two Bash calls and a ~1 s HTTP round-trip.

**Why a `model:` pin here is safe.** notify is invoked through the `Skill` tool from inside another
skill's turn, so the obvious worry is that its `model:` would re-route the rest of the *caller's*
turn. A five-run probe on 2026-09-03 settled it: with `context: fork` the nested skill's `model:`
does take effect (the run's `modelUsage` carried both models); **without** `context: fork` — which
is notify's case — the nested skill's `model:` is silently ignored and the caller stays on its own
model (`modelUsage` carried one). The pin therefore satisfies S2 without touching any caller.

The same probe re-confirmed why `disable-model-invocation` must stay off: with it set, the `Skill`
call did nothing and the caller was told the skill is `/name`-only. S1 says the Skill-tool rule
wins over the Telegram clause.

## Dependencies
- `TELEGRAM_BOT_TOKEN` env var
- `TELEGRAM_CHAT_ID` env var
- `launchd-runtime/bin/telegram-send` (the only sender)
- `ROUTINE` / `ROUTINE_RUN_ID` / `METRICS_DIR`, exported by `launchd-runtime/bin/_run.sh` — absent
  in an interactive run, which the ledger records as `routine: "interactive"`

## Known Issues
None.

## Changelog
- 2026-09-07 (v2.0.2): Arguments now carries the literal `$ARGUMENTS` placeholder. Both
  `work-on-task` and `iterate-on-pr` reach this skill through `Skill(name="notify", …)`, and a
  skill with no placeholder receives none of the arguments it is called with — the 2026-09-07
  dispatch outage. Enforced by
  `test_contract_skills_invoked_with_arguments_carry_the_arguments_token`.
- 2026-09-03 (v2.0.1): Review fixes on PR #18. `telegram-send` treated any HTTP 200 as delivery,
  but Telegram reports a rejected message — unknown chat, blocked bot — as `ok: false` inside a
  200. The old code printed `sent message_id=None` and wrote a ledger row with a null id for a
  message nobody received, which is the precise failure the ledger exists to rule out. The body is
  now checked: `ok != true` exits 1 with the API's own description on stderr and writes no row.
  The mock Telegram fixture grew a `MOCK_TG_NOT_OK` switch to make that answer testable.
  SKILL.md's pointer to `reference.md` also named only missing credentials and recipe changes,
  while the file now carries send diagnostics too — it names that case, and `reference.md` gained a
  "Reading a failed send" section distinguishing the four nonzero exits.
- 2026-09-03 (v2.0.0): Rewritten to `docs/skill-standard.md`; off the contract-exceptions list.
  Frontmatter scoped (`allowed-tools` now names the two literal command prefixes the body issues,
  replacing bare `Bash`) and given `model: claude-sonnet-5` / `effort: low` (S2), justified by the
  nested-skill probe above. Body reordered into the S3 sequence with a Contract block and per-step
  checks; rationale moved to `reference.md` and cited via `${CLAUDE_SKILL_DIR}` (SKILL.md 3653B →
  2793B). **Breaking:** the `--issue` mode is gone — no caller in the repo used it, and creating a
  tracked issue is `request-approval`'s job; `argument-hint` is now `"<message> [--dry-run]"`, with
  `--dry-run` printing the message and skipping the send. The Step 1 credential echo is gone too:
  the sender already checks and exits 2. Corrected the `Bash(rm:*)` claim — the blanket deny was
  replaced by 28 targeted denies plus a PreToolUse hook, so the reason for no cleanup is now the
  chaining rule, not a deny that no longer exists.
- 2026-09-03 (sender): `telegram-send` now appends one row per accepted send to
  `${METRICS_DIR}/sends.jsonl` — `{ts, routine, run_id, message_id, chars, sha256, refs}` — so the
  pipeline's notifications are auditable instead of living only in a Telegram scrollback. The write
  is best-effort and can never fail a delivered send. Covered by
  `launchd-runtime/tests/unit/test_telegram_send.sh`.
- 2026-07-14 (v1.1.0): Send procedure rewritten around the shared `launchd-runtime/bin/telegram-send` script — literal `/tmp/notify-message.txt` heredoc + single unchained `python3` call, no cleanup (the old mktemp/export/python3-heredoc/rm recipe hit headless permission denies); BotFather setup walkthrough and send-pattern rationale moved to reference.md (assessment items P1/D5).
- 2026-07-08 (v1.0.1): Doc fixes from skill-assess — moved the `_NOTIFY_MSG_FILE` export into the main send block (the block previously read the var before the export was shown, so it failed if run verbatim), and corrected the Guidelines to match the payload (plain text, no `parse_mode`; the old line implied HTML mode).
- 2026-05-06: Initial version
