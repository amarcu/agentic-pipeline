# Filing an assessment issue

Read at Step 5, and only on an `--update` run. Nothing here happens without that flag.

## The labels have to exist first

`skill-maintenance` and `automated` are not GitHub defaults and neither exists on a fresh clone of
this repo — an `--update` run that assumed them failed at the first `gh issue create` with
`could not add label: 'skill-maintenance' not found`, which is why this step exists.

```bash
gh label create skill-maintenance --color D4C5F9 --description "Findings from skill-assess" --force
gh label create automated --color EDEDED --description "Opened by a scheduled routine" --force
```

`--force` turns a second run into an update rather than an error, so this is safe to run weekly.

## Check for the marker before writing

One list call covers every finding; match locally rather than trusting GitHub's search index to
have picked up an HTML comment.

```bash
gh issue list --repo amarcu/agentic-pipeline --label skill-maintenance --state open --json number,title,body --limit 100
```

A body carrying **both** `target=<skill>` and this finding's `finding=<slug>` is this finding,
already filed. Print `HALT: skill-assess already-filed <skill>/<slug>` and write nothing for it.
Matching on `target=` alone would be wrong: one skill can have several open findings, and the
second one would read as already filed and never get an issue.

## Deriving the `finding=` slug

The slug has to come out the same on every run that sees the same defect, so it is derived from the
finding's source rather than from the title a model wrote for it:

| Finding | Slug |
|---|---|
| A `FAIL:` line from the static suite | the message text, lowercased, every run of non-alphanumerics folded to `-`, trimmed, first 48 characters |
| A `description` that no longer matches the body | `description-drift` |
| A path or command in the body that does not resolve | `path-<basename of the path, slugged>` |

The suite's messages are fixed format strings, so slugging one is deterministic while the defect
lasts — `allowed-tools grants bare 'Bash' — scope it, e.g. Bash(gh issue:*)` becomes
`allowed-tools-grants-bare-bash-scope-it-e-g-bash-gh`. The path case carries its own discriminator,
so two unresolvable paths in one skill are two findings and get two issues.

## Create it

```bash
cat > /tmp/skill-assess-issue.txt << 'EOF'
<the finding, what is wrong, and what to fix>

<!-- agentic-skills: skill=skill-assess repo=amarcu/agentic-pipeline target=<assessed-skill> finding=<slug> routine=${ROUTINE:-interactive} run=${ROUTINE_RUN_ID:-none} model=claude-sonnet-5 -->
EOF
```

```bash
gh issue create --repo amarcu/agentic-pipeline --label skill-maintenance,automated --title "skill: <name> — <summary>" --body-file /tmp/skill-assess-issue.txt
```

## Why the marker has no `issue=` field

S6's shape uses `issue=<n>` on an issue, but that number does not exist until after the body is
written. `target=` plus `finding=` carries the identity instead: together they are the key the
idempotence check greps for, and they are what a reader needs — which skill this issue is about and
which of its defects — rather than which issue this issue is.

## One issue per finding, not per skill

A skill with a broken path and an unscoped `allowed-tools` gets two issues, because they are two
pieces of work and they close separately. `target=` is the same on both and `finding=` is not,
which is the whole reason the second field exists.
