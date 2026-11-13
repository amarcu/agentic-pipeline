---
domain: universal
kind: coding
version: 2.1.0
status: active
last-assessed: 2026-09-03
---

## Purpose
The daily health pass across the tracked repositories, and the human's primary morning signal that
the pipeline is alive and what it is waiting on. Runs `triage-repo`'s script once per repo,
assembles one plain-text Telegram digest grouped by workspace, and opens a tracking issue for any
hard blocker that has sat unmoved for two days.

`kind: coding` — it writes to GitHub: one `Escalation:` issue per qualifying blocker and the
`escalated` label in that repo. It writes nothing to the original item, and no code anywhere.

## Model / budget
- Model: `claude-sonnet-5` — since v2.0.0 the classification is a script, so the remaining work is
  reading structured blocks, grouping them by workspace and composing a digest. That does not need
  Opus, and the routine was measured as the most frequent Opus consumer in the stack.
- Effort: `medium` — the digest still needs judgement (what to name, what to compress, what to drop
  at the length limit), so `low` would flatten it into a wall of counts. Nothing here searches or
  plans, so `high` buys nothing.
- Typical run: not yet measured on the new shape. The comparison to keep is the pre-2.0.0 routine,
  which ran Opus at high effort across all thirteen repos and re-derived the classification per
  repo in prose; the 2026-07-14 assessment costed the re-implementation alone at ~650 tok/run.
  Two changes cut the roster to `ACTIVE_REPOS` (7 repos) and move the classification into the
  script — re-measure from `runs.jsonl` after a week of nightly runs.

## Halt Conditions
- **Quiet day** — every block reports `blocking=0` and `needs-approval=0`, and no escalation was
  created. Prints `HALT: morning-triage all-clear`, sends no Telegram (BASELINE Principle 5).
  Proposed items alone do not break the quiet: they already sit in the human's approval queue and
  a nightly reminder of it is the noise the principle exists to stop.
- **Refusal** — `--repo` names a repo in no roster in `repos.conf`. Nothing is scanned.
- **Send failure** — `telegram-send` exits nonzero. Report its stderr verbatim and stop; never
  retry, which is how this stack once shipped duplicate messages.
- A repo whose block comes back as `ERROR:` is **not** a halt. It is named in the digest and the
  scan carries on — `triage-repo.sh` exits 0 on a gh failure precisely so one unreachable repo at
  04:10 cannot end the routine.

## Dependencies
- `gh` CLI, authenticated for every repo in the roster
- `TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID`, checked by `launchd-runtime/bin/telegram-send`
- `triage-repo/scripts/triage-repo.sh` — run by absolute path, one call per repo
- `launchd-runtime/repos.conf` — `ACTIVE_REPOS`, `REPOS_BY_PRIORITY`, `WORKSPACES`, `get_stale_days`
- `ROUTINE` / `ROUTINE_RUN_ID`, exported by `launchd-runtime/bin/_run.sh`

## Scheduling
Daily via the launchd routine `morning-triage`, whose prompt (`launchd-runtime/prompts/
morning-triage.md`) invokes `/morning-triage` with no arguments.

## Known Issues
- Escalation dedup is a GitHub search (`in:body <url>`), which is eventually consistent. Two runs
  within about a minute of each other could both miss an existing escalation. Nothing schedules
  them that close together.
- The digest's length limit is enforced by the model's own judgement, not measured. If it starts
  arriving truncated by Telegram, the drop-order in Step 5 is the thing to tighten.

## Changelog
- 2026-09-13 (v2.1.0): The `TRIAGE:` line gains `errors=<k>`, the repos whose block came back as
  `ERROR:`. A scan in which every repo errored reports zero of everything and read as a quiet day:
  a smoke rehearsal on 2026-09-12 with no `gh` on PATH did exactly that. The smoke checker now fails
  a run whose `errors` reaches `repos`.
- 2026-09-07: Step 0 now echoes `dry_run=${ROUTINE_DRY_RUN:-0}`, the channel the smoke gate
  (`make smoke`) reaches this skill's dry run through; `BASELINE.md` defines the contract.
- 2026-09-06: Hotfix — removed `disable-model-invocation: true`. It made the Skill tool refuse
  `/morning-triage` on the nights of 2026-09-05 and 2026-09-06: a headless run is handed the
  routine prompt as natural language, so the model invokes the skill through the tool the flag
  blocks. New Step 0 refuses a run with `ROUTINE` unset unless `--dry-run` or `--force` is passed,
  which is the guard the flag was standing in for; `--force` is new.
- 2026-09-04 (v2.0.1): Review fix on PR #21. The routine prompt still said to exit non-zero if any
  required tool failed, which v2.0.0 turned into a contradiction: `triage-repo.sh` reports a repo
  it cannot reach as an ERROR block and exits 0 precisely so the scan continues, and the prompt
  would have had the routine fail a run that worked. The prompt now reserves a non-zero exit for
  failures that stop the routine finishing — `repos.conf` unreadable, `telegram-send` failing, no
  repo scanned at all — and states that a per-repo ERROR block is normal and named in the digest.
- 2026-09-03 (v2.0.0): Rewritten to `docs/skill-standard.md`; off the contract-exceptions list.
  **Step 1 now runs `triage-repo/scripts/triage-repo.sh` by absolute path**, one Bash call per
  repo, instead of telling the model to "apply triage-repo's Steps 1-3" — a pointer with no path
  to a skill the routine prompt forbids it from invoking. No `Skill` call is involved, so the
  prompt's constraint stays true. **Escalation rewritten and moved to `references/escalation.md`:**
  the old recipe interpolated `$(date -u …)`, `"$BLOCKER_REPO"` and `"$BLOCKER_URL"`, none of which
  was ever assigned and all of which are denied forms headlessly, and it applied an `escalated`
  label that nothing ever created — so the whole path would have failed on first use. It is now
  literal substitution throughout, with `gh label create escalated --force` ahead of the create.
  **Stale thresholds and digest sections are no longer hardcoded** for three of six workspaces:
  the threshold comes from `get_stale_days` in `repos.conf` (new) and the digest template is
  generic per workspace, so a workspace added to `repos.conf` is triaged without editing this file.
  Emoji tags in the digest became ASCII (`BLOCK` / `APPROVE` / `REVIEW`), which sort and grep.
  **Routing:** `model: claude-sonnet-5`, `effort: medium`, and the nightly roster is `ACTIVE_REPOS`
  (7 repos) — `--all` widens it to all thirteen. Frontmatter scoped (`allowed-tools` names the nine
  command prefixes the body issues, replacing bare `Bash`) with `disable-model-invocation: true`,
  since the routine prompt is the only caller. Output contract added: one `TRIAGE:` line per run,
  and the quiet-day halt now prints `HALT: morning-triage all-clear`.
- 2026-07-14: Efficiency pass (P1/P2/D2/D3/D7): Step 4 now writes /tmp/morning-triage-digest.txt via literal cat-heredoc and sends with launchd-runtime/bin/telegram-send (no mktemp/export/rm); Steps 1–2 source the repo list from launchd-runtime/repos.conf and delegate fetch+classify to triage-repo; quiet-day paragraph trimmed to a BASELINE Principle 5 reference.
- 2026-07-08: Assessed — no issues found. The BLOCKING label set (`blocker`/`critical`/`security`) is now mirrored exactly by triage-repo v1.1, closing the classification drift between the two skills.
- 2026-05-07: Switched to workspace model (StarBonk, GameTwo, Personal Sites); removed inaccessible repos
- 2026-05-06: Initial version
