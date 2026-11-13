---
domain: universal
kind: readonly
version: 2.0.1
status: active
last-assessed: 2026-09-03
---

## Purpose
Classifies one repo's open issues and pull requests into fixed urgency buckets and prints the
`triage-repo/2` block. `morning-triage` is the primary consumer — it runs the script once per repo
and assembles the digest from the blocks — but the skill stands alone for "what is open on this
repo, and which of it is waiting on me".

`kind: readonly` — it calls `gh` twice and prints. It creates no issue, applies no label, sends no
message.

## Model / budget
- Model: `claude-sonnet-5` — the classification is the script's; the model runs one command and
  relays its output.
- Effort: `low` — there is no judgement left in the turn. Anything the model would have to decide
  is a bug in the script.
- Typical run: two `gh` calls, ~1-2 s per repo, and a block that is ~15 lines for a quiet repo.
  Not separately measured as a standalone invocation — it runs inside `morning-triage`'s turn, so
  its tokens land in that routine's `runs.jsonl` row.

## Halt Conditions
- `gh` is not on `PATH`, or a `gh` call exits nonzero: the block becomes `REPO:` / `FORMAT:` /
  `Scanned:` / `ERROR:` and the script still exits 0. This is deliberate — the caller is usually
  part-way through a roster of thirteen repos and one that is down must not end the routine.
- `$0` is not `owner/repo`, or `--days-stale` is not a whole number: usage line, exit 2, no GitHub
  call. A bad argument is the caller's bug, not a repo that is unreachable, so it gets a distinct
  exit rather than an ERROR block that would read as "the repo is down".
- Nothing else halts. There is no partial-output path: either both sections print or the ERROR
  block does.

## Dependencies
- `gh` CLI, authenticated for the target repo. No `jq` on `PATH` — the classification runs inside
  gh's own embedded jq via `--jq`.
- `/bin/date` with BSD `-v` relative-date arithmetic (macOS). A GNU-coreutils host would need
  `-d "<n> days ago"` instead.
- `launchd-runtime/repos.conf` for `get_stale_days`, read by the caller that chooses `--days-stale`.

## Known Issues
- Classification is label-driven, so a repo with no labelling convention puts almost everything in
  `active` or `stale`. That is the honest answer rather than a guess: title keywords are
  deliberately not consulted, because a keyword match once drove an autonomous escalation.
- `ci=` is derived from `statusCheckRollup`, which is empty for a repo with no CI. Those PRs report
  `ci=none`, which is not the same as passing.
- The 50-issue / 30-PR ceilings are silent: a repo past either is truncated by GitHub's own
  ordering and the block does not say so. No tracked repo is close to either.

## Changelog
- 2026-09-04 (v2.0.1): Review fixes on PR #21. The script took its stale window only as a bare
  second argument while SKILL.md and META.md documented `--days-stale <N>`, so a human following
  the documentation triaged at the default window and was told `Stale-days: 14` for a run they
  thought they had widened. It now accepts either spelling, refuses both at once, and refuses any
  other extra argument with a usage line and exit 2 — an argument this script does not read is
  refused rather than dropped. A tab inside an issue title also reached the rendered item line:
  bucketing survived it (the field split ends at the separator, which is the first tab) but the
  block is machine-read, so `flat` now folds tabs to spaces alongside newlines and carriage
  returns. Three new tests cover the two spellings, the four ways to get the arguments wrong, and
  a title carrying a tab.
- 2026-09-03 (v2.0.0): Rewritten to `docs/skill-standard.md`; off the contract-exceptions list.
  **Fetch and classification moved out of prose into `scripts/triage-repo.sh`** — the model used to
  re-derive six precedence rules per repo from a template, and the same issue could land in
  different buckets on consecutive mornings. Same data now gives byte-identical output, covered by
  `launchd-runtime/tests/unit/test_triage_repo.sh` (10 tests against a mock `gh`).
  **Breaking — output is now `triage-repo/2`:** a `FORMAT:` line, `Stale-days:`, both precedence
  chains stated in-band, per-bucket counts on each section line, and `labels=[…]` closing every
  item line. The v1 block carried no labels at all, so a consumer could name a blocker it could not
  then evidence. **New `proposed` bucket** (label `proposed` without `approved`), ahead of
  active/stale, and `proposed`/`approved` items are excluded from `stale` — previously every agent
  proposal awaiting the human's approval read as `stale` forever, which is what kept
  `morning-triage`'s quiet-day halt from ever firing. PR buckets are now `draft-agent` / `ready` /
  `stale` / `draft` with CI state carried as a field, replacing the overlapping v1 set.
  Frontmatter scoped (`allowed-tools` names the one script prefix, replacing bare `Bash`), given
  `model: claude-sonnet-5` / `effort: low` (S2) and `disable-model-invocation: true` — no skill
  invokes this one through the `Skill` tool, `morning-triage` runs the script directly by absolute
  path, so the flag costs nothing and stops Claude loading it on its own judgement.
- 2026-07-14 (v1.1.1): Steps 1-2 fetch commands made headless-safe — repo name and stale-cutoff date substituted literally instead of `REPO="$0"` / `STALE_DATE=$(date ...)` (VAR=$() forms are permission-denied in scheduled runs). Step 4 `blocking` lines now carry `updated <N>d ago` so morning-triage's escalation preconditions have the data they need (2026-07-14 audit).
- 2026-07-08 (v1.1.0): Aligned `blocking` classification with morning-triage — labels only (`blocker`/`critical`/`security`). Dropped `bug` from the blocking set and demoted title keywords ("broken"/"failing"/"urgent") to a digest-only `(keyword match)` soft signal that never drives escalation.
- 2026-05-06: Initial version
