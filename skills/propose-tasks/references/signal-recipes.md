# Signal recipes

Read this at Step 4, before running a grep. It holds the per-stack TODO sweep, the exclusions that
keep one command from dumping tens of kilobytes into a headless run, and the rule for turning a hit
into a candidate.

## The four signals, in order

Step 4 takes them in this order and stops once `MAX_PER_RUN` candidates are in hand.

1. **Open untriaged issues** — `gh issue list --repo "<owner/repo>" --state open --json
   number,title,body,labels,author --limit 30`. Keep human-authored issues carrying neither
   `proposed` nor `approved`; a large one yields one scoped slice, never the whole.
2. **TODO / FIXME / HACK / XXX in live code** — the grep recipes, exclusions and output cap are
   below, per stack.
3. **Recent git activity** — `git -C "<repo path>" log --oneline --no-merges -20`, *context only*:
   it rules candidates out (just-refactored code, active branches) and never in.
4. **Thin documentation** — at most one docs proposal per run, against code the repo ships.

## Rules every recipe answers to

- **Resolve the path with `get_repo_path`.** Never scan the home directory, and never `find ~`.
- **Always exclude `.claude`.** `work-on-task` keeps worktrees under `.claude/worktrees`, so every
  TODO in the repo appears once more per live worktree. This is the exclusion most worth keeping.
- **Always exclude vendored code, build output, and anything `CLAUDE.md` lists under NEVER touch.**
  A TODO in a dependency is not this repo's work.
- **Always cap the output** with `| head -100`. An uncapped grep on a large repo is the single most
  expensive command this skill can run.

## TypeScript / JavaScript — Next.js, Node

```bash
grep -rn "TODO\|FIXME\|HACK\|XXX" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  --exclude-dir=node_modules --exclude-dir=.next --exclude-dir=dist --exclude-dir=build \
  --exclude-dir=.claude --exclude-dir=vendor \
  "<repo path>" | head -100
```

## C# — Unity

```bash
grep -rn "TODO\|FIXME\|HACK\|XXX" --include="*.cs" \
  --exclude-dir=Library --exclude-dir=Temp --exclude-dir=Obj --exclude-dir=Build \
  --exclude-dir=.claude --exclude-dir=Plugins \
  "<repo path>" | head -100
```

`Plugins` is excluded because Unity keeps third-party packages there; a TODO in one is upstream's.

## Python

```bash
grep -rn "TODO\|FIXME\|HACK\|XXX" --include="*.py" \
  --exclude-dir=.venv --exclude-dir=venv --exclude-dir=__pycache__ \
  --exclude-dir=site-packages --exclude-dir=.claude \
  "<repo path>" | head -100
```

## Rust

```bash
grep -rn "TODO\|FIXME\|HACK\|XXX" --include="*.rs" \
  --exclude-dir=target --exclude-dir=.claude \
  "<repo path>" | head -100
```

## Shell, Make and configuration

```bash
grep -rn "TODO\|FIXME\|HACK\|XXX" \
  --include="*.sh" --include="Makefile" --include="*.mk" --include="*.yml" --include="*.yaml" \
  --exclude-dir=node_modules --exclude-dir=.claude \
  "<repo path>" | head -100
```

## A stack not listed here

Read the repo's `CLAUDE.md` for its source extensions and its build directory, then write the same
shape: the extensions in `--include`, the build output and dependency directories in
`--exclude-dir`, `.claude` always, and the `head -100` cap.

## Turning a hit into a candidate

A hit is a candidate only when all three hold:

1. **The code is live.** `git -C "<repo path>" log -1 --format=%ar -- <file>` returns something
   recent enough that someone still owns the file. A decade-old TODO in code nobody has touched is
   archaeology, not work.
2. **The comment makes an actionable claim.** "TODO: handle the empty-cart case" is one. "TODO:
   think about this" and "HACK: works for now" without a stated problem are not — there is no
   acceptance criterion to write from them.
3. **The file is in bounds.** Not vendored, not generated, and not on `CLAUDE.md`'s NEVER list.

Quote the path and line in the issue's `## Why now`. A proposal whose signal cannot be pointed at is
a proposal that was invented.

## The line-count exclusion, in full

BASELINE Principle 2: line count is not a quality signal. Never propose splitting a file because it
is long — **even if** the repo's `.cursorrules`, `CLAUDE.md` or style guide states a hard cap. Such
a mandate is a hint for review attention, not a proposal trigger; the standing example is a batch of
"Split X.cs" proposals from 2026-05-13 that went stale unapproved, every one of them justified by
size alone.

A split proposal needs an observable coupling problem, named in the `## Why now`:

- changes to two unrelated concerns keep colliding in the same file during review;
- a constant table or helper is duplicated across files and the copies have already drifted;
- one file carries two responsibilities the rest of the codebase has to reason about separately;
- a change the repo actually needs is blocked because the surrounding code is tangled.

If the rationale you can write is "this file is 900 lines", drop the candidate.
