#!/bin/bash
# Static checks: the Claude review and iterate lanes act only on agent PRs.
# The human decided on 2026-09-26 that Claude reviews only what the agents
# shipped; both the skills and the routine prompts carry that, because a prompt
# that selects widely is caught by the skill, and a skill run by hand is caught
# by its own refusal.

test_agent_pr_lanes_skills_refuse_a_human_pr() {
    local rc=0 skill
    for skill in review-pr iterate-on-pr; do
        if ! /usr/bin/grep -q '`not-agent-pr`' "$REPO_ROOT/skills/$skill/SKILL.md"; then
            echo "  FAIL: $skill/SKILL.md no longer refuses a PR whose head is not an agent branch"
            rc=1
        fi
    done
    return $rc
}

test_agent_pr_lanes_prompts_select_through_the_predicate() {
    local rc=0 prompt
    for prompt in pr-review-night pr-iterate-night; do
        if ! /usr/bin/grep -q 'launchd-runtime/bin/agent-prs <owner/repo> --draft-only' \
                "$RUNTIME_DIR/prompts/$prompt.md"; then
            echo "  FAIL: prompts/$prompt.md does not select its PRs through bin/agent-prs"
            rc=1
        fi
    done
    return $rc
}
