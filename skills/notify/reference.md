# Notify — reference

Loaded on demand only. SKILL.md points here when Telegram credentials are missing, when a send fails, or when someone proposes changing the recipe.

## Credential setup

Telegram credentials not configured. To set them up:

1. Open Telegram and search for @BotFather
2. Send /newbot — follow the prompts, copy the token it gives you
3. Send /start to your new bot in a private chat
4. Visit: https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates
   Look for "chat": {"id": <number>} — that number is your TELEGRAM_CHAT_ID
5. Add both to ~/.claude/settings.json:
   {
     "env": {
       "TELEGRAM_BOT_TOKEN": "your-token-here",
       "TELEGRAM_CHAT_ID": "your-chat-id-here"
     }
   }

Do not proceed until both are set.

## Why this send pattern

- **No `jq` in the hot path.** jq's interaction with shell-substituted unicode is what produced the duplicate-send bug (2026-05-10): emojis caused `jq` parse errors in some attempts but `curl` had already fired in others — silent duplicate sends. `telegram-send` builds the JSON payload in Python with explicit UTF-8, which handles emojis cleanly the first time, every time.
- **Message goes through a file, not a shell variable.** Eliminates every quoting / heredoc edge case, even with emojis, multiline content, or backticks in the message.
- **Literal /tmp path, single unchained command.** The headless permission profile denies command-substitution assignments (`VAR=$(...)`), `export`, `mktemp`, python3-heredocs, and any `&&`/`;` chain that contains a denied form — the whole compound gets denied. `cat > /tmp/<literal-name> << 'EOF'` and a single unchained `python3 /abs/path/script.py arg` are the proven-allowed forms.
- **No cleanup.** `rm` is guarded, not blanket-denied: the blanket `Bash(rm:*)` deny was replaced by 28 targeted denies plus a PreToolUse hook (`permissions/README.md`). We still never `rm` and never chain — a chained `rm` used to take the whole send command down with it — and the message file is overwritten in place on the next run.
- **One request per invocation, explicit exit code.** The sender never retries on its own and exits nonzero on failure, so the caller can check the exit code reliably; no "exit looked clean but the request never fired" ambiguity. Retries on perceived failure are how duplicates happen: the request often *did* go through, and the local error was a parse problem on the response.

## Reading a failed send

The sender exits nonzero in four distinguishable ways, and none of them is a reason to run it again:

- `exit 2`, `TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be set` — the credentials never reached the process. Under a routine that means `_run.sh` could not read them out of `~/.claude/settings.json`; interactively it means the shell has no env for them.
- `exit 2`, `cannot read message file` / `message file is empty` — Step 1 did not run, or its heredoc closed early. Re-write the file; do not send an empty one.
- `exit 1`, `HTTP <code>` — the API refused the request itself. A 401 is a bad token, a 429 is rate limiting; both are for the human, not for a retry.
- `exit 1`, `Telegram rejected the message: <description>` — a 200 whose body carried `ok: false`. This is the one that looks like success from the outside: the request completed. `chat not found` means `TELEGRAM_CHAT_ID` is wrong or the bot was never `/start`ed; `bot was blocked by the user` means exactly that.

Only the last two mean the request reached Telegram, and in neither case was the message delivered — so no ledger row is written for any of the four. A row in `sends.jsonl` means Telegram answered `ok: true`, and nothing else does.

## What the ledger records

Until 2026-09-03 a send left no durable record: the only evidence that a routine had told the human about a PR was the human's Telegram scrollback, so "did the 04:10 run notify me about #12?" could not be answered afterwards.

Every accepted send — one Telegram answered `ok: true`, not merely one that got a 200 — now appends one JSON line to `${METRICS_DIR:-$HOME/.agentic-skills/routines/metrics}/sends.jsonl`:

```json
{"ts": "2026-09-03T18:05:11+02:00", "routine": "dispatch-tasks", "run_id": "dispatch-tasks-1757000000-4711",
 "message_id": 8842, "chars": 412, "sha256": "…", "refs": ["amarcu/agentic-pipeline#15"]}
```

- `routine` and `run_id` come from the `ROUTINE` / `ROUTINE_RUN_ID` that `_run.sh` exports, so a row joins `runs.jsonl` on `run_id`. An interactive send records `routine: "interactive"` and `run_id: null`.
- `refs` holds every `owner/repo#N` the message named, deduped and in message order, extracted from both `github.com/<owner>/<repo>/(issues|pull)/<n>` URLs and bare `owner/repo#N` mentions — so a row joins the GitHub side too.
- `sha256` is over the sent text; the text itself is not stored, because the digest is already in the routine log.
- The write is best-effort. A failure warns on stderr and leaves the exit code alone: the message has already been delivered, and a nonzero exit there is exactly what would make a caller retry a delivered send.

Covered by `launchd-runtime/tests/unit/test_telegram_send.sh` against the mock Telegram server.
