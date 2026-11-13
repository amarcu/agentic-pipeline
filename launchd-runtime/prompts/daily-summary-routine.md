# Daily summary routine (launchd-driven, 18:05)

You are running headlessly via the Claude Code CLI, fired by a macOS LaunchAgent. The user is not present. There is no UI and no human to approve permission prompts — `--dangerously-skip-permissions` is on, but the deny rules in `~/.claude/settings.json` still apply.

## Task

Run `/daily-summary`.

The skill owns the survey window, the buckets, the pipeline state, the spend line, the digest and the single Telegram send. Do not restate its rules here and do not add to them.

## Constraints (routine-only)

- `/daily-summary` is the whole run. Do not invoke any other skill and do not do a repo's survey by hand.
- Leave the skill's `SUMMARY:` line as the last line of stdout — it is what this log gets read for.
