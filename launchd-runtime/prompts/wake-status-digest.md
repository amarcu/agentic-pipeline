# Wake-schedule status digest (launchd-driven, 04:00)

You are running headlessly via the Claude Code CLI, fired by a macOS LaunchAgent. The user is not present. There is no UI and no human to approve permission prompts — `--dangerously-skip-permissions` is on, but the deny rules in `~/.claude/settings.json` still apply.

## Task

Send a one-message Telegram digest summarising the health of the wake/routines infrastructure. This runs first thing in the morning so any silent failures from the previous 24 hours are surfaced immediately.

## Steps

1. **Pause state** — read `$HOME/.wake-schedule.state`. If present, report the contents (`forever` / `YYYY-MM-DD`). If absent, report "active".

2. **Queued wake events** — `pmset -g sched` and report the count of `wake at` lines AND the next 3 upcoming wake times.

3. **Daemon status** — `sudo launchctl print system/com.agentic-skills.wakeschedule 2>/dev/null` would need sudo; instead just check that the plist exists at `/Library/LaunchDaemons/com.agentic-skills.wakeschedule.plist` and that the last log line in `/var/log/wake-schedule.log` is recent (within last 36 hours).

4. **Routine health** — routine logs live in `$HOME/.agentic-skills/routines/logs/`, named `<routine>-YYYY-MM-DD.log`. Do NOT list the whole directory — glob only today's and yesterday's files (e.g. `ls $HOME/.agentic-skills/routines/logs/*-<today>.log $HOME/.agentic-skills/routines/logs/*-<yesterday>.log` with literal dates). The expected roster is these nine daily routines — one missing from BOTH days' globs is a silent failure, not a healthy absence: `wake-status-digest`, `morning-triage`, `morning-proposals`, `dispatch-tasks-night`, `pr-review-night`, `pr-iterate-night`, `daily-summary-routine`, `daily-review-nudge`, `merge-lane-night`. `skill-assess-weekly` is also in the roster but fires only on Mondays at 04:20: report it as INFO ("weekly, next Monday") on any day it was not due, and treat its absence as a failure only when yesterday was a Monday. `playtest-build-night` is in the roster too but fires only on Monday, Wednesday and Friday at 09:00: report it as INFO ("next build Mon/Wed/Fri") on any other day, and treat its absence as a failure only when yesterday was one of those days. For each routine in the roster:
   - Did it run yesterday? (`grep "ROUTINE END" "<routine>-<YYYY-MM-DD-of-yesterday>.log"` should match)
   - Did it exit 0?
   - List any routine that DIDN'T run yesterday (silent failure) or exited non-zero.

5. **Compose Telegram message**:

   ```
   ☀️ Morning Status — <Day, Mon D>

   Wake schedule:    active | paused until X
   Queued wakes:     N events; next: HH:MM, HH:MM, HH:MM
   Daemon log:       last entry Xh ago

   Routines yesterday:
     ✅ wake-status-digest      09:06  exit=0  12s
     ✅ morning-triage          09:13  exit=0  87s
     ⚠️ daily-summary-routine   18:09  exit=2  44s
     ❌ dispatch-tasks-night    DID NOT RUN

   Issues: 1 routine failed, 1 didn't fire — investigate.
   ```

6. **Send** — write the digest to a literal path:

   ```bash
   cat > /tmp/wake-status-digest.txt << 'EOF'
   <digest text>
   EOF
   ```

   then send it as a single unchained command (the script reads `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` from the environment, prints the message_id, exits non-zero on failure):

   ```bash
   /usr/bin/python3 $AGENTIC_SKILLS_ROOT/launchd-runtime/bin/telegram-send /tmp/wake-status-digest.txt
   ```

   The recipe and every constraint on it — the literal path, no chaining, no cleanup, and never a retry on perceived failure — live in `$AGENTIC_SKILLS_ROOT/skills/notify/SKILL.md` and nowhere else.

## Constraints

- Read-only — no mutations anywhere.
- One Telegram per run, every morning, regardless of state. Even if everything is healthy, send the digest. (The point is to confirm the routine itself fired.)
- If a routine "didn't run yesterday" but it's an optional / paused one, mark it INFO not ERROR.
- Exit 0 on success; non-zero only if Telegram send fails.
