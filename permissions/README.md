# permissions — the shared rm / secrets policy for trusted sessions

Two tiers, two threat models. Do not mix them up. The second tier belongs to `anchor/`, an optional
component for driving a session from a phone; a copy of this repository without that folder has
only the first.

| | `permissions/interactive-baseline.json` | `anchor/targets/deny-baseline.json` |
|---|---|---|
| Applies to | Interactive Claude Code and launchd workers, on a machine you control | Phone-driven remote sessions over Telegram |
| Merged into `~/.claude/settings.json` | Yes | **Never** |
| Enforced by | Claude Code permission rules (prompts on no match) | The bridge process, ahead of the approval gate |
| Threat model | Careless command, not hostile operator | **The phone is the attacker** |
| `rm -rf` | Allowed for scratch, temp, and regenerable paths | Blocked outright, and must stay blocked |

The allowlist here must never be copied into the anchor deny-net. That layer
holds against a *hostile approver* — someone with a stolen unlocked phone taps
"Yes" — so it is deliberately absolute, and
`anchor/tests/static/test_deny_baseline.sh` asserts `Bash(rm -rf:*)` is present.

## What this fragment does

**Removes two blanket rules** that were doing more harm than good:

- `Bash(rm:*)` — blocked every deletion anywhere, including session scratchpads
  and build output. Because a deny always beats an allow, no narrower rule could
  ever take effect while it was present.
- `Bash(cat *.env*)` and its `head`/`tail`/`less`/`more` siblings — these match
  any command *starting* with the tool that mentions `.env` anywhere in the line.
  A heredoc writing an unrelated file was blocked because the file's contents
  happened to contain the string. Replaced with patterns that only match an env
  file in argument position, which keeps the protection and drops the false
  positives.

**Allows deletion only where it is cheap to be wrong**: `/tmp` and
`/private/tmp`, any `scratch`, `demo` or `tmp` directory, disposable extensions
(`.tmp`, `.log`, `.bak`, `.orig`, `.rej`, `.DS_Store`), and regenerable build
output (`node_modules`, `dist`, `out`, `.next`, `coverage`, `__pycache__`,
`target/debug`, `target/release`). Also `git clean -n` and `-nd`, which only
print what they would remove.

`git clean -fd` is deliberately **not** allowed. It skips ignored files, but it
still deletes untracked ones — so in a repo where `.env` is untracked and not in
`.gitignore`, `git clean -fd` removes it. Verified, not assumed. It falls through
to a prompt like anything else unmatched.

**Keeps hard denies as a backstop**, because a deny outranks an allow and one of
the allow globs could otherwise match something it should not: `/` and `$HOME`,
`.git` directories, secrets and keys (`.env`, `.pem`, `.key`, `.p12`, keystores,
SSH keys), databases and dumps (`.db`, `.sqlite`, `.sql`, `.dump`, anything
matching `*backup*`), and the records you cannot regenerate — `deployments/`,
`broadcast/`, `safe-transactions/`.

## Rule syntax

A Bash rule is `Bash(<command pattern>)`, where `*` is a wildcard. The colon in
`Bash(gh pr merge:*)` separates a command prefix from its arguments — it is not
a working-directory separator, and it is not required. `Bash(rm *.env*)` and
`Bash(rm -rf /tmp/*)` match on the command string exactly as written.

All three behaviours below were verified against the CLI rather than assumed:

| Probe | Rule | Result |
| --- | --- | --- |
| `rm .env.probe` | `Bash(rm *.env*)` in deny | blocked, file survived |
| `rm /private/tmp/…/a.txt` | `Bash(rm /private/tmp/*)` in allow | permitted with no `--dangerously-skip-permissions` |
| `rm ~/probe.dat` | no matching rule | fell through to a prompt, file survived |

The third is the important one: an unmatched command is *asked about*, not
permitted.

## Install

```sh
permissions/bin/merge-permissions.sh --dry-run   # show the diff first
permissions/bin/merge-permissions.sh             # apply to ~/.claude/settings.json
```

Idempotent, and it writes a timestamped backup before touching anything. Pass a
path as the last argument to target a different settings file.

### Withdrawing a rule

Allow lists are merged by **union**, so deleting a rule from the baseline has no
effect on a machine that already merged it — the rule simply stays there
forever. To actually withdraw one, add it to `_removeFromAllow` (the mirror of
the existing `_removeFromDeny`) as well as deleting it from `permissions.allow`.
The merge subtracts those entries from the existing list before the union, and
subtracts them again afterwards, so a rule left in both places loses.

This is not hypothetical. `Bash(rm *.log)` and `Bash(rm -f *.log)` shipped in the
first version of this baseline. Because `*` crosses `/`, they reached
`~/.agentic-skills/routines/logs/*.log` — 580 files, the only record of
every routine run, auto-approved with no prompt. They are withdrawn, and
`test_merge_permissions.sh` now fails if any allow rule names `.log` at all.

## What this is not

These are string patterns matched against the command line, so they are a
guardrail against accidents, not a sandbox. `cd /var/db && rm -rf x` does not
start with `rm` and no `rm` rule will see it. If you need enforcement that
actually resolves paths — following `cd`, `&&` and `;` — write a `PreToolUse`
hook on `Bash` that parses the command and checks the resolved targets against a
protected-root list. **That hook now exists** —
`permissions/bin/protected-paths-hook`, installed as a `PreToolUse` hook on
`Bash` by `merge-permissions.sh`, with its protected paths as data in
`permissions/protected-roots.conf`. It resolves a command's real targets
(following `cd`, `&&`, `;` and line breaks, and checking heredoc bodies on their
own), denies deleting a protected path *or any parent
of one*, and refuses to remove a directory whose contents include files matching
a protected pattern — which is how a `git worktree remove` on a tree that
`git status --untracked-files=all` calls clean gets stopped when it still holds
a live `server/.env`.

It costs about 22 ms per Bash call, dominated by interpreter startup rather than
by the analysis, so a 300-call dispatch run pays roughly 6–7 seconds.

Two things it is not. It is a guardrail against a mistake, not a sandbox: hooks
can be disabled per-run with `--settings '{"disableAllHooks": true}'` and are
skipped in `--bare` mode, so it constrains the model, not an operator. And it
does not replace the static rules — those stay underneath it precisely because
they hold in modes where hooks do not.

The rules here deliberately fail *closed* to a prompt: a command that matches no
allow rule is not permitted, it is asked about.

Two consequences of pattern-matching worth stating outright, because both have
already produced a live hole:

- **A relative path matches nothing.** `Bash(rm -rf /Users/.../trash)` can be
  denied while `cd /Users/... && rm -rf trash` sails through. Only a resolver
  sees those as the same command.
- **Denying a command is not denying an operation.** `Bash(gh pr merge:*)` and
  `Bash(gh pr ready:*)` are denied for scheduled runs, but `Bash(gh api:*)` is
  allowed and reaches the same operations as GraphQL mutations
  (`mergePullRequest`, `markPullRequestReadyForReview`,
  `enablePullRequestAutoMerge`, `resolveReviewThread`) and as the REST route
  `PUT /repos/{o}/{r}/pulls/{n}/merge`. The runner's `HEADLESS_DENY` names all
  of them. When adding a deny, ask what *else* reaches the same operation.
