---
name: notify
description: Owns the stack's one Telegram send recipe and its ledger row. Use when a skill must tell the human something — scheduled skills run the sender and cite this file; coding skills invoke this skill.
argument-hint: "<message> [--dry-run]"
allowed-tools: Bash(cat > /tmp/notify-message.txt:*), Bash(/usr/bin/python3 ${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/telegram-send:*)
model: claude-sonnet-5
effort: low
---

# Notify

You are the one Telegram path this stack has. You produce one delivered message and the ledger row
the sender writes for it. You never retry, never build a second sender, never write to GitHub.

## Limits

- Telegram's own 4096-character ceiling; truncate with `[truncated]`.
- `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`: the sender checks them, you do not.
- `sends.jsonl` under `METRICS_DIR`: the sender appends it, never you.

Read `${CLAUDE_SKILL_DIR}/BASELINE.md` first and apply its
five principles throughout.

## Arguments

Invocation arguments, verbatim: `$ARGUMENTS`

- `$0` — the message. Plain text: no `parse_mode`, so `<`, `>` and `&` need no escaping.
- `--dry-run` — print the message, return before the send.

## Contract

- **Refuses when**: the message is empty, or the caller's run was a no-op (BASELINE Principle 5).
- **Writes**: one Telegram message and its ledger row.
- **Halts**: the sender exits nonzero — report its stderr verbatim, stop.
- **Budget**: one message per invocation.

## Steps

### Step 1 — Write the message to the literal path

No `mktemp`, no `VAR=$(...)`, no `export` — all three are denied headlessly.

```bash
cat > /tmp/notify-message.txt << 'EOF'
<the message, exactly as it should appear>
EOF
```

→ verify: the file holds what you meant to send. **`--dry-run` returns here.**

### Step 2 — Send it, unchained

No `&&`, no `;` — a compound holding a denied form is denied whole, taking the send with it.

```bash
/usr/bin/python3 ${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/telegram-send /tmp/notify-message.txt
```

→ verify: stdout reads `sent message_id=<id>`. A nonzero exit is a halt, never a retry: retrying
on perceived failure is how this stack shipped duplicates.

## Output contract

```
sent message_id=<id>
HALT: notify <reason>
```

## Hard rules

- This recipe or nothing (S8). Quiet by default — BASELINE Principle 5.
- `rm` is guarded, not blanket-denied; we still never `rm` and never chain, and the message file is
  overwritten in place.
- A denied command is a stop signal — BASELINE, *Respect the Denial*.

## Additional resources

- `${CLAUDE_SKILL_DIR}/reference.md` — credential setup, how to read a failed send, the recipe's
  rationale, the ledger's fields. Read it when a credential is missing, the sender exits nonzero,
  or a change to the recipe is proposed.
