# launchd-runtime

macOS LaunchAgent + claude-cli runtime for the agentic routines in this repo. This is what fires `morning-triage`, `dispatch-tasks`, `daily-summary`, etc. on schedule, **without depending on Claude Desktop being open**.

If you're reading this for the first time, the [Why](#why) section explains what problem this solves. If you just want to install or change something, jump to [Quick start](#quick-start).

---

## Why

Claude Desktop's built-in scheduled tasks have two architectural problems that make them unreliable for unattended overnight automation:

1. **Permission IPC stream breaks randomly mid-run.** Tool permission requests inside scheduled-task sessions go over an IPC channel that frequently closes before the response is received. We saw this with the error: `Tool permission request failed: Error: Tool permission stream closed before response received`. When it triggers, that session aborts and (worse) subsequent scheduled tasks for the day get skipped. Verified across 4 transcripts on 2026-05-09 — non-deterministic, no clear pattern.

2. **`wakeScheduler` feature is unavailable** in this Claude Desktop build. Scheduled tasks only fire when Claude Desktop is *already open*. If the Mac wakes overnight via pmset and Claude Desktop is closed, no tasks fire.

This runtime sidesteps both:

- **launchd** (macOS's native scheduler) fires shell scripts at calendar times. It runs as long as the user is logged in, regardless of which apps are open. Reliable.
- **`claude` CLI** (the binary bundled inside Claude Desktop, exposed via the `claude-cli` wrapper) runs prompts to completion in a fresh process with `--dangerously-skip-permissions`. No IPC permission stream is ever involved — the deny rules in `~/.claude/settings.json` are still loaded for safety, they just take effect at the rule layer instead of the UI layer.

We tested both paths on 2026-05-09 — pure-bash launchd→Telegram and full launchd→claude-cli→skill→Telegram — both fired exactly on schedule with zero permission errors.

---

## Architecture

```
~/Library/LaunchAgents/com.agentic-skills.routines.<name>.plist
       │
       ▼ (calendar-time trigger)
~/.agentic-skills/routines/_run.sh <routine-name>
       │
       ▼
   reads ~/.agentic-skills/routines/<name>.prompt.md
       │
       ▼
   invokes ~/.agentic-skills/claude-cli -p "<prompt>" --dangerously-skip-permissions \
                                                 --settings "<headless deny-net>"
       │
       ▼
   logs everything to ~/.agentic-skills/routines/logs/<name>-YYYY-MM-DD.log
       │
       ▼
   on non-zero exit: sends Telegram alert with last 30 lines of log
```

Source of truth = this repo. The `install.sh` script symlinks scripts and prompts from the repo into their runtime locations, and copies plist files into `~/Library/LaunchAgents/` (then bootstraps them with `launchctl`).

---

## Files in this directory

```
launchd-runtime/
├── README.md                         # this file
├── repos.conf.example                # every cap, with an example roster; copy to repos.conf
├── machines.conf.example             # the machine map bin/machine reads; copy to machines.conf
├── secrets.env.example               # Telegram and API credentials; copy to secrets.env, chmod 600
│                                     # (repos.conf, machines.conf and secrets.env are git-ignored)
├── bin/                              # the runner, the installer, the deny-net, the review lane and
│                                     # the status and metrics tools; COMMANDS.md lists each one
├── system/                           # system-level (LaunchDaemon, requires sudo, run once)
│   ├── com.agentic-skills.wakeschedule.plist  # daemon plist deployed to /Library/LaunchDaemons/
│   ├── refresh-wake-schedule.sh       # script the daemon runs (deployed to ~/.agentic-skills/)
│   └── install.sh                     # sudo-required installer for the daemon
├── prompts/                          # one <routine>.md per scheduled routine
├── tests/                            # unit and static suites, mocks, the reviewer eval
└── agents/
    └── com.agentic-skills.routines.<name>.plist   # one template per routine; matches prompts/<name>.md
```

### Where things land on disk after `install.sh`

| Repo location | Runtime location | Symlink? |
|---|---|---|
| `bin/claude-cli` | `~/.agentic-skills/claude-cli` | symlink |
| `bin/_run.sh` | `~/.agentic-skills/routines/_run.sh` | symlink |
| `bin/routines-status` | `~/.agentic-skills/routines-status` | symlink |
| `prompts/<name>.md` | `~/.agentic-skills/routines/<name>.prompt.md` | symlink |
| `agents/<name>.plist` | `~/Library/LaunchAgents/<name>.plist` | **copy** (launchctl is finicky with symlinks) |

Logs are NOT in the repo — they live at `~/.agentic-skills/routines/logs/` and are not committed.

---

## Quick start

### First-time install

```bash
# 0. Create this machine's local files from the tracked examples, then edit them.
cp launchd-runtime/repos.conf.example    launchd-runtime/repos.conf      # your repos and caps
cp launchd-runtime/machines.conf.example launchd-runtime/machines.conf   # only if you use bin/machine
cp launchd-runtime/secrets.env.example   launchd-runtime/secrets.env && chmod 600 launchd-runtime/secrets.env

# 1. The Claude CLI must be authenticated. One time only.
launchd-runtime/bin/claude-cli /login
# (browser opens, sign in with your Anthropic account, close the tab)

# 2. Run the user-level installer (no sudo).
bash launchd-runtime/bin/install.sh

# 3. Run the system-level installer (sudo required, ONCE).
#    Installs /Library/LaunchDaemons/com.agentic-skills.wakeschedule.plist and the
#    refresh-wake-schedule.sh helper. This is what keeps the Mac awake at
#    03:55, 08:55, 17:55 so user-level routines fire reliably.
sudo bash launchd-runtime/system/install.sh

# 4. Verify the agents are loaded.
launchctl list | grep com.agentic-skills.routines
sudo launchctl print system/com.agentic-skills.wakeschedule | head -10

# 5. Manually trigger a routine to confirm everything works end-to-end.
~/.agentic-skills/routines/_run.sh wake-status-digest
# Expect a Telegram message within ~30 seconds.

# 6. Check status.
routines-status
wake-schedule status
```

### After editing a script

If you edit `bin/_run.sh` or `bin/claude-cli`, **changes are immediate** — they're symlinked from the repo.

If you edit a prompt at `prompts/<name>.md`, **changes are immediate** — same reason.

### After editing or adding a plist

Plists are copies, not symlinks. Re-run the installer to redeploy them:

```bash
bash launchd-runtime/bin/install.sh
```

This is idempotent — it bootouts each existing agent and bootstraps it fresh, picking up plist changes.

---

## Adding a new routine

1. Add `prompts/<new-name>.md` describing what the routine does. Follow the same structure as the existing files (preface explaining headless context, task description, constraints).
2. Add `agents/com.agentic-skills.routines.<new-name>.plist` mirroring an existing plist. Set the `StartCalendarInterval` `Hour` and `Minute` to your desired fire time (24-hour, local timezone).
3. Run `bash bin/install.sh` to deploy.
4. Manually trigger to test: `~/.agentic-skills/routines/_run.sh <new-name>`.
5. Commit prompt + plist to the repo.

## Per-routine settings

Each routine's behaviour is tuned by `EnvironmentVariables` in its plist, read
by `bin/_run.sh`. All are optional; the defaults are what every routine gets
today. After editing a plist, run `bash bin/install.sh` — the plists are
copied, not symlinked, so an edit in the repo does nothing until you reinstall.

| Variable | Default | What it does |
| --- | --- | --- |
| `ROUTINE_TIMEOUT_SECONDS` | `1800` | Wall-clock budget. The watchdog kills the process tree past it. Bounds are asserted per routine by `tests/static/test_plists.sh`. |
| `ROUTINE_MODEL` | `claude-opus-4-8` | Pins the model, instead of inheriting whatever was last set interactively. An unrecognised id fails loudly. |
| `ROUTINE_MAX_BUDGET_USD` | `5.00` | Per-run spend cap. A runaway guard, not a tight budget. `dispatch-tasks-night` raises it to `15.00` — five tasks at the measured p95 of $2.51 do not fit the default. |
| `ROUTINE_EFFORT` | `high` | Reasoning effort for the wrapper turn: `low`, `medium`, `high`, `xhigh` or `max`. A skill's own `effort:` frontmatter wins once it loads, so this is the fallback rather than the setting. Anything else aborts the run with exit 6 — the CLI itself would only warn and then run at its default. |
| `ROUTINE_CAPTURE_JSON` | unset (off) in the runner; every shipped routine plist sets it | Records what the run cost and what its deny-net refused. See below. |

### Recording what a run costs

With `ROUTINE_CAPTURE_JSON` set to anything non-empty, the runner asks the CLI
for `--output-format json` and keeps the result: a per-run sidecar at
`metrics/<routine>-<date>-<epoch>.json`, one appended row in
`metrics/runs.jsonl`, and a `ROUTINE COST:` line in the log beside
`ROUTINE END`. Each denial the envelope names is written to
`metrics/denials.jsonl`, and a successful run's final text is copied into the
log, where it would otherwise have streamed. Without capture the CLI still
produces all of that and the runner throws it away, so the pipeline has no
record of its own spend or of the rules it keeps running into.

The runner defaults to **off** because `bin/_run.sh` is symlinked by
`install.sh` — the repo file is the live runner for every routine the moment it
is saved. It was proven on `wake-status-digest` first, and since 2026-09-13
every shipped routine plist sets it: with two of nine capturing, the spend line
and the denial ledger each described two routines as the whole pipeline.
`tests/static/test_plists.sh` fails a routine plist that does not set it. The
plists are copied into `~/Library/LaunchAgents`, so a change to one reaches the
pipeline host only after `bash bin/install.sh` there.

A failed run is still costed, and its reason is still written to the log — the
capture only ever adds to the log, because the failure Telegram tails it and
`daily-review-nudge` reads its own previous logs.

## Removing a routine

```bash
UID_NUM=$(id -u)
NAME="com.agentic-skills.routines.dispatch-tasks-night"
launchctl bootout gui/$UID_NUM/$NAME
rm ~/Library/LaunchAgents/$NAME.plist
rm launchd-runtime/agents/$NAME.plist
rm launchd-runtime/prompts/dispatch-tasks-night.md
```

The symlink at `~/.agentic-skills/routines/dispatch-tasks-night.prompt.md` will become a dangling link until you re-run `install.sh`, but the routine won't fire because the LaunchAgent is gone.

---

## Daily commands you'll actually use

```bash
# What's open right now across all tracked repos
issues-status

# Filter to one label, e.g. show what's awaiting human approval
issues-status -l proposed

# Filter to one label, e.g. show what the agent will dispatch next
issues-status -l approved

# One workspace
issues-status -w starbonk           # or gametwo | personal

# One repo, only PRs
issues-status -r acme/club_app --prs

# Machine-readable
issues-status --json | jq .

# All flags
issues-status --help
```

The repo list comes from `launchd-runtime/repos.conf`, this machine's local copy of `repos.conf.example`. Edit it to add or remove tracked projects.

## Verifying routines are healthy

```bash
# Quick: who ran when, did they exit clean
routines-status

# Detailed: full transcript of the most recent run
routines-status -v dispatch-tasks-night

# Are all 6 agents loaded?
launchctl list | grep com.agentic-skills.routines | wc -l    # should be 11

# What's the next fire time of one specific agent?
launchctl print gui/$(id -u)/com.agentic-skills.routines.morning-triage 2>&1 | grep -iE 'next|state'

# Is Telegram delivery working? Manually trigger a routine.
~/.agentic-skills/routines/_run.sh wake-status-digest
```

---

## Troubleshooting

### A routine didn't run

Check three things in order:

1. **Is the agent loaded?**
   ```bash
   launchctl list | grep com.agentic-skills.routines.<name>
   ```
   If empty, the LaunchAgent isn't bootstrapped. Re-run `install.sh`.

2. **Did launchd try to fire it?**
   ```bash
   log show --predicate 'subsystem == "com.apple.xpc.launchd"' --last 24h | grep com.agentic-skills.routines.<name>
   ```
   Look for "spawned" or "exited" lines. If nothing, the Mac was likely asleep at the scheduled time. Check the wake schedule status (`pmset -g sched`) and the wake-schedule daemon log (`tail /var/log/wake-schedule.log`).

3. **Did the script run but fail?**
   ```bash
   routines-status -v <name>
   cat ~/.agentic-skills/routines/logs/launchd-<name>.stderr
   ```

### A routine ran but no Telegram arrived

- Check the routine's log — did it actually attempt the curl?
- Verify Telegram creds in `~/.claude/settings.json` `.env.TELEGRAM_BOT_TOKEN` and `.env.TELEGRAM_CHAT_ID`.
- Test manually: `curl -s "https://api.telegram.org/bot${TOKEN}/getMe"` should return your bot's identity.

### `claude-cli` says "Not logged in"

Run `claude-cli /login` interactively. Auth tokens persist after that.

### Permission errors despite `--dangerously-skip-permissions`

Deny rules hold in every mode, that flag included, and a headless run is covered by two layers of them:

1. `~/.claude/settings.json` — the machine-wide deny list, loaded as usual.
2. `HEADLESS_DENY` in `bin/_run.sh`, passed as `--settings` on every routine invocation. Scheduled-run only; interactive sessions never see it.

The second layer exists because a routine has no human to instruct it, no auto-mode classifier on this host, and it reads issue and comment bodies out of **public** repos. Prompt text is untrusted input, so anything a crafted issue could talk a worker into has to be refused at the rule layer. Three families, each with its reasoning written out above the rules in `_run.sh`:

| Family | Refuses | Why |
| --- | --- | --- |
| no ready / merge | `gh pr merge`, `gh pr ready`, and every `gh api` route to the same operations (four GraphQL mutations, the REST merge route, and a mutation loaded from a file via `--input` or `@`) | BASELINE.md, "Merging and Marking PRs Ready" — a scheduled run has no user to authorise either |
| nothing irreversible | force-push, branch delete, `git reset --hard`, `git clean`, `gh issue/repo/release delete`, `gh pr close`, `gh api` DELETE | destroys work no reflog brings back, a human's included |
| no egress | `curl`, `wget`, `nc`, `ncat`, `ssh`, `scp`, `gh auth token`, `gh gist`, `printenv`, `env`, and the `WebFetch` / `WebSearch` tools | the CLI inherits `CLAUDE_CODE_OAUTH_TOKEN` and `TELEGRAM_BOT_TOKEN`; one outbound request is the whole attack |

Telegram still works: `bin/telegram-send` is Python + `urllib`, not `curl`, and this runner's own alert `curl`s are shell, not agent tool calls.

One gap is documented rather than fixed: the short delete refspec `git push origin :old-branch` cannot be expressed as a rule, because a pattern ending in `:*` is read as the trailing-wildcard idiom and loses its colon. `git push --delete` and `-d` cover the porcelain spelling of the same deletion, and `git push * :refs/*` covers the fully-qualified refspec.

To debug a block:

```bash
# What rules apply to a specific command?
jq -r '.permissions.deny[]' ~/.claude/settings.json | grep -i <pattern>
jq -r '.permissions.allow[]' ~/.claude/settings.json | grep -i <pattern>

# ...and the headless layer on top of it
sed -n '/^HEADLESS_DENY=/,/^]}}.$/p' bin/_run.sh
```

If a routine legitimately needs one of these, widen the rule in `_run.sh` and extend `tests/unit/test_run_sh.sh` in the same commit — the deny list is asserted there, rule by rule.

### Mac was asleep at the scheduled time

LaunchAgents only fire while the user is logged in AND the Mac is awake. The wake-schedule daemon (`system/com.agentic-skills.wakeschedule.plist`, deployed to `/Library/LaunchDaemons/`) maintains a pmset wake queue at `03:55 / 08:55 / 17:55` so the Mac is up before each routine batch. The daemon refreshes the queue daily at noon and at boot.

```bash
wake-schedule status                                       # pause state + queued events
sudo wake-schedule refresh                                 # force-rebuild the queue
sudo cat /var/log/wake-schedule.log                        # daemon log (timestamped)
sudo launchctl print system/com.agentic-skills.wakeschedule        # daemon health
sudo launchctl kickstart -k system/com.agentic-skills.wakeschedule # fire daemon now
```

The script schedules **3 days of events** (today + tomorrow + day after), not 7. Why: macOS's pmset queue gets opportunistically pruned over time when many events are stacked, and we observed events for days 4-7 silently disappearing. With daily refreshes, 3 days of buffer is plenty.

---

## Schedule (current — consolidated overnight window)

| Time (local) | Routine | What it does |
|---|---|---|
| 04:00 | `wake-status-digest` | Confirms the routine system itself is healthy (yesterday's runs, queued wakes) |
| 04:02 | `morning-triage` | Classifies all repos' open issues/PRs by urgency |
| 04:05 | `morning-proposals` | Generates 3-5 `proposed` issues per repo for human approval |
| 04:10 | `dispatch-tasks-night` | Overnight dispatch — approved issues become draft PRs |
| 05:00 | `pr-review-night` | Reviews open agent PRs |
| 06:05 | `pr-iterate-night` | Workers answer the review findings |
| 07:00 | `merge-lane-night` | The merge-lane script merges what passed, for opted-in repos |
| Mon/Wed/Fri 09:00 | `playtest-build-night` | Builds the game for the owner to play |
| Mon 04:20 | `skill-assess-weekly` | Audits this repo's own skills; files `skill-maintenance` issues only when something needs attention |
| 18:05 | `daily-summary-routine` | Evening retrospective: shipped, awaiting review, blocked |
| 19:00 | `daily-review-nudge` | Reminds the owner what is waiting on them |

The wake-schedule daemon ensures the Mac is awake at 03:55 and 17:55 — covers the overnight batch and the evening daily-summary.

**Why everything overnight?** The docked-lid-closed Mac was unreliable during morning monitor-DPMS transitions. When the external display went to sleep, some docks briefly lost the "display detected" signal, triggering macOS clamshell-sleep (which `caffeinate -i` can't prevent). At 04:00, the display has been off for hours, the dock signal is stable, and the API stream stays healthy. The morning dispatch (`dispatch-tasks-routine` at 10:09) was retired on 2026-05-12 after consolidating everything into the 04:00 window.

---

## Migration history (2026-05-09)

We migrated to this runtime after three days of Claude Desktop scheduled tasks failing silently. The diagnostic path:

1. Symptoms: routines didn't fire, no Telegrams. Sometimes one task fired, others on the same day were skipped.
2. Hypothesis 1 — Mac sleep: bumped `pmset -c sleep 1 → 20` to give post-wake routines time to fire. Didn't help.
3. Hypothesis 2 — Claude Desktop must be open: confirmed via `wakeScheduler: unavailable` in the desktop's feature flags. True but not the whole story.
4. Hypothesis 3 — permission IPC bug: confirmed by inspecting 4 failed scheduled-task transcripts; all hit `Tool permission stream closed before response received` at random points (sub-skill invocation, second Bash, third Bash). No deny rule pattern matched.
5. Decision: migrate to launchd + claude-cli. Tested two routines on 2026-05-09 21:47 and 21:51 — both fired and delivered Telegrams. Migration completed same evening.

Old Claude Desktop scheduled tasks are kept disabled (not deleted) at `~/.claude/scheduled-tasks/` for forensic reference. They can be re-enabled if Anthropic ever ships a fix for the IPC stream issue.
