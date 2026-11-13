---
domain: universal
kind: coding
version: 1.0.0
status: active
last-assessed: 2026-09-06
---

## Purpose
The director's read on visual work, applied consistently and without the owner as the bottleneck.
It holds a project's art bible and judges screenshots, capsule mocks and art-touching PRs against
it, producing findings that cite a rule and a region rather than an opinion.

Exists because the pilot project has an owner who can give feedback but is not an artist, no art
director, and a chosen look whose commercial argument is that it reads in a store grid at half
size. Nobody was checking that. This skill applies the project's written brief to every image.

`kind: coding`, not `readonly`: it posts a review comment on someone else's PR, which is a write
that lands on a shared surface, the same reasoning `review-pr` records.

## Model / budget
- Model: `claude-opus-4-8` — the judgement is "does this region break this rule at this scale",
  which is the whole value; a cheaper read produces findings the worker argues with.
- Effort: `high` — each review reads every image twice (full and half size) against every rule.
- Typical run: unmeasured. A single screenshot against a twelve-rule bible should be short; a PR
  with a live editor capture adds a worktree checkout and a screenshot.

## Dependencies
- A bible at `<repo>/agent/ART.md` (or `--bible`). No bible, no review — the skill refuses rather
  than improvise a standard.
- `sips` (macOS) for the half-size copy. The half-size read is the readability test; without it
  silhouette rules cannot be judged.
- Optional: a reachable Unity editor with `com.unity.pipeline` for live captures via
  `unity command screenshot`. Without it, PR reviews judge attached images and say so.
- `ART_FINDINGS_MAX` in `launchd-runtime/repos.conf`.

## Design notes
**Rules, not taste.** The one hard boundary: a rule the bible does not state cannot fail a review.
That is what makes the skill's verdict something a worker can act on and something the owner can
overrule by editing one file. Taste lives in the bible; the skill only applies it.

**Two scales, judged separately.** Palette and lighting are judged at full size; silhouette and
readability only at half size, because a store grid and a crowded scene are both
half-size problems, and a rule that passes at 1080p and fails at 960 has failed.

**The verdict follows mechanically.** Blocker or major present → `changes-needed`. That removes the
"looks fine to me" outcome that a director without a bible produces.

## Known Issues
- Cannot judge motion. Ramps, opening animations and pops are all
  time-based; a still frame catches only the end state. A short capture sequence is the fix, not
  yet built.
- Live capture needs the pipeline package in the target project, which is a `manifest.json`
  change and therefore must-ask under StarBonk's `CLAUDE.md`.
- `sips` is macOS-only; the pipeline host is macOS, so this holds today and is a note for later.

## Changelog
- 2026-09-06 (v1.0): Created, to the skill standard. Bible worked example under `references/`.
