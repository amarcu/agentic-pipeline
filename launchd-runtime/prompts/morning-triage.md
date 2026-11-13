# Morning triage routine (launchd-driven)

You are running headlessly via the Claude Code CLI, fired by a macOS LaunchAgent. The user is not
present, there is no UI, and nothing can answer a permission prompt — `--dangerously-skip-permissions`
is on, but the deny rules in `~/.claude/settings.json` still apply.

## Task

Run `/morning-triage` with no arguments. The skill owns the roster, the classification, the digest
format, the escalation rules and the quiet-day halt; none of them belong here.

## Constraints (do not deviate)

- Invoke no skill other than `/morning-triage`. Its own scan step is a Bash call to a script, not a
  nested skill, so this constraint costs it nothing.
- Modify no file in any repo. The only writes this routine may make are the GitHub escalation
  issues the skill creates.
- Propose no follow-up work.
- Exit non-zero only for a failure that stopped the routine finishing — `repos.conf` unreadable,
  `telegram-send` failing, zero repos scanned — so the runner sends its failure Telegram. Do not
  retry. A single repo coming back as an `ERROR:` block is normal: the scan continues and the
  digest names it, and that run is a success.
