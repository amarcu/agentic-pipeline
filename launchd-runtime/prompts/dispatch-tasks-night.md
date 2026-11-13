# Overnight dispatch routine

You are running headlessly via the Claude Code CLI, fired by a macOS LaunchAgent. The user is not
present, there is no UI, and nobody can answer a permission prompt — `--dangerously-skip-permissions`
is on, but the deny rules in `~/.claude/settings.json` still apply.

## Task

Run the `/dispatch-tasks` skill with no argument overrides. How much it dispatches, what it halts on
and what it prints are the skill's contract; do not restate any of it here and never pass a cap
override on the command line.

## Constraints (the routine's own, not the skill's)

- Prefix the Telegram digest header with `🌙 Overnight dispatch`, so the user can tell at a glance
  which run sent it.
- This is the only dispatch of the day. It picks up everything approved since the last run, and
  whatever the gate holds back waits until tomorrow — there is no second pass to catch leftovers.
