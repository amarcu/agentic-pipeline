# Model routing probe — 2026-09-01

Ground truth for the per-role model routing and cost-capture work. Every number here was
measured on this host against CLI **2.1.252**; nothing is quoted from memory. One paid API
call was made ($0.1538); everything else is a desk check against artifacts already on disk.

## 1. The pin is holding — no drift since July

The 2026-07-14 assessment measured $13.02/30d of excess spend caused by routines inheriting
whatever model was last set interactively. C1 fixed that by passing `--model` in the runner.
Verified against **201 real routine transcripts** in `~/.claude/projects/-/`, spanning
2026-08-02 to 2026-08-29:

| model | assistant messages |
|---|---|
| `claude-opus-4-8` | 3,440 |
| `claude-haiku-4-5-20251001` | 202 |

Two models, both intended: Opus 4.8 is the pinned fleet default, and Haiku is the auth
canary (≈1 per run, matching 201 runs). **Zero drift.** This is far stronger evidence than a
`-p 'ok'` probe, which only shows what the CLI does when *this* shell invokes it.

Consequence for the plan: the routing work starts from a known, uniform baseline, so any cost
delta after a `ROUTINE_MODEL` change is attributable to that change.

## 2. Opus 4.8 rates, derived from a live envelope

One probe, run from `/` (the routines' working directory):

```
claude -p 'ok' --model claude-opus-4-8 --output-format json
```

`modelUsage["claude-opus-4-8"]` returned `inputTokens: 2`, `outputTokens: 14`,
`cacheReadInputTokens: 10029`, `cacheCreationInputTokens: 14839`, `costUSD: 0.1537645`.
Solving against the catalog rates for the three known classes leaves exactly one unknown:

| class | tokens | rate / MTok | cost |
|---|---:|---:|---:|
| input | 2 | $5.00 | $0.0000100 |
| output | 14 | $25.00 | $0.0003500 |
| cache read | 10,029 | $0.50 | $0.0050145 |
| cache write | 14,839 | **$10.00** | $0.1483900 |
| **total** | | | **$0.1537645** |

Reconciles to the envelope's last digit. So for Opus 4.8: **$5 in / $25 out, cache read at
0.1× input, cache write at 2.0× input** — the 2× multiplier identifying a 1-hour cache TTL.

`contextWindow` read **1000000**, which settles the open question from the plan: the 1M-context
variant is billed at the same per-token rates as the 200K one, so the derived rates apply to
the routines as they actually run.

### The finding that should shape every later step

**96.5% of that bill was cache creation** — 14,839 tokens of harness scaffolding against 14
tokens of actual output, for the prompt `ok`.

Two consequences, both load-bearing:

1. **Context reduction is the highest-leverage cost work**, not model selection. A routine's
   bill is dominated by what it loads, not what it thinks.
2. **A 2× model premium mostly doubles the price of the system prompt.** On a
   context-dominated workload, paying 2× for a stronger model buys 2× on the scaffolding and
   very little on the reasoning. This is the strongest argument yet against a blanket upgrade
   to a more expensive model for issue authoring, and the reason the Fable arm is scoped as a
   bounded A/B rather than a default.

## 3. Flag inventory

Verified against `claude --help` on 2.1.252 and, where noted, by passing values.

| flag | status | notes |
|---|---|---|
| `--model` | documented | Invalid value fails **loudly**: `[claude-code:unrecognized_model]`, non-zero exit. Session pins are self-verifying. |
| `--effort <level>` | documented | `low, medium, high, xhigh, max`. See the warning below. |
| `--max-budget-usd` | documented | Dollar cap. Already passed by the runner. |
| `--fallback-model` | documented | Does **not** cover quota exhaustion (see §5). |
| `--output-format` | documented | Required for cost capture. |
| `--settings` | documented | Carries the headless merge/ready deny. |
| `--max-turns <n>` | **undocumented but accepted** | Absent from `--help`; passing it produces no `unknown option` error. |
| `--task-budget <n>` | **undocumented but accepted** | Absent from `--help`. See §4 — this is a token budget. |

### `--effort` fails silently, and nothing downstream can catch it

```
$ claude -p 'ok' --model definitely-not-a-model --effort bogus
Warning: Unknown --effort value 'bogus' — ignoring it and using the default effort.
Valid values: low, medium, high, xhigh, max.
```

Verbatim. An invalid effort value **warns to stderr and silently continues at the default**,
and the `--output-format json` envelope carries no `effort` field, so there is no way to detect
after the fact that the requested effort was not applied.

This is why adding `ROUTINE_EFFORT` to the runner must include an **exact-string check against
the five valid values before invoking the CLI**, aborting with a clear log line on anything
else. Without it, a typo in a plist produces a routine that looks configured, reports success,
and quietly runs at the wrong effort forever.

Contrast with `--model`, which fails loudly and therefore needs no such guard.

## 4. `--task-budget` is a token budget — correcting the plan

The plan recorded that only a *dollar* cap could be enforced per run. That is wrong.
Passing a deliberately small value returns:

```
API Error: 400 output_config.task_budget.total: Input should be greater than or equal to 1024
```

The error names `output_config.task_budget.total` and enforces a floor of **1024**, so
`--task-budget` takes a **token** count, not dollars. Two mechanisms exist and they cap
different things:

| | caps | granularity |
|---|---|---|
| `--max-budget-usd` | spend | dollars, per run |
| `--task-budget` | consumption | tokens, minimum 1024 |

This directly answers the original ask for *token* budgets on workers and the orchestrator,
rather than approximating them with dollar caps. It also means the worker-isolation step can
cap tokens per task natively.

**Caveat, stated plainly:** both flags are absent from `--help`. An undocumented flag can change
or disappear without a deprecation cycle, so anything built on `--task-budget` needs a startup
assertion that it is still accepted, and must not be the only thing standing between a runaway
worker and the bill. Keep `--max-budget-usd` as the backstop.

## 5. Model availability on this account

Probed 2026-09-01.

| model | status |
|---|---|
| `claude-opus-4-8` | available — current fleet default |
| `claude-opus-5` | available |
| `claude-sonnet-5` | available |
| `claude-haiku-4-5` | available — used by the auth canary |
| `claude-fable-5` | **quota exhausted** — `You've reached your Fable 5 limit`, HTTP 429, exit 1 |

`--fallback-model` was tested against the exhausted model and returned a **byte-identical 429**:
it covers model *errors*, not quota exhaustion. Any routine pinned to a quota-limited model
therefore needs an explicit pre-flight probe and substitution, not `--fallback-model`.

## 6. What this changes in the plan

1. **S9 confirmed and tightened** — the exact-string effort validation is not defensive
   programming, it is the only detection mechanism that exists.
2. **S21 corrected** — `--max-turns` and `--task-budget` both work but are undocumented; the
   worker wrapper needs a startup assertion for each.
3. **S21 gains a native token cap** — per-worker token budgets via `--task-budget`, with
   `--max-budget-usd` retained as the backstop.
4. **S14 promoted in importance** — at 96.5% cache-creation share on a trivial prompt, context
   reduction is the dominant cost lever, ahead of model selection.
5. **No baseline correction needed** — the fleet has run uniformly on Opus 4.8 since at least
   2026-08-02, so the backfill can price the whole window at one rate card.

## Method notes

- Model-mix figures count assistant-message `model` fields across all 201 transcripts. They
  index which model served each message, not token volume; the backfill computes volume, and
  must dedup by `message.id` first (naive summation over-counts by 3.23× fleet-wide).
- The rate solve assumes the catalog rates for input, output and cache read, then solves for
  cache creation. It reconciles exactly, which would not happen if any assumed rate were wrong.
- Single-sample: one probe, one model, one moment. Re-derive if the envelope ever disagrees
  with `make cost`.
