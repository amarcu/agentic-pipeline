# agentic-skills — Claude Code Context

The pipeline itself: the skills, the launchd runtime and the tests that keep them honest. Editing
this repo changes how every other repo's work gets proposed, written, reviewed and merged, so the
bar here is higher than in a product repo — a mistake propagates to all of them.

## Read first
1. `BASELINE.md` — the five principles every coding skill inherits
2. `BASELINE-CODING.md` — the verify-gate rules, the retry budget, and when to stop and ask
3. `docs/skill-standard.md` — what a `SKILL.md` must contain: frontmatter, body order, attribution
4. `README.md` — what each skill is for and how the pieces fit together
5. `launchd-runtime/repos.conf.example` — every cap, with an example roster. The real roster is
   the git-ignored `launchd-runtime/repos.conf` on each machine.

## Layout
- `skills/<name>/` — one folder per skill: `SKILL.md`, `META.md`, `references/`, `scripts/`
- `launchd-runtime/` — the scheduler: `agents/` (plist templates), `prompts/`, `bin/`, `tests/`
- `permissions/` — the deny and allow baseline, and the protected-paths hook
- `docs/` — the skill standard, plugin distribution, dated assessments
- `tools/export-public.sh` — builds and checks the tree that is safe to publish

Nothing tracked may name one person's machine, network, secrets or private projects.
`launchd-runtime/tests/static/test_no_personal_values.sh` enforces it. Machine-specific values go
in the git-ignored local files, each of which has a tracked `.example`: `repos.conf`,
`machines.conf` and `secrets.env` under `launchd-runtime/`.

## Stack
Bash **3.2** (`/bin/bash` on macOS — not 4.x) and `/usr/bin/python3` with the standard library
only. **No third-party Python modules**, no `pip install`, no virtualenv: these scripts run from
launchd with a bare `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, so anything not in the system Python is
not available at 04:00.

The floor is **Python 3.9.6** — the `/usr/bin/python3` on the pipeline host, which is the machine
that actually runs the routines. A workstation may well have a newer one; write for 3.9.6 anyway,
and declare it in `agent/requirements.conf` (`cmd python3 >=3.9`) so `make doctor` says so.

Consequences that have actually bitten:

- Bash 3.2 has no associative arrays and no `${var^^}`, and it mis-parses a quote inside a heredoc
  nested in `$(…)`. Keep heredocs at the top level and read their output back from a file.
- Never trust `PATH` for a tool. `gh` is resolved as `command -v gh || ~/.local/bin/gh`; `jq`
  through the candidate list in `launchd-runtime/bin/_run.sh` (`/usr/bin`, `/opt/homebrew/bin`,
  `/usr/local/bin`, `~/.local/bin`), which `launchd-runtime/tests/helpers.sh` mirrors. On the
  pipeline host `/usr/bin/jq` does not exist.
- Prefer absolute paths for system binaries (`/bin/cat`, `/usr/bin/git`) in anything launchd runs.
- A newer local interpreter hides 3.9 breakage rather than reporting it. `datetime.fromisoformat`
  is the one that keeps coming back: until 3.11 it rejects the `Z` that every GitHub timestamp
  ends in, so parse those as `ts.replace("Z", "+00:00")` and never bare — see
  `launchd-runtime/bin/pipeline-metrics`. `date.fromisoformat` is stricter before 3.11 too: on
  3.9 it takes `YYYY-MM-DD` and nothing else.

External CLIs the pipeline calls: `gh`, `claude`, `cursor-agent`, `unity`. Each is optional, and a
script that needs one must fail with a named error rather than degrade quietly.

## Build / Verify

The gate is:

```
make test
```

It runs `launchd-runtime/tests/run.sh` (unit + static) and prints a count. Where the optional
`anchor/` component is present it runs that suite too. Exit `0` means every test passed. Nothing
else counts as verification here.

`make test-unit` and `make test-static` narrow it while iterating; the full `make test` is what has
to be green before a PR.

**`make smoke` is NOT part of the gate.** It runs every routine headless against the real APIs and
spends budget, so it never runs unattended, never in CI, and never as a substitute for `make test`.
Run it deliberately, on the pipeline host, when a routine's contract changed.

Both suites are hermetic: mocks for `gh`, `claude`, `cursor-agent`, Unity and Telegram live in
`launchd-runtime/tests/fixtures/`, and no test may reach the network. A test that needs a new
external surface extends the mock rather than skipping.

If `jq` is absent the suite aborts with exit `5` and says where it looked — install `jq` or set
`JQ_BIN`; that is a broken environment, not `NO GATE`.

## Branch / commit / PR
- Never push to `main`. Branch as `task/issue-<N>-<slug>` for issue work, `pipeline/<topic>` for
  pipeline changes, `hotfix/<topic>` for a break that is already costing a nightly run.
- Commits: imperative single-line subject, then a body that says what was wrong and what now
  happens instead. The body is where the reasoning lives; the code carries only the constraints it
  cannot show.
- PRs open as **draft**, with Summary / Why / Test plan and `Closes #N`. Quote the gate result —
  the count each suite printed — rather than asserting it passed.
- Marking a PR ready and merging are the human's, except through the merge lane (`bin/merge-lane`, a script, for repos in `MERGE_LANE_REPOS` only); see BASELINE.md → Merging and Marking PRs Ready.

## Agent autonomy

**CAN do autonomously**
- Implement an approved issue inside `skills/`, `launchd-runtime/bin/`,
  `launchd-runtime/prompts/` and `launchd-runtime/tests/`
- Add or extend tests, fixtures and mocks
- Update `README.md`, `docs/` and a skill's own `META.md` to match a change made here
- Run `make test` and the narrower test targets

**MUST ask first** (through `/request-approval`, which stops the run)
- `launchd-runtime/repos.conf.example` and a machine's own `repos.conf` — every cap in the
  pipeline lives there, and changing one changes what the fleet does tonight
- `launchd-runtime/agents/` and anything that changes a routine's schedule
- `launchd-runtime/bin/install.sh` and `launchd-runtime/system/` — they touch launchd and,
  for the system one, require sudo
- `BASELINE.md`, `BASELINE-CODING.md` and `docs/skill-standard.md` — the contracts every skill
  inherits
- Deleting or renaming a skill

**NEVER touch**
- `~/.agentic-skills/routines/logs/`, `~/.agentic-skills/routines/metrics/`,
  `~/.agentic-skills/routines/trash/` and `~/.agentic-skills/routines/.pipeline-host` — the live
  runtime's own state and the file that decides which machine owns the schedule
- `~/.claude/settings.json` and the rest of `~/.claude/` — the harness configuration, human-owned
- Anything under `permissions/` without a human in the loop; it is the deny-net that stops a
  headless run doing damage
- `gh pr ready`, `gh pr merge`, `git push --force`, and any push to `main` (the merge lane script is the one sanctioned caller of the first two)

## Working on the pipeline from inside it
A PR that touches `launchd-runtime/`, a `*.plist`, `.github/` or a `SKILL.md` is a pipeline PR.
`pr-review-bundle` refuses to bundle one for review (exit 4) so that Claude never reviews its own
guardrails; only `cursor-review`, whose reviewer is a different vendor's model, may pass
`--allow-pipeline` and review it. Expect a pipeline PR to be read by a human, by Cursor, or by
both — never by `review-pr`.
