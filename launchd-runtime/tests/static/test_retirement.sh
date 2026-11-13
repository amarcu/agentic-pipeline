#!/bin/bash
# Static checks: the retirement path holds together across the three skills that
# make up one loop (issue #62).
#
# Closing an issue stops dispatch from working it and nothing else. The decision
# survives only if every link is in place: `plan-features` reconciles against the
# focus it just wrote, a retirement is a close AND the `retired` label, `unstick`
# applies the same label, and `propose-tasks` reads it. Each link lives in prose
# that a later edit can quietly drop, so each is asserted here.

_ret_has() {  # $1 = file (repo-relative), $2 = extended regex, $3 = what it guarantees
    if ! LC_ALL=C /usr/bin/grep -qE -- "$2" "$REPO_ROOT/$1"; then
        echo "  FAIL: $1 no longer says: $3"
        return 1
    fi
    return 0
}

_ret_lacks() {  # $1 = file, $2 = regex that must NOT match, $3 = why
    if LC_ALL=C /usr/bin/grep -qE -- "$2" "$REPO_ROOT/$1"; then
        echo "  FAIL: $1 still has: $3"
        return 1
    fi
    return 0
}

test_retirement_plan_features_reconciles_with_the_documents() {
    local rc=0
    # In Step 4, not with Step 5's issues: --docs-only skips Step 5, and a
    # retirement belongs in the diff the human confirms.
    _ret_has skills/plan-features/SKILL.md 'references/retiring\.md' \
        "where the reconcile step is written down" || rc=1
    _ret_has skills/plan-features/SKILL.md 'bin/focus-orphans' \
        "that the orphan list comes from the script, not from reading bodies" || rc=1
    _ret_has skills/plan-features/SKILL.md 'MAX_RETIRE' "the cap on offers in one session" || rc=1
    _ret_has skills/plan-features/SKILL.md '\*Not now\* line already there is kept' \
        "that a rewrite of FOCUS.md keeps the retirements already recorded" || rc=1
    _ret_has skills/plan-features/SKILL.md 'RETIRED: <owner/repo>#<N>' "the output line" || rc=1
    _ret_has skills/plan-features/SKILL.md 'nothing for a line a `retired` issue already names' \
        "that Step 5 does not re-cut retired work" || rc=1
    if LC_ALL=C /usr/bin/grep -qE '^## Step 4\.5' "$REPO_ROOT/skills/plan-features/SKILL.md"; then
        echo "  FAIL: plan-features/SKILL.md puts the reconcile in its own step again —"
        echo "        it belongs in Step 4, which --docs-only runs and whose diff the human confirms"
        rc=1
    fi
    return $rc
}

test_retirement_is_a_close_and_a_label() {
    local rc=0
    _ret_has skills/plan-features/references/retiring.md 'add-label retired' \
        "that a retirement carries the label propose-tasks reads" || rc=1
    _ret_has skills/plan-features/references/retiring.md 'Not now' \
        "that the reason is written to Not now" || rc=1
    _ret_has skills/plan-features/references/retiring.md 'Decisions log' \
        "and to the Decisions log" || rc=1
    _ret_has skills/plan-features/references/retiring.md 'never offered' \
        "that a claimed or untraceable issue is not offered" || rc=1
    _ret_has skills/plan-features/references/retiring.md 'yes covers that issue alone' \
        "that one yes never covers the rest of the list" || rc=1
    _ret_has skills/plan-features/references/retiring.md 'no document edit, no label, no comment, no close' \
        "that --dry-run writes nothing at all" || rc=1
    # Nothing would have failed if a kept issue were quietly closed, relabelled or
    # moved to Not now (Grok, PR #63 f4).
    _ret_has skills/plan-features/references/retiring.md 'still reports .OPEN. and no .retired. label' \
        "the check that an issue the human kept was left untouched" || rc=1
    _ret_has skills/plan-features/references/retiring.md 'on no \*Not now\* line' \
        "including that a kept issue did not land in Not now" || rc=1
    _ret_has skills/unstick/SKILL.md 'add-label retired' \
        "that a sitting labels what it retires, or the work stays proposable" || rc=1
    # --add-label fails when the label does not exist, so the first retirement in a
    # repo would close the issue and leave no record (Grok, PR #63 f2).
    _ret_has skills/unstick/SKILL.md 'gh label create retired' \
        "that it creates the label before adding it" || rc=1
    _ret_has skills/plan-features/references/retiring.md 'gh label create retired' \
        "the same, in the session that retires in bulk" || rc=1
    _ret_has skills/unstick/SKILL.md 'action=<approved\|retired' "that its output names the action" || rc=1
    return $rc
}

test_retirement_is_read_by_the_proposer() {
    local rc=0
    _ret_has skills/propose-tasks/SKILL.md 'references/duplicates\.md' \
        "where the duplicate queries are written down" || rc=1
    _ret_has skills/propose-tasks/references/duplicates.md '\-\-label retired' \
        "that a retired issue is consulted" || rc=1
    _ret_has skills/propose-tasks/references/duplicates.md '\-\-state open' \
        "and that open issues still count, whoever filed them" || rc=1
    # The two narrownesses that let retired work come back.
    _ret_lacks skills/propose-tasks/references/duplicates.md 'contains\("skill=propose-tasks"\)' \
        "the filter that ignored every issue this skill did not write" || rc=1
    # Omitting --limit is not a wider lookback: gh pages 30 by default, which is
    # narrower than the --limit 60 this replaced (Grok, PR #63 f1).
    if [[ $(LC_ALL=C /usr/bin/grep -cE '^gh issue list .*--limit 500' \
            "$REPO_ROOT/skills/propose-tasks/references/duplicates.md") -ne 2 ]]; then
        echo "  FAIL: propose-tasks/references/duplicates.md must bound both duplicate"
        echo "        queries with --limit 500 — without a flag gh pages 30"
        rc=1
    fi
    _ret_lacks skills/propose-tasks/SKILL.md 'contains\("skill=propose-tasks"\)' \
        "the same filter, in the skill itself" || rc=1
    return $rc
}

test_retirement_script_is_read_only_and_documented() {
    local rc=0
    local script="$REPO_ROOT/launchd-runtime/bin/focus-orphans"
    if [[ ! -x "$script" ]]; then
        echo "  FAIL: launchd-runtime/bin/focus-orphans is not executable"
        return 1
    fi
    _ret_has launchd-runtime/bin/focus-orphans 'UNTRACEABLE' \
        "the third state, which keeps a pre-template backlog off the human's list" || rc=1
    _ret_has launchd-runtime/bin/focus-orphans 'task/issue-' \
        "repos.conf's own definition of a claimed issue" || rc=1
    if LC_ALL=C /usr/bin/grep -qE '(issue (close|edit|comment)|pr (merge|ready)|--method (POST|PATCH|PUT|DELETE))' \
            "$script"; then
        echo "  FAIL: focus-orphans is the read-only half of the step, but it names a writing command"
        rc=1
    fi
    return $rc
}
