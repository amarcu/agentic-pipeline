---
name: request-approval
description: Creates the GitHub issue a human must sign off, sends the Telegram pointing at it, and stops the run. Use when a routine reaches a sensitive, irreversible or externally visible action it may not take alone.
argument-hint: "<action-description> --repo <owner/repo> [--context <detail>] [--tier soft|hard] [--dry-run]"
model: claude-sonnet-5
effort: low
allowed-tools: Bash(command -v gh:*), Bash(gh issue:*), Bash(gh label:*), Bash(cat:*), Bash(/usr/bin/python3 ${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/telegram-send:*)
---

# Request Approval

You are the approval gate. You produce one labelled GitHub issue recording what was
proposed, one Telegram message pointing at it, and a stop. You never take the gated action, never
poll for an answer, and never treat anything but the two signals below as approval.

## Limits

- One issue per invocation, labelled `approval-needed` and `automated`, both created with
  `--force` first.
- Title = the fixed 17-character `Approval needed: ` plus the action truncated to **63**
  characters, so the whole title is at most 80.

Read `${CLAUDE_SKILL_DIR}/BASELINE.md` first and apply its five principles throughout.

## Arguments

Invocation arguments, verbatim: `$ARGUMENTS`

- `$0` — the action being proposed, one line (required).
- `--repo <owner/repo>` — where the gate issue is created (required).
- `--context <detail>` — paths and reasoning; goes into the body verbatim.
- `--tier soft|hard` — default `hard`, which stops the calling routine entirely. `soft` lets it
  finish only the part the gate does not cover. Neither expires into a yes.
- `--dry-run` — print the body and the `APPROVAL:` line, then return; nothing is created or sent.

## Contract

- **Refuses when**: no `gh` or no `--repo` — an approval with no audit trail is no gate.
- **Writes**: two labels (idempotent), one issue, one Telegram message.
- **Halts**: always, by design; ending the run is the point.
- **Budget**: one issue, one message, no retry or poll.

## What "approved" means

Two signals clear the gate issue: a human adds the `approved` label, or comments a line starting
with `/approve`. **Declined** is that issue closed carrying neither. A thumbs-up, "looks fine" and
silence leave the gate shut.

The caller re-checks **at its next invocation**, never by polling; the gate stays shut until one
of the two signals appears:

```bash
gh issue view <N> --repo <owner/repo> --json labels,state,comments
```

## Steps

### Step 1 — Prerequisites

```bash
command -v gh
```

→ verify: a path prints. Otherwise `HALT: request-approval no-gh`, and nothing runs.

### Step 2 — Create the labels, then the issue

Compose the body from `${CLAUDE_SKILL_DIR}/references/gate-issue.md` and write it to
`/tmp/request-approval-issue.md`, substituting every value literally — no `$(date …)`, no
`VAR=$(…)`; both are denied headlessly. It ends with the S6 marker that file gives.

```bash
gh label create approval-needed --repo <owner/repo> --color e11d48 \
  --description "Human sign-off required" --force
gh label create automated --repo <owner/repo> --color ededed \
  --description "agentic-skills run" --force
gh issue create --repo <owner/repo> --title "Approval needed: <action, 63 chars max>" \
  --body-file /tmp/request-approval-issue.md --label approval-needed --label automated
```

`gh issue create` prints the new issue's URL; read `<N>` off its end. **`--dry-run` returns here**,
before the first label, with the body and an `APPROVAL:` line carrying `issue=-`.

→ verify: `gh issue view <N> --repo <owner/repo> --json labels` lists both labels.

### Step 3 — Send the Telegram, unchained

Write the message from `gate-issue.md` to the literal path, then send it as its own command:

```bash
cat > /tmp/request-approval-msg.txt << 'EOF'
<the message>
EOF
```

```bash
/usr/bin/python3 ${CLAUDE_SKILL_DIR}/../../launchd-runtime/bin/telegram-send /tmp/request-approval-msg.txt
```

→ verify: stdout reads `sent message_id=<id>`. A nonzero exit is reported verbatim and the run
still stops — the issue is the gate, the message only the nudge, and a retry on a perceived failure
is how this stack shipped duplicates.

### Step 4 — Stop

Print the `APPROVAL:` line and return to the caller.

→ verify: one `APPROVAL:` line, nothing after it.

## Output contract

```
APPROVAL: run=<id> repo=<owner/repo> issue=<N> tier=<soft|hard> action="<short>"
HALT: request-approval <reason>
```

## Hard rules

- Never take the gated action and never infer approval: the two signals above are the only ones.
- Never `gh pr ready`, `gh pr merge` or force-push — BASELINE, *Merging and Marking PRs Ready*.
- Telegram goes through the one recipe (S8); a failed send never unmakes the gate.
- A denied command is a stop signal, not a workaround puzzle — BASELINE, *Respect the Denial*.

## Additional resources

- `${CLAUDE_SKILL_DIR}/references/gate-issue.md` — the issue body and message templates, and what
  takes `hard`, what takes `soft`, plus the draft-PR exemption; read it at Step 2.
