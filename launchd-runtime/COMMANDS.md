# Commands cheat sheet

Quick reference for the CLI tools shipped with `launchd-runtime`. All commands are on your `PATH` after running `install.sh` (symlinks point at the scripts in this repo at `launchd-runtime/bin/`).

For architecture and "why this exists" → see [README.md](./README.md).

---

## `routines-status` — health of the scheduled routines

Shows when each launchd routine last ran, its exit code, and where to find its log.

```bash
routines-status                       # table view of every routine
routines-status -v <routine-name>     # full transcript of one routine's last run
```

**Routines tracked**: `wake-status-digest`, `morning-triage`, `morning-proposals`, `dispatch-tasks-night`, `daily-summary-routine`, `daily-review-nudge`.

**Example output**:
```
ROUTINE                   LAST RUN               EXIT   DUR       LATEST LOG
-------                   --------               ----   ---       ----------
wake-status-digest        2026-05-09 22:27       0      63s       /…/wake-status-digest-2026-05-09.log
morning-triage            (never run)            -      -         -
…
```

**When to use**:
- You suspect a routine didn't fire — check `(never run)` or stale `LAST RUN` timestamps
- You want to see what an overnight dispatch actually did — `routines-status -v dispatch-tasks-night`

---

## `issues-status` — open issues + PRs across all tracked repos

On-demand view of GitHub state across every repo listed in `repos.conf`. Reads via the `gh` CLI; does not modify anything.

### Basic usage

```bash
issues-status                         # everything: issues + PRs, every tracked repo, grouped by workspace
issues-status --help                  # all flags
```

### Filter by label

```bash
issues-status -l approved             # what the autonomous dispatcher will pick up next
issues-status -l proposed             # what's waiting for your sign-off
issues-status -l blocker              # blockers
issues-status -l bug                  # bugs
issues-status -l <any-label>          # any label name
```

### Filter by scope

```bash
issues-status -w starbonk             # one workspace (starbonk | gametwo | personal)
issues-status -r acme/club_app    # one repo
issues-status --issues                # issues only, skip PRs
issues-status --prs                   # PRs only, skip issues
```

### Combine filters

```bash
issues-status -l approved --prs       # PRs that are merge-ready
issues-status -w personal -l proposed # what needs my approval in personal sites
issues-status -r acme/club-site --issues
```

### Machine-readable output

```bash
issues-status --json | jq .
issues-status --json | jq '."Personal Sites"."acme/club-site".issues[].title'
```

**Example output**:
```
  acme/club-site
    📋 #9    Add frontend test infrastructure (Jest)…   1d  [approved,proposed]
       https://github.com/acme/club-site/issues/9
    📋 #8    Add backend test infrastructure (Jest…)    1d  [approved,proposed]
       https://github.com/acme/club-site/issues/8
```

URLs print on a second indented line for easy copy-paste. Modern terminals (iTerm2, macOS Terminal, Ghostty, Warp) recognise them as clickable links — **cmd-click to open** in your default browser.

**When to use**:
- Before starting work in the morning, see what's queued
- After a dispatch run, see what got opened as PRs
- Quickly find the URL for an issue without leaving the terminal
- `issues-status -l approved` answers "what will the agent do next?"

---

## `routine-cost` — what the routines cost, per routine

Rolls up the append-only spend ledger `_run.sh` writes (`metrics/runs*.jsonl`) over a window. `routines-status` answers "did last night run?"; this answers "what did the last month cost, and which routine is burning it".

```bash
routine-cost                          # last 7 days, one line per routine
routine-cost --days 30                # last 30 days
routine-cost --since 2026-08-01       # explicit window start
routine-cost --until 2026-08-31       # explicit window end (default: today)
routine-cost --days 7 --until 2026-08-31   # the week ending on that date
routine-cost --by-model               # group by the models a run actually used
routine-cost --sends                  # add a Telegram-send count per routine
routine-cost --json                   # one JSON object per routine, for piping
```

**Example output**:
```
routine cost — 2026-08-06..2026-09-04 (28 runs across 1 ledger file(s))
cost columns cover 27 of 28 runs: a watchdog kill (t/o) records no cost, so it
counts in runs but not in cost/med/p95/max. bud = budget cap tripped, err = is_error or api_error_status.

routine                    runs     cost     med     p95     max  bud  t/o  err  turns  cache%  requested
dispatch-tasks-night         14    31.20    2.05    5.00    5.00    2    1    3   44.6    91.2  claude-opus-4-8
morning-triage                7     6.58    0.94    1.10    1.10    0    0    0   12.4    88.0  claude-sonnet-4-8
TOTAL                        28    41.03    1.32    5.00    5.00    2    1    3   28.1    90.1  claude-opus-4-8,claude-sonnet-4-8
```

A watchdog kill leaves `cost_usd` null — the CLI was killed before it could report its own spend — so those rows count toward `runs` and `t/o` but stay out of the cost columns. Folding them in as $0 would understate exactly the runs that ran longest.

The window is closed at both ends and the header prints the bounds it enforced. A row stamped in the future — a clock-skewed host, or a backfill imported with the wrong date — is outside a window ending today, and only `--until` brings it into scope. `--since` after `--until` is refused as a usage error rather than reported as an empty window.

**When to use**:
- `bud` above zero means a run hit `--max-budget-usd` and was truncated — raise the cap or shrink the prompt
- A routine whose `p95` sits far above its `med` is occasionally running away; the cheap fix is usually its model, not its cap
- A low `cache%` on a long routine means the prompt is being re-read rather than cached
- Before moving a routine between models, `--by-model` says what the current split actually costs

Reads `$METRICS_DIR` (default `~/.agentic-skills/routines/metrics`). Read-only. A host that has never run a routine prints one line saying there is no ledger and exits 0.

---

## `check-requirements` / `make doctor` — can this host do the work?

Reads each project's `agent/requirements.conf` — the manifest that travels with the code, in the
project's own repo — and says whether this machine has what the project needs. `make doctor` runs it
across every repo in `ACTIVE_REPOS`.

A repo whose checkout has no manifest falls back to
`launchd-runtime/requirements-templates/<owner>-<repo>.conf`, a manifest staged in this repo because
that project's tree was not clean enough to commit into. Every line reporting such a repo ends in
`(template)`, and `make doctor` names them under the table. The checkout's own file always wins.

```bash
make doctor                           # table + total for every active repo
make doctor-GameTwo                # one repo, with the per-requirement detail
check-requirements amarcu/StarBonk    # the same, called directly
check-requirements amarcu/StarBonk --quiet   # the REQ: summary line only
check-requirements --all --json       # one JSON object per repo, for piping
```

**Example output**:
```
repo                         gate      status       missing
amarcu/StarBonk              advisory  ok           -
amarcu/StarBonk-backend      -         no-manifest  -
acme/GameTwo            required  MISSING      xcodebuild, ../game-engine
acme/video_app       -         no-manifest  -
TOTAL 4 repos: 1 ok, 1 missing, 0 manifest-error, 0 advisory, 2 no-manifest, 0 unresolved
NOTE: 2 repo(s) checked against a staged template rather than their own agent/requirements.conf: amarcu/StarBonk, acme/GameTwo
```

Four verbs, one per line: `cmd <name> [>=<version>]`, `path <path>`, `env <VAR>`, and
`check <shell command>` for anything else that must exit 0 (`gh auth status`, `xcodebuild -version`).
`>=` is the only operator a `cmd` line may use — a host check acts on a minimum and nothing else — so
`<`, `==`, `=>`, a bare version, or anything trailing the version is a parse error rather than a
guess at what was meant.
A trailing `# hint: …` is printed when the requirement fails and `# install: …` is what
`install-requirements` offers to run. An optional first line `gate: advisory` says an **absent**
requirement downgrades that repo's verify gate to `NO GATE — verify by reading` instead of blocking
work.

`advisory` covers absence and nothing else. A `cmd` that is installed but older than its `>=` floor
fails under any gate — exit 1, `REQ: … below-floor=<names>` — because the tool is present and the
manifest has declared its output untrustworthy. StarBonk is the case: `cmd unity >=1.0.0-beta.8`
exists because Unity Hub's beta.5 reports a failed test and a failed compile identically.
Downgrading a beta.5 host to `NO GATE` would hide a tool the manifest declared untrustworthy, leaving
a repo that declares the floor worse off than one that declares nothing.

The per-repo target takes the bare repo name and assumes the owner: make splits a target on `/`
before matching a pattern rule, so a target with a slash in it — `doctor-acme/GameTwo` — matches
no rule at all. Call `check-requirements acme/GameTwo` for any form the target cannot express.
Every `make doctor…` command written in this file is checked to be a real target by
`test_requirements_manifests.sh`, so this cannot silently drift again.

Exit 0 when everything required passed, 1 when something is missing, **the manifest has a line it
cannot parse**, or a `cmd` is below its declared floor, 2 on a usage error or a repo `repos.conf`
cannot resolve. **A repo with neither a manifest nor a staged template exits 0** and reports
`no-manifest`: absence must never block work, or every project that has not written one yet stops
at once.

A line the parser cannot read is a **hard failure in every mode**, `--quiet` included: exit 1, with
`REQ: <repo> manifest-error line <n>: <text>` naming each one. An unrecognised verb or a malformed
version spec means a requirement is quietly not being checked, and reporting `ok` over an unchecked
requirement is the failure this whole thing exists to remove. `gate: advisory` does not soften it —
the gate says what to do when a requirement is *absent*, not when the file cannot be read.

`cmd` is resolved against the PATH THIS PROCESS INHERITED. Inside a routine that is the LaunchAgent
plist's PATH, which is the answer that matters; from your own terminal it is usually more permissive,
so `make doctor` can pass where the 04:10 run would not.

**When to use**:
- Before approving work in a project you have not built on this machine
- After a new machine, an OS upgrade, or a `brew upgrade` that moved something
- When a worker halted with `blocked:missing-deps` — the comment names what was missing, this says
  whether it is still missing

## `install-requirements` — install what is missing

```bash
install-requirements acme/GameTwo --dry-run   # print the plan, change nothing
install-requirements acme/GameTwo             # run each `# install:` command, then re-check
```

Runs each missing requirement's `# install:` command from the repo root, and lists everything else as
a manual step with its hint. A manifest `check-requirements` cannot parse stops it before it plans
anything: such a report carries no requirements, and an empty plan is indistinguishable from
"nothing missing" unless the status is read first. It never runs as root, never installs Xcode or activates a Unity licence
(both print as manual steps), and **defaults to `--dry-run` when stdin is not a TTY**, so no routine
can trigger an install. It ends by re-running `check-requirements`, so the result is verified rather
than assumed.

---

## `pr-review-round` — drive a PR's Copilot review rounds

The mechanical half of a Copilot review round: request one, wait for it, and say whether the round came back green. The judgement — is a finding valid — stays with the model running `iterate-on-pr`; this only handles the request/wait/collect cycle a human used to drive by hand.

Not symlinked onto `PATH` by `install.sh` — like `pr-review-bundle`, it is a pipeline internal that `iterate-on-pr` invokes by absolute path. `make review-round PR=<n>` is the read-only shortcut; the examples below are written from the repo root.

```bash
launchd-runtime/bin/pr-review-round request amarcu/agentic-pipeline 35
launchd-runtime/bin/pr-review-round request amarcu/agentic-pipeline 35 --force
launchd-runtime/bin/pr-review-round wait    amarcu/agentic-pipeline 35
launchd-runtime/bin/pr-review-round wait    amarcu/agentic-pipeline 35 --timeout-mins 12 --poll-secs 60
launchd-runtime/bin/pr-review-round status  amarcu/agentic-pipeline 35
launchd-runtime/bin/pr-review-round status  amarcu/agentic-pipeline 35 --json
make review-round PR=35               # `status` only, read-only
```

### `request` — ask Copilot for a review

Posts `reviewers[]=copilot-pull-request-reviewer[bot]`, and only after checking that no request is already pending — a second request while one is outstanding may be ignored. The plain `Copilot` reviewer form is accepted by the API and creates nothing, and nothing in the HTTP response says so, which is why the command verifies afterwards against the pending list and the `review_requested` timeline count.

```
ROUND: amarcu/agentic-pipeline#35 requested
ROUND: amarcu/agentic-pipeline#35 already-pending
```

Exit 0 either way. **Exit 3** when the POST created no request — verified, not assumed.

**Exit 6** is `already-reviewed-at <sha7>`: this head SHA already carries a Copilot verdict — asked as "is there a verdict of this commit", not "what was reviewed most recently", so a later review of an older commit cannot hide it. A review is billed in AI credits to whoever requested it, every time, with no de-duplication for a repeat on an unchanged SHA — so a re-request without a new commit spends the monthly allowance on an answer already on the PR. `--force` overrides it when you actually want a second opinion.

```
ROUND: amarcu/agentic-pipeline#35 already-reviewed-at 44b68d8
```

A quota notice at the head SHA does not count as having reviewed it: the round never happened, so the guard does not block the request that would.

### `wait` — block until this round's review lands

Waits for a review **of the head commit**, submitted after the wait began. A review of any other commit does not end it, however recently it was posted — Copilot answers late, and a verdict on the previous push must never satisfy a round opened for this one. `--since` is optional and defaults to the moment `wait` starts, so a caller needs no clock of its own: run `request`, then `wait`. Pass it explicitly only to reconstruct a round by hand. Copilot posts one review per round; the verdict comes off its opening line.

```
ROUND: amarcu/agentic-pipeline#35 review 2026-09-08T14:19:52Z green
```

`verdict` is `green` (`### 🟢 Approval recommended`), `changes` (`🟡`), `closer-look` (`🔵`) or `unknown`. **Exit 4** on timeout, with a line saying plainly that a timeout is not a green light — this commit was not reviewed, so it was not approved. Seeing only reviews of older commits is a timeout too, never a verdict.

**Exit 5** is `quota-exhausted`: Copilot replied "unable to review this pull request because the user who requested the review has reached their quota limit" instead of a verdict, so the round never happened. `wait` prints `ROUND: <owner/repo>#<n> quota-exhausted`. A caller must stop rather than re-request — the quota does not come back inside a loop.

### `status` — the verdict, and what is still unanswered

```
ROUND: amarcu/agentic-pipeline#35 status green unanswered=1
2317884590 launchd-runtime/bin/pr-review-round:88 This cast can throw on a null body.
```

The first line is the latest Copilot verdict and the number of root review comments nobody has replied to; one line follows per unanswered finding, as `<id> <path>:<line> <first line of body>`. `--json` emits the same state as one object, including the `commit_id` the verdict was against. When that commit is not the head, a note on stderr says so — the exit code still answers "green or not", but a verdict against an older commit says nothing about what has been pushed since.

**Exit 0 only when the head commit's verdict is green AND nothing is unanswered.** `status` reads the same review `wait` waits for, through the same lookup, so the two cannot disagree. Exit 1 otherwise, including `no-review` — which covers both a PR nobody has reviewed and a PR whose reviews are all of commits since replaced. A green review of the previous commit is not this commit's green. A review can carry findings only in its summary body with no inline comment at all, so an empty unanswered list is never a verdict on its own. **Exit 5** is the `quota-exhausted` case above, kept distinct from exit 1 so a loop can tell "this round found problems" from "this round never happened".

Every `gh` call is wrapped: a non-zero exit or unparsable JSON is a named error and **exit 2**, never an empty result that would read as green.

---

## Manual run of a routine

Useful for testing changes to a prompt, or for kicking off a routine on demand.

```bash
~/.agentic-skills/routines/_run.sh <routine-name>
```

This is exactly what launchd invokes at the scheduled time. It logs to the same place (`~/.agentic-skills/routines/logs/<name>-YYYY-MM-DD.log`) and sends a Telegram on non-zero exit, just like the scheduled run. Safe to run repeatedly.

---

## `claude-cli` — direct access to the bundled Claude Code CLI

The `claude` binary is bundled inside Claude Desktop at a version-specific path; this wrapper finds the latest one automatically.

```bash
claude-cli --version                  # check it works
claude-cli /login                     # log the CLI in to your Anthropic account (one-time)
claude-cli -p "What is 2+2?"          # one-shot prompt
claude-cli -p "$(cat prompt.md)" --dangerously-skip-permissions
```

**When to use**:
- One-off LLM calls from the terminal without opening Claude Desktop
- Scripting (the `_run.sh` runner uses this internally)
- Re-authenticating after a long absence (`claude-cli /login`)

---

## `install.sh` — deploy or refresh the runtime

Idempotent. Re-run any time you've edited a plist or added a new routine.

```bash
bash launchd-runtime/bin/install.sh
bash launchd-runtime/bin/install.sh --dry-run
bash launchd-runtime/bin/install.sh --skills-only   # skills only (`make install-skills`)
```

What it does:
- `mkdir -p` runtime directories
- Symlinks `bin/*` and `prompts/*.md` to `~/.agentic-skills/`
- Copies `agents/*.plist` to `~/Library/LaunchAgents/` and `launchctl bootstrap`s each
- Symlinks each skill *directory* to `~/.claude/skills/<name>`, dropping the legacy `~/.claude/commands/<name>.md` file links that hid META.md and scripts/

You don't need to re-run after editing a `.sh` script or a prompt — those are symlinked and changes are live. Plists are copies, so editing a plist requires re-running `install.sh`.

---

## Tests — pre-flight regression suite

Run before committing changes to the runtime, BASELINE.md, or any skill that inherits BASELINE. Catches the bug classes we've actually hit in production (orphan kills, watchdog freezing on sleep, "four-vs-five principles" drift, deprecated Telegram patterns, broken plists).

```bash
launchd-runtime/tests/run.sh             # all tests, ~60-90s
launchd-runtime/tests/run.sh unit        # _run.sh behaviour + repos.conf
launchd-runtime/tests/run.sh static      # cross-file consistency checks
launchd-runtime/tests/run.sh <substring> # only tests matching <substring>
```

Each new bug class deserves a new test fixture in `tests/fixtures/mock-claude-cli/` plus a `test_*` function — that's the discipline that breaks the regression cycle. See `tests/README.md` for the authoring conventions.

## launchctl basics (when you need to debug deeper)

```bash
# List all loaded launchd-runtime agents
launchctl list | grep com.agentic-skills.routines

# State and next-fire info for one agent
launchctl print gui/$(id -u)/com.agentic-skills.routines.morning-triage

# Manually trigger an agent right now (bypasses the schedule)
launchctl kickstart -k gui/$(id -u)/com.agentic-skills.routines.morning-triage

# Unload one agent (e.g., to disable a routine without deleting it)
launchctl bootout gui/$(id -u)/com.agentic-skills.routines.morning-triage

# Reload after editing the plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.agentic-skills.routines.morning-triage.plist
```

---

## `wake-schedule` — Mac wake-schedule maintenance

The system-level daemon (`launchd-runtime/system/`) keeps the Mac awake at 03:55 / 08:55 / 17:55 via pmset, so user-level routines actually fire. This CLI manages the pause state and triggers manual refreshes.

```bash
wake-schedule status                       # current pause state + queued events
wake-schedule pause 7d                     # pause refreshes for 7 days (vacation)
wake-schedule pause until 2026-06-01       # pause until specific date
wake-schedule pause forever                # pause indefinitely
wake-schedule pause-now 1d                 # pause AND clear existing queue (sudo)
wake-schedule resume                       # clear pause + refresh now (sudo)
wake-schedule refresh                      # force-rebuild the queue (sudo)
sudo cat /var/log/wake-schedule.log        # daemon log (timestamped)
```

The daemon refreshes daily at noon and on boot. Each refresh schedules 3 days × 3 wakes = 9 events; pmset silently drops past times so you'll see 6-9 entries in `pmset -g sched` depending on time of day.

---

## Where things live (mental model)

| Type | Source of truth | Runtime location |
|---|---|---|
| Skill scripts | `launchd-runtime/bin/*.sh` (this repo) | `~/.agentic-skills/routines/` (symlinks) |
| Skill prompts | `launchd-runtime/prompts/*.md` (this repo) | `~/.agentic-skills/routines/*.prompt.md` (symlinks) |
| LaunchAgents | `launchd-runtime/agents/*.plist` (this repo) | `~/Library/LaunchAgents/*.plist` (copies — re-install to update) |
| Tracked repos | `launchd-runtime/repos.conf` (local, git-ignored; from `repos.conf.example`) | read in-place |
| Routine logs | n/a | `~/.agentic-skills/routines/logs/<name>-YYYY-MM-DD.log` (NOT in repo) |
| Telegram creds | `~/.claude/settings.json` (`.env.TELEGRAM_*`) | n/a |

---

## Cheat-sheet: the commands you'll actually use daily

```bash
issues-status -l approved          # "what's the agent about to do?"
issues-status -l proposed          # "what needs my approval?"
issues-status                      # "what's open everywhere?"
routines-status                    # "did the routines fire correctly?"
routine-cost                       # "what did this week cost, and where?"
make doctor                        # "can this host actually build these projects?"
```

Add `routines-status -v <name>` only when something looks off. The morning `wake-status-digest` Telegram should surface issues automatically, so you usually won't have to ask.
