# tests/ — pre-flight regression suite

Pure-bash test framework (no dependencies beyond what macOS ships) covering the three test tiers for this stack:

- **Tier 1 — `unit/`**: mock-based behaviour tests of `_run.sh` itself, the central runner used by every scheduled routine.
- **Tier 2 — `static/`**: lint-style consistency checks across every skill, plist, and reference between files.
- **Tier 3 — `smoke/`**: one headless read-only run of every routine through the real runner path, asserting each one's output contract. **Not part of `make test`** — it spends real API calls. See [The smoke gate](#the-smoke-gate-make-smoke).

Together they cover the bug classes we've actually hit:

| Past bug | Date | Caught by |
|---|---|---|
| `find /Users/...` orphan kept session alive 8.5h | 2026-05-10 | `unit/test_run_sh.sh::watchdog_kills_orphan_children_in_process_group` |
| Watchdog frozen by macOS sleep (6.5h stuck) | 2026-05-11 | `unit/test_run_sh.sh::watchdog_kills_hanging_cli_within_wall_clock_budget` (uses wall-clock, not `sleep`) |
| Telegram duplicate sends (jq parse errors with emoji) | 2026-05-10 | `static/test_baseline_conformance.sh::no_deprecated_jq_telegram_pattern_in_active_skills` |
| "Four principles" preamble drift (BASELINE got 5) | 2026-05-11 | `static/test_baseline_conformance.sh::inheriting_skills_preamble_says_five_principles` |
| Dispatch deadlock: one cap under four names with four values | 2026-09-02 | `static/test_cap_names.sh::every_cap_named_in_a_skill_or_prompt_is_defined_in_repos_conf` |
| Eleven skills solving the same five problems five different ways | 2026-09-03 | `static/test_skill_contract.sh` (the mechanical half of `docs/skill-standard.md`) |
| Every review bundle's acceptance criteria was a placeholder (gh returns no issue body under `closingIssuesReferences`) | 2026-09-03 | `unit/test_pr_review_bundle.sh::pr_review_bundle_writes_only_the_criteria_section` |
| Every routine whose prompt says "run the /skill" halted: `disable-model-invocation` blocks the Skill tool | 2026-09-05/06 | `static/test_skill_contract.sh::contract_routine_invoked_skills_disable_model_invocation`, and `make smoke` on any routine |
| Dispatch's forked `work-on-task` arrived with no arguments | 2026-09-07 | `make smoke-dispatch-tasks-night` — the `WORK:`/`PLANNED:` assertion |
| Two workers spent a dispatch slot each discovering undeclared host gaps (no game-engine checkout, no full Xcode) | 2026-09-07 | `unit/test_check_requirements.sh`, `static/test_requirements_manifests.sh` |
| A manifest line nobody could parse reported `ok` — the requirement was silently never checked, in every mode | 2026-09-08 | `unit/test_check_requirements.sh` (one test per malformed shape), `unit/test_install_requirements.sh` |
| The two repos the requirements feature was built for reported `no-manifest`: their manifests were staged in `requirements-templates/` and nothing read them | 2026-09-08 | `unit/test_check_requirements.sh::check_requirements_reads_a_staged_template_when_the_checkout_has_none`, `static/test_requirements_manifests.sh::requirements_no_repo_is_both_covered_and_excepted` |
| `gate: advisory` downgraded a too-old `cmd` to `no-gate`, skipping the very gate the version floor existed to reach — declaring the floor left the repo weaker than declaring nothing | 2026-09-08 | `unit/test_check_requirements.sh::check_requirements_advisory_does_not_cover_a_failed_version_floor` |
| `dispatch-tasks` Step 1 dropped a repo into `unmet` while its own verify line admitted only two buckets, so a correct run could not satisfy it | 2026-09-08 | `static/test_cap_names.sh::dispatch_step_1_verify_admits_the_unmet_bucket` |

What we don't test (and what mitigates each):

- **Real Anthropic API failure**: simulated via mock CLI with `error` and `hang` fixtures — covers the runner's response.
- **Real macOS sleep**: `caffeinate` in `_run.sh` prevents it; the wall-clock watchdog catches it if caffeinate fails.
- **Real Telegram delivery**: `tests/fixtures/mock-telegram-server.py` captures every POST. Production delivery is exercised daily by `wake-status-digest` running for real (a canary).

## Running

```bash
launchd-runtime/tests/run.sh                  # all tests
launchd-runtime/tests/run.sh unit             # unit/ only
launchd-runtime/tests/run.sh static           # static/ only
launchd-runtime/tests/run.sh telegram         # any test with "telegram" in its name
```

Expected runtime: ~60-90 seconds (the watchdog tests intentionally wait ~35s real wall-clock to verify the watchdog actually fires).

Exit code is 0 when all tests pass, non-zero otherwise.

## Layout

```
tests/
├── README.md                              # this file
├── run.sh                                 # entry point (no deps)
├── helpers.sh                             # assertions + mock env lifecycle
├── fixtures/
│   ├── mock-claude-cli/                   # binaries with the same surface as the real claude-cli
│   │   ├── success                        # clean run, exit 0
│   │   ├── error                          # emits "API Error: Stream idle timeout", exit 1
│   │   ├── hang                           # sleeps forever — must be killed by watchdog
│   │   └── orphan                         # spawns hanging child — tests kill_tree
│   ├── mock-gh/gh                         # canned gh responses out of $MOCK_GH_DIR
│   ├── mock-telegram-server.py            # localhost HTTP server that captures POSTs
│   ├── settings/settings.json             # fake env (TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID)
│   ├── smoke-envelopes/                   # JSON envelopes the smoke checker is judged against
│   └── prompts/test-routine.prompt.md     # placeholder prompt file
├── unit/
│   ├── test_run_sh.sh                     # _run.sh behaviour (success, error, watchdog, orphans, missing prompt)
│   ├── test_pr_review_bundle.sh           # pr-review-bundle: criteria section, src/ export, bounded tree
│   ├── test_repos_conf.sh                 # get_repo_path() function under bash 3.2
│   └── test_smoke_checker.sh              # every verdict of smoke/check-envelope.sh, on fixtures
├── smoke/                                 # tier 3 — NOT run by make test
│   ├── run-smoke.sh                       # one headless run per routine, the way _run.sh runs it
│   ├── check-envelope.sh                  # the verdict: exit, is_error, denials, contract line
│   └── out/                               # envelopes + captured Telegrams (gitignored)
└── static/
    ├── test_baseline_conformance.sh       # BASELINE.md exists, has 5 principles, no drift in skill preambles
    ├── test_cap_names.sh                  # every *_MAX a skill or prompt names is defined in repos.conf, and no prompt sets one
    ├── test_plists.sh                     # plists parse, point to existing files, sane schedules
    ├── test_skill_contract.sh             # every SKILL.md meets the mechanical half of docs/skill-standard.md
    └── test_skill_metadata.sh             # every skill has SKILL.md + META.md with required frontmatter
```

## The smoke gate (`make smoke`)

The suite above checks files. Nothing in it checks a *run* — and the outages of 2026-09-05/06 and
2026-09-07 were both invisible to every file-level check, and both would have shown up in one
headless run of the real prompt. `make smoke` is that run.

```bash
make smoke                      # every routine
make smoke-morning-triage       # one
```

For each routine it does what `bin/_run.sh` does, minus the mutations: the same prompt file passed
to `claude -p`, the same `--settings` deny-net (both read `bin/headless-deny.sh`, so the rehearsal
cannot drift from the night), `--dangerously-skip-permissions`, `--output-format json`, `ROUTINE`
and `ROUTINE_RUN_ID` exported, the LaunchAgent's working directory, `/`, and the `PATH` from that routine's own plist. It then asserts the
run exited 0, `is_error` is false, `permission_denials` is empty, and `result` carries that
routine's output-contract line — as listed in `bin/routine-contracts.tsv`, which the runner also
warns from:

| Routine | Contract in `result` |
|---|---|
| `morning-triage` | `TRIAGE:`, whose `errors=` count must stay below `repos=`: a scan in which every repo errored saw nothing |
| `morning-proposals` | at least one `PROPOSED:` or `HALT:` |
| `dispatch-tasks-night` | `DISPATCH GATE:` **and** `DISPATCH END:` — plus a `WORK:`/`PLANNED:` line from the forked worker whenever the gate line named an eligible repo |
| `daily-summary-routine` | `SUMMARY:` |
| `pr-review-night` | `REVIEW:` |
| `pr-iterate-night` | `ITERATE:` |
| `skill-assess-weekly` | `ASSESS:` or `HALT:` |
| `wake-status-digest`, `daily-review-nudge` | exit 0 and a non-empty result |

Two strings in `result` fail a routine outright, because we have already paid for both:
`disable-model-invocation` (2026-09-05/06) and `don't have an issue number` (2026-09-07).

One line per routine, plus a total; every envelope is kept under `smoke/out/`:

```
SMOKE: morning-triage pass 74s $0.28 -
SMOKE: dispatch-tasks-night FAIL 131s $0.44 known-signature:"don't have an issue number"
SMOKE TOTAL: 8 passed, 1 failed, $2.91, 3 telegram send(s) captured (none delivered)
```

### What keeps it read-only

Three layers, in the order they engage:

1. **`ROUTINE_DRY_RUN=1`.** `BASELINE.md` defines it as `--dry-run` for every skill: read
   everything, decide everything, print the contract lines, return before the first mutation. Each
   skill observes it in its Step 0 echo — `env` and `printenv` are denied in a headless run, so
   that echo is the only channel. `bin/_run.sh` never sets it.
2. **A mock Telegram server.** `TELEGRAM_API_URL` points at `fixtures/mock-telegram-server.py` and
   the credentials are placeholders, so a send is captured under `smoke/out/`, never delivered. The
   gate refuses to start if the mock does not come up. `METRICS_DIR` also points into `out/`, so a
   rehearsed send never lands a row in the production ledger.
3. **A smoke-only deny family** on top of the production one: `gh issue create`, `gh pr create`,
   `git push`, `git commit` and the rest of the writes no rehearsal makes. A denial *fails* the
   routine, so this layer is a tripwire as much as a guard.

The gate refuses to run at all when the checkout `~/.claude/skills` points at has no
`ROUTINE_DRY_RUN` section in its `BASELINE.md`. Skills, `repos.conf`, `BASELINE.md` and
`telegram-send` all resolve through `/Users/dev/code/agentic-skills` — never
through your worktree — so a branch that has not landed there would be rehearsing against the
*installed* skills, which is not a rehearsal at all. Land the branch first, or set
`SMOKE_SKIP_GUARD_CHECK=1` for a routine you have separately confirmed makes no writes.

### Knobs

`SMOKE_MODEL` (default `claude-sonnet-5`), `SMOKE_EFFORT` (`high`), `SMOKE_MAX_BUDGET_USD`
(`1.50` — raise it for a dispatch run that actually forks workers), `SMOKE_MAX_TURNS` (`40`, passed
only when the installed CLI has the flag), `SMOKE_TIMEOUT_SECONDS` (`900`), `SMOKE_SKILLS_ROOT`,
`SMOKE_SKIP_GUARD_CHECK`.

### Adding a routine

A new `prompts/<name>.md` joins `make smoke` on its own. It fails as `unknown-routine` until its
contract is written into `smoke/check-envelope.sh`, and `unit/test_smoke_checker.sh` fails the
suite until then — which is the point.

## Authoring conventions

A new test is just a bash function whose name starts with `test_`. Drop it in any `*.sh` under `unit/` or `static/`; the runner discovers it automatically.

```bash
test_my_new_assertion() {
    local rc=0
    # ... do work ...
    assert_equal "expected" "$actual" "what this checks" || rc=1
    assert_contains "$haystack" "needle" "what this checks" || rc=1
    return $rc
}
```

Assertions return 1 on failure. Tests should accumulate a `rc=0` and `|| rc=1` on each assertion so all failures surface in one run rather than stopping at the first.

A test may also print a `WARN:` line and still return 0 — a finding it has deliberately chosen not to fail on, such as a skill whose rewrite to `docs/skill-standard.md` is still pending. The runner prints a passing test's output too, so the warn tier is visible rather than write-only; the count shrinks as the debt is paid down.

For tests that exercise `_run.sh`:

```bash
test_something_about_the_runner() {
    setup_run_env                              # creates isolated TEST_TMP, mock TG server
    export CLAUDE_CLI="$FIXTURES_DIR/mock-claude-cli/error"  # pick the failure mode
    export ROUTINE_TIMEOUT_SECONDS=10

    invoke_runner test-routine
    local exit_code=$?

    local rc=0
    assert_exit 1 "$exit_code" || rc=1
    assert_equal 1 "$(telegram_count)" || rc=1
    assert_contains "$(captured_telegram)" "expected substring" || rc=1
    assert_contains "$(runner_log)" "log line we want" || rc=1

    teardown_run_env
    return $rc
}
```

## When a routine fails in production, write the test FIRST

Every time we hit a new bug class, the discipline is:

1. Reproduce in a mock fixture (add to `fixtures/mock-claude-cli/` or create a new fixture type).
2. Write a failing test in `unit/` or `static/`.
3. Fix the underlying code.
4. Test goes green.
5. Bug becomes permanently impossible to ship again.

This is the actual leverage point. Each prior fix made one bug impossible *in production*; each test in this suite makes a whole class of bug impossible *at commit time*.
