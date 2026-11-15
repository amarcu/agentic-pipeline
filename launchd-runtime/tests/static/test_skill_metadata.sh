#!/bin/bash
# Static checks: every skill directory has the expected files + frontmatter.

ALL_SKILLS=(notify request-approval triage-repo morning-triage
            propose-tasks plan-features dispatch-tasks work-on-task
            iterate-on-pr daily-summary skill-assess review-pr
            refill-queue)

test_every_skill_has_skill_md() {
    local rc=0
    for skill in "${ALL_SKILLS[@]}"; do
        if [[ ! -f "$REPO_ROOT/skills/$skill/SKILL.md" ]]; then
            echo "  FAIL: $skill/SKILL.md missing"
            rc=1
        fi
    done
    return $rc
}

test_every_skill_has_meta_md() {
    local rc=0
    for skill in "${ALL_SKILLS[@]}"; do
        if [[ ! -f "$REPO_ROOT/skills/$skill/META.md" ]]; then
            echo "  FAIL: $skill/META.md missing"
            rc=1
        fi
    done
    return $rc
}

test_every_skill_md_has_frontmatter() {
    local rc=0
    for skill in "${ALL_SKILLS[@]}"; do
        local first_line
        first_line=$(/usr/bin/head -1 "$REPO_ROOT/skills/$skill/SKILL.md")
        if [[ "$first_line" != "---" ]]; then
            echo "  FAIL: $skill/SKILL.md does not start with YAML frontmatter"
            rc=1
        fi
        if ! /usr/bin/grep -qE '^name:' "$REPO_ROOT/skills/$skill/SKILL.md"; then
            echo "  FAIL: $skill/SKILL.md missing 'name:' in frontmatter"
            rc=1
        fi
        if ! /usr/bin/grep -qE '^description:' "$REPO_ROOT/skills/$skill/SKILL.md"; then
            echo "  FAIL: $skill/SKILL.md missing 'description:' in frontmatter"
            rc=1
        fi
    done
    return $rc
}

test_skill_name_matches_directory() {
    local rc=0
    for skill in "${ALL_SKILLS[@]}"; do
        local declared
        declared=$(/usr/bin/grep -E '^name:' "$REPO_ROOT/skills/$skill/SKILL.md" | /usr/bin/head -1 | /usr/bin/awk '{print $2}')
        if [[ "$declared" != "$skill" ]]; then
            echo "  FAIL: $skill/SKILL.md declares name='$declared' but directory is '$skill'"
            rc=1
        fi
    done
    return $rc
}

test_meta_has_last_assessed() {
    local rc=0
    for skill in "${ALL_SKILLS[@]}"; do
        if ! /usr/bin/grep -qE '^last-assessed:' "$REPO_ROOT/skills/$skill/META.md"; then
            echo "  FAIL: $skill/META.md missing 'last-assessed:'"
            rc=1
        fi
    done
    return $rc
}
