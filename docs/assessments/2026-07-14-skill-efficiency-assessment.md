# Skill efficiency & quality assessment — 2026-07-14

Measured assessment of the launchd routine stack (5 scheduled routines, 10 skills), with a
ranked improvement plan where **every item is justified by a measured number**, not a guess.

## 1. Data sources & methodology

| Source | Coverage | What it gave us |
|---|---|---|
| Runner logs `~/.agentic-skills/routines/logs/*.log` | 2026-05-10 → 2026-07-14, 315 runs | exit codes, durations, timeouts, failure causes |
| Headless transcripts `~/.claude/projects/-/*.jsonl` | 2026-06-14 → 2026-07-14, 102 sessions | per-run token usage (deduped by API message id), tool calls, permission denials, model used |
| LaunchAgent plists + `_run.sh` | current | timeout budgets, model selection mechanism |
| Anthropic pricing (claude-api skill, cached 2026-06-24) | — | $ conversion per model |

Extraction script: deterministic Python (`extract_metrics.py`, session scratchpad; being
productized as `launchd-runtime/bin/routine-metrics`, see item C2). Qualitative
classification of waste patterns: multi-agent workflow over the flagged transcripts/logs,
each finding backed by verbatim transcript quotes. Feature research: web research verified
against the installed CLI (2.1.209) — every claim tested via `--help`/live run or official docs.

## 2. Baseline: what the stack costs and how reliably it runs

### Reliability (May 10 – Jul 14, AC-skips excluded)

| Routine | attempted | failed | success | timeouts | budget | dur med/p90/p95 (success) |
|---|---|---|---|---|---|---|
| wake-status-digest | 56 | 4 | 92.9% | 2 | 300s | 72 / 104 / 109s |
| morning-triage | 54 | 6 | 88.9% | 4 | 300s | 120 / 161 / 169s |
| **morning-proposals** | 53 | **16** | **69.8%** | **12** | 600s | 287 / 453 / 520s |
| dispatch-tasks-night | 53 | 6 | 88.7% | 3 | 2700s | 226 / 810 / 1033s |
| daily-summary | 44 | 5 | 88.6% | 2 | 600s | 139 / 201 / 220s |

Failure classes (all routines):
1. **Chronic timeout** — morning-proposals killed at its wall-clock cap on 12/53 runs
   (9 at the current 600s cap, 3 under earlier/larger budgets). Successful runs' p95 is
   520s: the cap has no headroom, and the skill wastes 60-300s per run on avoidable
   work (see P3).
2. **Auth outage** — 2026-06-24/25: expired OAuth ⇒ every run failed in 3-5s with 401 for
   two days (10 lost runs, 10 identical generic Telegram alerts, no guidance, no dedup).
3. **Zero-output stalls** — 2026-07-06: three runs hung from startup and burned their
   full wall-clock budget before the watchdog killed them (301s, 302s, and 2714s —
   45 min — for dispatch-tasks-night); a fourth (morning-proposals, 600s budget) failed
   on its own at 307s when the underlying 401 finally surfaced. The watchdog checks
   wall-clock only, never output liveness.
4. **Sleep-freeze (mitigated)** — 2026-05-21: battery overnight froze CLI+watchdog; all 4
   morning routines died at an identical 4927s. The AC pre-check added afterwards prevents
   recurrence; residual cost is that battery days now become silently *skipped* runs (58
   skips in the period) and the abort-path Telegram curl once hung 46 minutes.

### Cost (30 days of transcripts, per-model pricing)

| Routine | actual 30d | if all Opus 4.8 | if all Sonnet 5 |
|---|---|---|---|
| daily-summary | $10.56 | $8.73 | $5.24 |
| dispatch-tasks-night | $26.80 | $20.93 | $12.56 |
| morning-proposals | $22.10 | $19.51 | $11.70 |
| morning-triage | $14.31 | $12.58 | $7.55 |
| wake-status-digest | $9.85 | $8.86 | $5.32 |
| **Total** | **$83.63 (~$1,018/yr)** | **$70.61** | **$42.37** |

Component breakdown (mixed per-model pricing; corrected in audit — an earlier draft
mistakenly used all-Fable rates): cache reads $31.16, cache writes $26.20, output $23.25,
uncached input $3.02 (sums to the $83.63 total) → **context size is ~69% of cost**,
which is why the dedup items (D*) pay off directly.

**Model drift (live regression).** The runner passes no `--model`; headless runs inherit
`~/.claude/settings.json` → whatever model was last set interactively. Observed drift:
Opus 4.8 on most days, but Fable 5 sessions on 07-04/05, 07-06, 07-08/09, 07-13/14 and
Sonnet 5 on 07-07/08.
The 17 Fable sessions cost **$14.60 more** than the identical tokens on Opus 4.8
(same tokenizer). As of this assessment `settings.json` says `claude-fable-5[1m]`, so the
stack is running at 2× intended cost *right now*.

### Permission-denial waste (30 days)

18/21 morning-triage, 8/21 morning-proposals, 8/18 daily-summary, 4/21 wake-status and
3/21 dispatch sessions hit ≥1 permission denial. Root causes, with per-run token waste
(verbatim evidence in the workflow output, session scratchpad `w5yylt9dk.output`):

| Pattern | Routines hit | Waste/run (est.) |
|---|---|---|
| SKILL.md Telegram send recipe uses denied forms (mktemp / `$VAR` composition / export / python3-heredoc compounds) | triage, summary, proposals, dispatch, wake | 350–2,800 tok + 25–70s |
| `rm -f /tmp/...` cleanup mandated by skills but `Bash(rm:*)` is deny-listed (deny survives `--dangerously-skip-permissions`); retried, sometimes kills the whole chained send | all 5 | 120–700 tok + 12–30s |
| Leftover fixed-name /tmp files (rm never works) ⇒ Write tool "File has not been read yet" errors next run | triage, summary, wake | 350–800 tok |
| morning-proposals prompt points at a repo list that doesn't exist in the skill ⇒ filesystem hunt every run | proposals | 600–1,200 tok + 80–190s |
| Saturated backlog not pre-checked ⇒ full no-op session incl. one 9-way subagent fan-out | proposals | up to 9,000 tok + 300s |
| Agents maintain a *memory file* about the denied send pattern instead of the skill being fixed | triage | 766 tok when updated |

### Prompt-size waste (context loaded every run)

11 duplication findings (prompt-cost audit; full detail in workflow output). Highest impact:
BASELINE.md fully loaded by propose-tasks though only 2/5 principles apply (~1,375 tok/run);
Telegram send block triplicated across notify/triage/summary (~350-400 tok/run each);
morning-triage re-implements triage-repo's fetch+classify inline (~650 tok/run); repo list
hardcoded in 3 skills although `repos.conf` is the declared single source (~250 tok/run + 4-way drift).

### Verify gate

`make test` was already red before this work: 4 pre-existing failures, all in the anchor
suite — 3 wrapper tests comparing un-canonicalized `mktemp` paths (`/var` vs `/private/var`)
and 1 bash-3.2 `set -u` crash on empty-array expansion (`${missing[*]}`). Fixed in this
branch so the gate is meaningful again (T1).

## 3. New features integrated (verified against installed CLI 2.1.209)

| Feature | Verified how | Used by plan item |
|---|---|---|
| `claude -p --output-format json` returns `total_cost_usd`, `usage`, `modelUsage`, `num_turns`, `permission_denials`, error subtypes | live run + `--help` | C2 metrics logging |
| `--json-schema` → schema-validated `structured_output` (hard-fails on invalid schema since 2.1.205) | live run | future per-routine typed outputs (deferred) |
| `--model` per invocation | `--help` | C1 model pinning |
| `--max-budget-usd` spend cap in print mode | `--help` | C3 runaway guard |
| `--fallback-model` | `--help` | C1 (optional resilience) |
| `claude setup-token` → long-lived `CLAUDE_CODE_OAUTH_TOKEN` for headless auth | `setup-token --help` | R1 auth fix at the root |
| `--disallowedTools` bare-name = tool removed from context; `dontAsk` permission mode | `--help` + docs | future tightening (deferred) |
| `--bare` mode (skips auto-discovery; docs: recommended for scripted `-p`) | `--help` + docs | deferred — routines rely on skill auto-discovery |
| OpenTelemetry export (`CLAUDE_CODE_ENABLE_TELEMETRY`) | docs | deferred — C2's JSON parsing is sufficient at this scale |
| PreToolUse hooks (deny with reason / input rewrite), SessionEnd/Stop hooks | see §5 verification addendum | P2 alternative (deferred) |
| Skill frontmatter (`disable-model-invocation`, `context: fork`, per-skill `model`) | see §5 verification addendum | D-items (as applicable) |

## 4. Ranked improvement plan

Each item: measured justification → change → expected effect. Implementation status is
tracked in §6.

### Tier 1 — reliability & live cost regression (largest measured impact)

- **C1. Pin the model per routine in the runner.** Justification: $13.02/30d measured excess
  from drift ($83.63 vs $70.61), currently running at Fable-5 pricing. Change: `_run.sh`
  passes `--model "${ROUTINE_MODEL:-claude-opus-4-8}"`; each plist may override via
  `ROUTINE_MODEL`. Effect: −16%/mo immediately; enables per-routine routing later
  (scan routines on Sonnet 5 would make the total $58.54, −30% — left as a user decision,
  config is in place).
- **R1. Auth: long-lived token + pre-flight canary with a single actionable alert.**
  Justification: 10 lost runs + 10 generic alerts over 2 days; 4 stall runs on 07-06 were
  the same auth path hanging. Change: (a) document + support `CLAUDE_CODE_OAUTH_TOKEN` from
  `claude setup-token` in the runner env; (b) `_run.sh` pre-flight: 60s-watchdogged
  `claude -p 'ok' --model claude-haiku-4-5`; on auth failure send ONE deduplicated Telegram
  ("AUTH EXPIRED on <host> — run `claude setup-token`"), exit with distinct code 4.
- **R2. Startup-stall detection via the auth canary (revised during audit).** Justification:
  4 zero-output runs burned full budgets (301s, 302s, 305s, 2714s). A log-growth
  "first-output deadline" was implemented first and **reverted**: in `-p` print mode the CLI
  emits nothing until completion, so healthy runs (morning-proposals median 287s, dispatch
  p95 1033s) are indistinguishable from hung ones by log growth — a 240s deadline would have
  killed most healthy proposals runs. Shipped instead: the R1 canary aborts the run (exit 4,
  distinct alert) when it hangs on **two consecutive** attempts (`CANARY_TIMEOUT`, 60s each;
  a healthy canary answers in seconds). This catches the observed 07-06 class — the hang was
  in the auth path before any output — in ~2 min instead of the full budget, with zero
  false-positive risk to healthy runs.
- **R4. morning-proposals timeout 600→900s.** Justification: 12/53 runs killed at 604s;
  successful p95 = 520s leaves zero headroom; P3 reduces run length but the cap should not
  sit on the p95. Effect: converts most chronic timeouts into completions; bounded by C3.
- **C3. `--max-budget-usd` per routine.** Justification: worst observed run 32,164s (8.9h,
  dispatch, started 2026-05-10; a second 23,246s/6.5h dispatch run failed 2026-05-11);
  a spend cap is the correct guard now that the flag exists. Change: runner passes
  `--max-budget-usd "${ROUTINE_MAX_BUDGET_USD:-5.00}"` — a runaway guard, not a tight
  budget (audit: a 2.00 default would truncate long dispatch/proposals runs whose
  costliest healthy instances measure ≈$2-3 at Opus pricing).

### Tier 2 — permission-denial waste (skills + prompts)

- **P1. Checked-in Telegram sender `launchd-runtime/bin/telegram-send`.** Justification:
  the single largest recurring waste; send recipe denied in 18/21 triage runs (~1,400 tok +
  35s each), pattern re-derived per run across 5 routines. Change: permanent python3 script
  (env-based creds, message file arg); notify/SKILL.md becomes the owner doc with a 2-line
  invocation; triage/summary Step 4, wake prompt step 6, dispatch digest step all reference
  it as one unchained command with **literal** /tmp paths (no mktemp, no `$VAR`, no export).
- **P2. Remove all `rm` cleanup from skills/prompts.** Justification: `Bash(rm:*)` deny is
  absolute; 7 occurrences of denied rm in triage alone, occasionally killing the chained
  send. Change: delete cleanup steps; add one note (deny survives bypass; leftover /tmp
  files are harmless; never chain rm onto a send). Skills write digests via
  `cat > <literal path> << 'EOF'` (proven allowed) so leftover files are overwritten, which
  also kills the Write-tool "File has not been read yet" class.
- **P3. morning-proposals: saturation pre-check + correct repo-list pointer.** Justification:
  5 no-op sessions burned ~9,000 tok each incl. one 9-way fan-out; 4 runs wasted 80-190s
  hunting a repo list the prompt mis-locates. Change: prompt points at
  `launchd-runtime/repos.conf`; step 0 runs one `gh` loop counting `proposed` issues and
  halts before any subagent fan-out when saturated; fan-out only for non-saturated repos.
- **P4. wake-status-digest prompt: use telegram-send; scan only the last 2 days of logs.**
  Justification: send re-invented 5/21 runs (~350 tok); full `ls -la` of 300+ log files
  every run (~100 tok + extra turns). Change: prompt names the sender script and restricts
  the scan to today's/yesterday's log files.
- **P5. dispatch-tasks: per-repo queue loops; zsh-safe syntax.** Justification: one gh flake
  inside a 9-repo mega-loop cost ~8,000 tok + 2,500s; bash-4 assoc arrays fail under zsh.
  Change: SKILL.md instructs per-repo loop with per-repo failure isolation; POSIX-safe syntax note.

### Tier 3 — context-size reduction (dedup)

- **D1. Split BASELINE.md** into core principles (~1.5KB, everyone) + `BASELINE-CODING.md`
  (coding detail; only work-on-task / iterate-on-pr read it). Saves ~1,375 tok/run for
  propose-tasks, similar for other non-coding skills.
- **D2. repos.conf as single source** — replace inline repo arrays in morning-triage,
  dispatch-tasks, daily-summary with `source repos.conf` (+ add `REPOS_BY_PRIORITY`).
  ~250-1,000 bytes/run each + kills 4-way drift.
- **D3. morning-triage delegates to triage-repo** instead of re-implementing fetch+classify
  (~650 tok/run; also removes rule drift).
- **D4. DEPENDS-ON algorithm → `docs/depends-on-convention.md`**, referenced by
  dispatch-tasks + daily-summary (~450 tok/run; prevents an accidental 11.9KB cross-load).
- **D5. notify progressive disclosure** — setup walkthrough + rationale → `notify/reference.md`
  (~365 tok/run on every notify-using routine).
- **D6. Prompt trims** — drop retirement history/absolute times/skill-paraphrases from the 5
  routine prompts (~85-150 tok/run each; removes 3 confirmed prompt-vs-skill contradictions,
  incl. the P3 repo-list bug and two conflicting quiet-day wordings).
- **D7. propose-tasks line-count & quiet-day dedup** (~275 + ~100 tok/run).

### Tier 4 — verify-gate repair

- **T1. Fix 4 pre-existing anchor test bugs** (path canonicalization via `pwd -P` in 3
  wrapper tests; `${missing[*]-}` for bash-3.2 in the deny-baseline test) so `make test`
  is green and future changes are actually gated.

### Measured-expectation summary

| Bucket | Expected effect |
|---|---|
| C1 (pin Opus) | −$13/30d now; −$25/30d with scan-routing option |
| P1+P2 (send + rm) | ~2,000-3,000 tok + 50-90s per triage/summary/proposals run; removes the top denial class from all 5 routines |
| P3 (saturation pre-check) | up to 9,000 tok + 300s on saturated days (observed 5×/21d); backpressure preserved via one aggregated nudge |
| D1-D7 (dedup) | ~2,000-3,500 tok of context per day across routines (audit: BASELINE core landed at 3.7KB, not the planned 1.5KB, so D1 realizes ~890 of the ~1,375 tok/run); removes 4 drift surfaces |
| R1+R2 (auth+stall) | converts multi-day silent outages into one actionable alert; startup-stall class caught by the double-hung canary in ~2min (mid-run stalls remain bounded by wall-clock budgets) |
| R4+C3 (budget) | ~12 timeout failures/2mo → expected completions, spend still capped at $5/run |

## 5. Verification addendum (research claims)

Filled by the adversarial verification pass; see `docs/assessments/` git history for
any post-audit corrections.

- CONFIRMED `--output-format json` result envelope (live run: `total_cost_usd: 0.020277`,
  `modelUsage` keyed by model id, `permission_denials`, `subtype: success|error_max_turns`).
- CONFIRMED `--json-schema` validated structured output; invalid schema hard-fails (2.1.205+).
- CONFIRMED `--disallowedTools` bare-name context removal vs scoped runtime deny; `dontAsk` mode.
- CONFIRMED `--bare` (docs: recommended for scripted/SDK calls, future default for `-p`).
- CONFIRMED OpenTelemetry export env vars.
- CONFIRMED `setup-token`, `--max-budget-usd`, `--fallback-model`, `--model`, `--agents` (local `--help`).
- CONFIRMED PreToolUse hooks: `permissionDecision: "deny"` + `permissionDecisionReason`
  fed back to the model, `updatedInput` rewrite; deny-hooks fire even under
  `--dangerously-skip-permissions` (allow-hooks cannot loosen settings denies).
  Stop + SessionEnd hooks exist (SessionEnd async, reporting-only).
- CONFIRMED skill frontmatter: `disable-model-invocation`, `context: fork` (+ `agent`),
  per-skill `model` and `effort`, `disallowed-tools`, dynamic `!`command`` injection;
  official guidance: keep SKILL.md under 500 lines, move detail to separate files.
- CONFIRMED stream-json `system/api_retry` events with error category
  `authentication_failed` (emitted on retryable failures only); stall watchdog env vars
  `API_FORCE_IDLE_TIMEOUT`, `CLAUDE_ENABLE_STREAM_WATCHDOG`, `CLAUDE_CODE_RETRY_WATCHDOG`.
- CONFIRMED native cloud Routines (research preview): `/schedule` + claude.ai/code/routines,
  cron ≥1h, GitHub repo access with `claude/`-prefixed branches. Assessed: not adopted now
  (research preview; this stack's Telegram/label workflow is local), revisit at GA.
- CONFIRMED subagent frontmatter (`.claude/agents/*.md`): `model`, `effort`, `maxTurns`,
  `background`, `tools` allowlist — cheap-model fan-out routing is officially endorsed.
  Candidate follow-up for propose-tasks' per-repo scans (deferred, needs its own eval).

## 6. Implementation status

All Tier 1-4 items implemented on branch `skill-efficiency-2026-07` (9 parallel work
packages with disjoint file ownership, then audit fixes). Full suite green: 100/100
(`make test`), 15/15 unit, 20/20 static.

## 7. Adversarial audit

Two audit layers ran against the implementation.

**Layer 1 (inline, during implementation):** the first-output stall watchdog shipped by
the runtime package was refuted and reverted before landing — see R2 for the reasoning
(log growth cannot signal liveness in `-p` print mode; healthy morning-proposals runs
are silent past the 240s deadline). Replaced by the double-hung-canary abort.

**Layer 2 (7-auditor adversarial workflow):** per-package refuters, a cross-file
consistency auditor, a plan-fidelity auditor, and an independent re-derivation of every
number in this report from the raw metrics. 27 findings (10 major, 17 minor), all
fixed on the branch:

- *Numbers (this report):* component breakdown had been computed at all-Fable pricing
  (~1.7× overstatement — corrected to mixed-pricing figures); timeout attribution
  (9/12 at the 600s cap, not 12), stall-run list, 8.9h-run date, and drift-date
  enumeration corrected. The headline totals ($83.63 / $70.61 / $42.37 / $14.60 excess)
  and denial counts were verified exact.
- *Behavior regressions caught:* `telegram-send` had silently dropped
  `disable_web_page_preview` (restored); the proposals saturation pre-check silenced
  propose-tasks' contractual backpressure nudge (replaced with one aggregated nudge on
  all-saturated days); the wake-status 2-day log glob lost the silent-failure roster
  (explicit five-routine roster added); `--max-budget-usd 2.00` default would have
  truncated the very runs R4 saves (raised to 5.00).
- *Denied-form leaks caught:* morning-triage's repos.conf snippet used bash-only
  `${!VAR}` indirection (replaced with a `cat`-once, no-shell-iteration instruction);
  its triage-repo delegation imported `REPO="$0"` / `STALE_DATE=$(...)` (triage-repo's
  fetch commands made literal-substitution, headless-safe); daily-summary Step 1 and
  notify Step 3 still instructed `VAR=$(...)` forms (rewritten); request-approval still
  carried the full deprecated inline sender and a dangling reference to notify's old
  pattern (rewritten to the shared sender).
- *Runtime:* the auth canary ran outside caffeinate's sleep assertion (now wrapped);
  `CLAUDE_CODE_OAUTH_TOKEN` plumbing had been claimed but not landed (now loaded from
  settings.json env like the Telegram creds, with setup documented in the runner).
- *Baseline:* "Push back when warranted" had vanished in the split (restored to core);
  skill-assess's conformance checklist still assumed the pre-split BASELINE layout
  (updated); dispatch's worktree note said "worktree-relative paths" though Read/Edit
  require absolute paths (reworded to "absolute paths under the worktree root").

Residual risks accepted: BASELINE core is 3.7KB vs the 1.5KB target (D1 partially
realized, noted in §4); telegram-send messages over Telegram's 4096-char limit are
rejected by the API and surfaced as a send error rather than auto-split (matches the
old inline senders' behavior).

## 8. Pipeline effectiveness baseline (added 2026-07-15)

Follow-up to the efficiency work: objective funnel metrics for
proposal → approval → PR → merge, extracted from GitHub label/PR event history by
`launchd-runtime/bin/pipeline-metrics` (`make funnel`). Two rate families are kept
separate by design: **decision rates** condition on a human decision having happened
(the closest objective proxy for artifact quality); **raw rates** include the
un-reviewed backlog (throughput — dominated by review bandwidth, not quality).
Markers are contract-based since the agent acts under the user's account:
proposal = `proposed`-labeled issue, approval = `approved` label event (human-only),
discard = closed-while-unapproved, agent PR = `task/issue-<N>-*` head branch.

Baseline (all history through 2026-07-15):

| repo | proposals | approved | discarded | pending | appr%·dec | PRs | merged | mrg%·dec | open (age med) |
|---|---|---|---|---|---|---|---|---|---|
| club-site | 38 | 33 | 1 | 4 | 97.1% | 28 | 27 | 100% | 1 (0.3d) |
| StarBonk | 22 | 13 | 4 | 5 | 76.5% | 12 | 6 | 85.7% | 5 (39.3d) |
| club_app | 13 | 8 | 0 | 5 | 100% | 6 | 3 | 100% | 3 (5.3d) |
| StarBonk-backend | 8 | 0 | 0 | 8 | — | 0 | — | — | — |
| GameTwo | 9 | 0 | 0 | 9 | — | 2 | 0 | — | 2 (57.8d) |
| engine-toolkit / game-engine / portfolio-site | 18 | 0 | 0 | 18 | — | 0 | — | — | — |
| personal | 0 | — | — | — | — | 0 | — | — | — |
| **Total** | **108** | **54** | **5** | **49** | **91.5%** | **48** | **36** | **97.3%** | 11 |

Readings:
- **Quality, by the human's own revealed judgment, is high**: 91.5% of decided
  proposals were approved; 97.3% of decided agent PRs merged (36/37). The agents'
  output is not the problem.
- **Throughput is bimodal, and the backlog is concentrated**: 35 of the 49 pending
  proposals sit in five repos that have never had a single proposal decision
  (StarBonk-backend, GameTwo, engine-toolkit, game-engine, portfolio-site). The proposal
  engine kept feeding repos the human doesn't currently review — exactly what the
  P3 saturation pre-check now stops. Active repos turn fast (club-site: 2.9d
  median to approval, PRs merged in hours).
- **Unit economics**: 10 agent PRs merged in the 30-day cost window against $83.63
  of routine spend → **$8.36/merged PR all-in**, or **$4.89/merged PR** attributing
  only the production routines (proposals $22.10 + dispatch $26.80). At the pinned
  Opus pricing this becomes ~$7.00 / ~$4.10.
- Caveat: N is small and 2 months young — treat these as the baseline for a trend
  line, not a verdict. Goodhart guard: if any skill is ever tuned against these
  rates, pair it with a countermetric (scope mix / lines-touched per merged PR) so
  "more approvable" cannot degenerate into "smaller and duller".

Suggested cadence: run `make funnel` monthly (or wire a routine); a collapsing
approval-given-decision rate flags proposal-quality drift, a growing
never-decided backlog flags repos to drop from the proposal rotation.
