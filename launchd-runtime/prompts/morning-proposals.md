# Morning proposals routine (launchd-driven)

You are running headlessly via the Claude Code CLI, fired by a macOS LaunchAgent. The user is not present. There is no UI and no human to approve permission prompts — `--dangerously-skip-permissions` is on, but the deny rules in `~/.claude/settings.json` still apply.

## Step 0 — backlog pre-check (BEFORE any skill invocation or subagent fan-out)

The repo list lives in `$AGENTIC_SKILLS_ROOT/launchd-runtime/repos.conf` — the single source of truth. Do not hunt the filesystem for a repo list.

Source `repos.conf` and iterate **`ACTIVE_REPOS` only** — dormant repos are tracked for reporting and must never be proposed against.

Run ONE `gh` loop over the active repos, counting each repo's open issues labeled `proposed` that do NOT also carry `approved`:

```bash
gh issue list --repo "$r" --state open --label proposed --json labels \
  --jq '[.[] | select((.labels | map(.name) | index("approved")) | not)] | length'
```

Sum those counts. If the sum is at or above `PROPOSED_BACKLOG_MAX` (from repos.conf), the human's single review sitting is already full: send the one Telegram described below, carrying the total and the per-repo breakdown, then halt — no subagents, exit 0. This global gate outranks everything below, because the constraint being protected is one person's 30-60 minutes, not any individual repo's backlog.

Keep the per-repo counts. They are the "before" figures in the end-of-run digest.

**Per-repo saturation is not decided here.** `propose-tasks` owns that threshold and applies it itself, printing `HALT: <owner/repo> | saturated (<n> unapproved proposals)`. Collect those lines rather than pre-empting them — one number in one file is the whole point.

## Task

Run `/propose-tasks --repo <R>` for each **active** repo, in `repos.conf` priority order, and capture its stdout. The skill emits one line per issue it creates:

```
PROPOSED: <owner/repo>#<N> | shape:chore | size:<XS|S|M> | <title>
```

and exactly one `HALT: <owner/repo> | <reason>` when it creates nothing.

Do not pass `--notify`. This routine owns the send; the skill's per-repo message was removed precisely so one morning cannot produce seven of them.

Stop as soon as the running total of unapproved proposals — the Step 0 sum plus every `PROPOSED:` line so far — would reach `PROPOSED_BACKLOG_MAX`, even if active repos remain unvisited. Repos skipped this way get first refusal tomorrow; name them in the digest so the rotation is visible.

## The one Telegram, at the end of the run

Send **at most one** message, when the run ends — whether it ended by visiting every active repo or by stopping at `PROPOSED_BACKLOG_MAX` with repos still unvisited — and only when there is something the human has to act on:

- **Send** when at least one issue was created, or at least one repo halted `saturated` — a full approval queue is backpressure the human clears, and it is the only halt reason that does not resolve itself.
- **Send nothing** when every repo was quiet for a normal reason: `direction is human-led`, `no candidate above the bar`, `no CLAUDE.md`. A no-op morning leaves no trace (BASELINE Principle 5); the routine log already carries every `HALT:` line for the record.

Write the digest to a literal path and send it as its own unchained command:

```bash
cat > /tmp/morning-proposals-digest.txt << 'EOF'
<digest>
EOF
```

```bash
/usr/bin/python3 $AGENTIC_SKILLS_ROOT/launchd-runtime/bin/telegram-send /tmp/morning-proposals-digest.txt
```

The recipe and every constraint on it — the literal path, no `mktemp`, no `VAR=$(...)`, no chaining, no cleanup, and never a retry on a perceived failure — live in `$AGENTIC_SKILLS_ROOT/skills/notify/SKILL.md` and nowhere else.

Shape it for a phone: the count and the total pending queue first, then one line per created issue (number, title, size, URL), then one line naming the repos that were saturated and the repos left unvisited because the cap fired. Under about 12 lines.

## Constraints (do not deviate)

- The repo list comes from `ACTIVE_REPOS` in `repos.conf` (Step 0) — do not invent new repos and do not fall back to `REPOS_BY_PRIORITY`, which includes dormant repos.
- Do not invoke any other skills beyond `/propose-tasks`.
- Do not modify code or open PRs. This routine only creates `proposed` issues, through the skill.
- Never restate a cap. Name `PROPOSED_BACKLOG_MAX`; read its value from `repos.conf`.
- If a repo errors, log it and continue to the next; count it as `(error)` in the digest.
- For a repo whose issues come from `plan-features`, `propose-tasks` prints exactly `HALT: <owner/repo> | direction is human-led (agent/FOCUS.md present) — use /plan-features` and exits 0. That is the expected outcome: match it on the stable prefix `HALT: <owner/repo> | direction is human-led`, count it as "nothing proposed" for that repo, and never report it as a failure.
