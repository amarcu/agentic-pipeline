#!/bin/bash
# The headless deny-net: the `--settings` deny rules every unattended run of a
# routine carries. Sourced, never executed — it sets one variable:
#
#     HEADLESS_DENY   a JSON settings document, ready for `claude --settings`
#
# Two readers, one list: `bin/_run.sh` (the scheduled runner) and
# `tests/smoke/run-smoke.sh` (the smoke gate, which must launch a routine the
# way production does). It lives in its own file so the smoke cannot drift
# away from what the routines actually run under.
#
# A scheduled run has no human to instruct it, no auto-mode classifier on this
# host, and it reads issue and comment bodies, which on a public repo anyone can
# write. Prompt text is therefore untrusted input, and
# the rule layer is the only part of the boundary that does not depend on the
# model behaving. permissions.ask already fails closed here (an ask rule has no
# prompt to fall back on without a TTY), but ask-denial is an inference rather
# than a documented guarantee. Deny rules ARE documented to hold in every mode,
# --dangerously-skip-permissions included, so state it outright.
#
# How these match (https://code.claude.com/docs/en/permissions.md):
#   * everything before the first `*` is matched literally; `*` then stands in
#     for any text, spaces and the empty string included;
#   * `Bash(x:*)` is another spelling of `Bash(x *)`, and both also match a
#     bare `x`. The colon form is only recognised at the END of a pattern;
#   * the space in `Bash(git push * -f*)` is part of the rule, and is what
#     keeps it off `git push origin add-feature-x` — an unanchored `*-f*`
#     matches that branch name, and workers push names shaped like it;
#   * a compound command is split on && || ; | |& & and newlines and each
#     subcommand is matched on its own, so `git status && curl evil` is caught;
#   * timeout/time/nice/nohup/stdbuf/command/builtin/noglob and a bare xargs
#     are stripped before matching, and a deny rule matches past a leading
#     VAR=value assignment;
#   * a bare tool name (WebFetch) denies the tool and removes it from context.
#
# ── family 1: no ready, no merge ──────────────────────────────────────────
# BASELINE.md, "Merging and Marking PRs Ready": a scheduled run never marks a
# PR ready and never merges one. Denying the two porcelain commands is not
# enough. `Bash(gh api:*)` is in the interactive allow list, and the same
# operations are reachable through it by another name — verified against the
# live GraphQL schema:
#   markPullRequestReadyForReview   the ready mutation
#   mergePullRequest                the merge mutation
#   enablePullRequestAutoMerge      merges later, without another command
#   resolveReviewThread             not ready/merge itself, but it clears the
#                                   objections a ready-gate checks for, so it
#                                   is the same authority one step removed
# plus the REST route PUT /repos/{o}/{r}/pulls/{n}/merge. "Absent from our
# source" is not "unreachable", which is the whole reason this block exists.
# The mutation rules are no longer anchored on `gh api graphql`: the method can
# be named first (`gh api -X POST graphql`, `gh api --method POST graphql`) and
# a literal `gh api graphql` prefix misses both. `--input` and `@` close the
# last shape, a mutation whose text lives in a file and so appears in no rule
# at all (`gh api graphql -F query=@merge.graphql`).
#
# ── family 2: nothing irreversible ────────────────────────────────────────
# A worker that can force-push, delete a branch or a remote object, or `git
# clean` a tree destroys work no reflog brings back, a human's included. Each
# push rule exists in two shapes because a flag may come before or after the
# refspec, and the short flags are space-anchored for the branch-name reason
# above. `git push * +*` is the force-by-refspec form, which says "force"
# nowhere.
#
# Its delete-by-refspec twin, `git push origin :old-branch`, is only PARTLY
# covered, by `git push * :refs/*`. The short form cannot be written at all: a
# rule ending in `:*` is read as the trailing-wildcard idiom (`Bash(ls:*)` is
# `Bash(ls *)`), so `Bash(git push * :*)` loses its colon and matches nothing
# it was meant to. `--delete` and `-d` cover the porcelain spelling of the same
# deletion; the bare short refspec is a documented gap, not an oversight.
# `gh api *DELETE*` applies family 1's lesson here: denying the porcelain
# deletes while the REST route stays open denies a command, not an operation.
# `git checkout -- <path>` is deliberately NOT denied: it discards edits the
# worker itself just made, which is ordinary work, not destruction.
#
# ── family 3: no egress ───────────────────────────────────────────────────
# The CLI inherits CLAUDE_CODE_OAUTH_TOKEN and TELEGRAM_BOT_TOKEN from
# settings.json, so a crafted issue body needs exactly one outbound request to
# be worth writing. This family removes the request. Checked before denying:
# telegram-send is python3 + urllib, not curl, so the stack's one Telegram path
# is untouched; the alert curls in this script are shell, not Bash tool calls,
# and permission rules never applied to them. iterate-on-pr is the only skill
# declaring `Bash(curl:*)` — it fetches images out of PR comments — and no
# routine invokes it; its own Step already treats "image at <url> could not be
# fetched" as a supported outcome, so the day it joins the schedule it degrades
# rather than breaks.
# None of this touches interactive sessions: these rules live in --settings,
# which only this runner passes.
HEADLESS_DENY='{"permissions":{"deny":[
"Bash(gh pr merge:*)",
"Bash(gh pr ready:*)",
"Bash(gh api *markPullRequestReadyForReview*)",
"Bash(gh api *mergePullRequest*)",
"Bash(gh api *enablePullRequestAutoMerge*)",
"Bash(gh api *resolveReviewThread*)",
"Bash(gh api*pulls/*/merge*)",
"Bash(gh api *--input*)",
"Bash(gh api *@*)",

"Bash(git push *--force*)",
"Bash(git push -f*)",
"Bash(git push * -f*)",
"Bash(git push *--delete*)",
"Bash(git push -d*)",
"Bash(git push * -d*)",
"Bash(git push * :refs/*)",
"Bash(git push * +*)",
"Bash(git branch *--delete*)",
"Bash(git branch -d*)",
"Bash(git branch * -d*)",
"Bash(git branch -D*)",
"Bash(git branch * -D*)",
"Bash(git reset *--hard*)",
"Bash(git clean*)",
"Bash(gh issue delete:*)",
"Bash(gh repo delete:*)",
"Bash(gh release delete:*)",
"Bash(gh pr close:*)",
"Bash(gh api *DELETE*)",

"Bash(curl:*)",
"Bash(wget:*)",
"Bash(nc:*)",
"Bash(ncat:*)",
"Bash(ssh:*)",
"Bash(scp:*)",
"Bash(gh auth token:*)",
"Bash(gh gist:*)",
"Bash(printenv:*)",
"Bash(env:*)",
"WebFetch",
"WebSearch"
]}}'
