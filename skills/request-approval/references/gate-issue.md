# The gate issue, the message, and what gets gated

Read this at Step 2, and again whenever a tier is not obvious. It holds the two templates and the
list that decides `--tier`.

## The issue body

Write it to `/tmp/request-approval-issue.md` and pass it with `--body-file`. Every value is
substituted literally — the model writes the date it computed, not a `$(date -u …)` the shell would
have to run, and never `VAR=$(gh issue create …)`. Both forms are permission-denied in headless
runs, and a body assembled by a denied command is a gate that silently never existed.

```markdown
## Approval needed

**Action:** <the action, verbatim>
**Tier:** <soft|hard>
**Requested:** <YYYY-MM-DD HH:MM UTC, written literally>

**Context**
<--context, or "none given">

Approve: add the `approved` label, or comment a line starting with `/approve`.
Decline: close this issue.

<!-- agentic-skills: skill=request-approval repo=<owner/repo> issue=- routine=${ROUTINE:-interactive} run=${ROUTINE_RUN_ID:-none} model=claude-sonnet-5 -->
```

The marker is the last line. `issue=-` is deliberate: `gh issue create` assigns the number after the
body is written, and the issue is its own identity — the marker's job here is saying which run asked
for what.

`ROUTINE` and `ROUTINE_RUN_ID` are exported by `launchd-runtime/bin/_run.sh`; an interactive
invocation gets the defaults shown.

## The Telegram message

Plain text — the sender posts without `parse_mode`, so `<`, `>` and `&` need no escaping.

```
APPROVAL NEEDED (<tier>)

<action>

Repo: <owner/repo>
Issue: <url>
Approve: add the `approved` label or comment /approve. Decline: close it.
```

Written to `/tmp/request-approval-msg.txt` and sent as one unchained command. The recipe, and every
constraint on it — the literal path, no `mktemp`, no `VAR=$(...)`, no chaining, no cleanup, and
never a retry on a perceived failure — live in
the `notify` skill's `SKILL.md` and nowhere else.

## What takes `hard`

The routine stops entirely. Nothing further in that run.

- Merging a pull request, or marking one ready.
- Closing an issue or a pull request.
- Pushing to a protected branch, or promoting anything to a deploy branch.
- Deleting a branch, a tag, or a file.
- Cutting a release.
- Publishing anything outside the repo — a report, a findings summary, a post.
- Anything that reaches another person: a comment on someone else's PR, an `@mention`, an email.

**The one exemption**: a **draft** pull request opened for an issue that already carries the
`approved` label. That label is the authorization, and it is `work-on-task`'s whole contract — a
gate there would deadlock the pipeline against itself. An ad-hoc draft PR with no approved issue
behind it still gates, and marking any PR ready always gates: a scheduled run has no user to
instruct it (BASELINE, *Merging and Marking PRs Ready*).

## What takes `soft`

The caller may finish the part of its work the gate does not cover, and must not start the gated
part.

- Creating a branch.
- Running a scan or a discovery pass against a target seen for the first time.
- Changing a configuration file whose effect is local to this machine.

## Tiering something the list does not name

Ask three questions in order:

1. **Can it be undone by the person who finds it wrong tomorrow?** If not, `hard`.
2. **Does anyone but this user see it?** If yes, `hard`.
3. **Does it change state outside the working tree?** If yes and both answers above were no, `soft`.

When two of the three are unclear, `hard`. A `soft` gate that should have been `hard` is discovered
by its damage; a `hard` gate that should have been `soft` costs one round trip.

## Neither tier times out

An earlier version of this skill promised that a `soft` gate would "auto-proceed after 4 hours".
Nothing ever implemented the wait, so the sentence described a behaviour the stack did not have —
and the failure mode of believing it is a routine that proceeds on a gate nobody answered. There is
no timer. A gate is cleared by a human or it is not cleared.
