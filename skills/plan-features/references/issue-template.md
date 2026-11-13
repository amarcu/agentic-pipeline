# The issue body

Use it literally. It is the shape `propose-tasks` cuts from too, so a worker reads one format
whichever session filed the issue.

```markdown
## Goal
<one sentence: what exists once this lands>

## Why now
<the FOCUS.md line this comes from, quoted>
<DRIVEN BY … — driven repos only>

## Breakdown
- <2–5 independently landable sub-units>

## Implementation plan (advisory)
1. <step — names the file(s) it touches>
2. <…>

## Acceptance criteria
- [ ] <testable>
- [ ] <verify gate line from CLAUDE.md>
- [ ] Draft PR opened against `<base>`

## Estimated size
<XS | S | M> — <one line>

BASE BRANCH: <name>

## Reference files
- <path>

<!-- plan-features run:<YYYY-MM-DD> focus:"<focus line>" -->
```

- The plan is advisory, numbered, ≤ `MAX_PLAN_STEPS` steps, each naming its files. It must **never**
  contain the phrase "depends on" — the only dependency syntax is a line beginning `DEPENDS ON #N`,
  outside the plan.
- `M` is the largest size one session may take. Anything bigger is two issues.
- `SCENE: allowed` is not in the template: add it as its own line under `BASE BRANCH:` only when the
  feature does nothing until objects exist in a scene, and only in a repo whose CLAUDE.md names the
  line (StarBonk does). It pre-approves scene and prefab wiring for that one issue. A feature shipped without its wiring compiles, passes its tests and does
  nothing in the game (StarBonk #67 and #68, 2026-10-17).
- `BASE BRANCH:` is `$BASE` from Step 0 — `get_repo_base`, the repo's working branch — unless FOCUS.md names another.

The `plan-features run:` comment on the last line is what a later session matches an issue to the
focus line it came from, so it is never edited or dropped — `references/retiring.md` reads it.
