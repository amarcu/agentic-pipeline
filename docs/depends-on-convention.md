# DEPENDS-ON convention

Shared convention for declaring dependencies between GitHub issues. Owned here so the
grammar and parsing algorithm exist in exactly one place — `dispatch-tasks` (queue
building, Step 1) references this file instead of restating it. `daily-summary` no
longer parses the grammar: since v1.0 its `blocked` bucket is the `blocked:*` label and
an issue with an unmet dependency simply counts as waiting.

## Grammar

Issue bodies declare dependencies with `DEPENDS ON` (case-insensitive — accept
`DEPENDS ON`, `Depends on`, `depends on`, with or without colons, comma-separated for
multiple deps). The convention supports both same-repo and cross-repo deps:

```
DEPENDS ON #5                             ← same-repo
DEPENDS ON amarcu/StarBonk-backend#15     ← cross-repo
DEPENDS ON: #5, acme/game-engine#8           ← mixed
depends on #5 and acme/foo#7
```

## Parsing algorithm

Run for each line containing "depends on":

1. **Cross-repo first**: extract every `<owner>/<repo>#<N>` reference. Record each as a
   tuple `(owner/repo, N)`. Use a regex like `([\w-]+/[\w.-]+)#(\d+)`.
2. **Strip those matches from the line** so they don't double-match in step 3.
3. **Same-repo second**: extract every bare `#<N>` from the stripped line. Record as
   `(current-repo, N)`.

This order matters — without stripping, `acme/foo#7` would match both `(acme/foo, 7)`
AND a phantom `(current-repo, 7)`.

## Checking each dep's state

For each `(repo, N)` tuple:

```bash
gh issue view <N> --repo <repo> --json state,title
```

Resolution rule: a dependency is **satisfied** if its state is `CLOSED` (regardless of
how — merged PR closing it, manual close, wontfix, etc.). It is **unmet** if `OPEN`.

## Cross-repo failure modes

- `gh` returns 404 (repo doesn't exist, no access, typo in `owner/repo`) → defer with a
  clear warning, do NOT silently treat as satisfied. Output:
  `WARN: cross-repo dep <owner/repo>#<N> could not be queried (404). Treating as unmet.`
- `gh` succeeds but the dep issue is `OPEN` → defer (same as same-repo).
- `gh` succeeds and dep is `CLOSED` → satisfied.

## Coordination caveat

The dependency model only verifies "the upstream issue is closed." It does NOT verify
"the upstream change is deployed." For repos where backend-must-deploy-before-frontend
matters (per CLAUDE.md), the human is responsible for sequencing approval — only approve
the frontend issue once the backend's deploy is confirmed.
