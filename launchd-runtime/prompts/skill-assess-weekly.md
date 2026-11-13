# Weekly skill assessment routine (launchd-driven, Mondays 04:20)

You are running headlessly via the Claude Code CLI, fired by a macOS LaunchAgent. The user is not present. There is no UI and no human to approve permission prompts — `--dangerously-skip-permissions` is on, but the deny rules in `~/.claude/settings.json` still apply.

## Task

Run `/skill-assess --update` against this repo.

That is the whole routine. The skill owns the roster, the static suite, the judgement pass, the issue filing and the halt conditions; this prompt exists to fire it on a schedule and to say what the run may and may not do.

## Constraints (do not deviate)

- **Quiet weeks stay quiet.** If nothing needs attention, print the report to stdout and halt — no GitHub issue, no Telegram, exit 0. Stdout is captured in the routine log, which is auditable and costs nothing; Telegram is reserved for a week in which something actually needs a human. The skill prints `HALT: skill-assess no-findings` in that case, and that is the expected outcome, not a failure.
- **One Telegram at most**, and only when Action required is above zero. It goes through the sender named in `$AGENTIC_SKILLS_ROOT/skills/notify/SKILL.md`, which owns the recipe and every constraint on it.
- **No `META.md` writes.** Assessments produce findings, not fixes; the skill refuses to write another skill's `META.md` on a headless run, and this routine does not ask it to.
- **No `SKILL.md` edits, no PRs, no code changes.** A finding becomes a `skill-maintenance` issue and stops there.
- Scope is `amarcu/agentic-pipeline` and nothing else. Do not open, compare against, or port anything from another skill repository.
- If the static suite cannot run, the skill halts with `suite-unrunnable`. Report that and exit rather than assessing without it.
