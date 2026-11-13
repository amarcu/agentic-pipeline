---
domain: universal
kind: coding
version: 1.0.0
status: active
last-assessed: 2026-09-06
---

## Purpose
The technical artist for effects. Given a written brief and a reachable Unity editor it authors
shaders, HLSL, particle and Volume parameters, and proves each iteration with a screenshot read at
full and half size, until the brief is met or the iteration cap stops it.

Exists because the pilot project's look is made almost entirely of effects, and effects that look
fine in code and wrong on screen get merged.

`kind: coding`: it writes shader files and mutates component parameters in a live project.

## Model / budget
- Model: `claude-opus-4-8` — the loop's value is judging a half-size screenshot against a brief
  and choosing the smallest next change; a weaker read iterates on the wrong thing.
- Effort: `high` — every iteration reads two images and the console.
- Typical run: unmeasured. Each iteration is one eval or file write plus a capture; the cap
  (`VFX_ITERATIONS_MAX`) bounds it.

## Dependencies
- Unity CLI `1.0.0-beta.8` or newer at `$HOME/.unity/bin/unity` — `unity command
  screenshot` arrived in beta.8.
- `com.unity.pipeline` installed in the target project (`unity pipeline install`). This edits
  `Packages/manifest.json`, which is must-ask under StarBonk's `CLAUDE.md`, so a human does it once.
- A reachable editor: a GUI editor in state `ready`, or a persistent batch editor launched without
  `-quit`. `references/loop.md` has both recipes.
- `sips` for the half-size copy.
- The official Unity skills `urp-postprocessing` and `shader-graph-create-custom-node`, installed
  per machine under `~/.claude/skills/` (their repository's licence is NOASSERTION, so they are not
  vendored here).
- `VFX_ITERATIONS_MAX` in `launchd-runtime/repos.conf`.

## Design notes
**The loop is the skill.** Author, capture, read, judge, adjust the smallest thing. Without the
capture step this is a shader-writing skill that reports success on compilation, which is how
effects that look fine in code and wrong on screen get merged.

**Half size is the test.** Both a store grid and a crowded scene are half-size
problems; a rule met at 1080p and missed at 960 is missed.

**Structure is someone else's.** Adding objects, reparenting, editing `.meta` and installing
packages are the four things that break a project silently, and all four are must-ask in the
target repo. The skill refuses them rather than asking, because a scheduled run has nobody to ask.

**Best-effort is a real outcome.** Stopping at the cap with an honest note about which rules were
missed is worth more than an iteration that overshoots the brief.

## Known Issues
- Judges still frames only. Time-based effects (ramps, opening animations, pops) are
  judged at their end state; a capture sequence is not yet built.
- The batch-editor path holds a licence seat while resident; on the pipeline host that is the same
  Personal seat the gate uses, so the two must not run concurrently.
- Not yet exercised end to end on StarBonk: the pipeline package is not in its manifest yet.

## Changelog
- 2026-09-06 (v1.0): Created, to the skill standard. Loop recipes under `references/`.
