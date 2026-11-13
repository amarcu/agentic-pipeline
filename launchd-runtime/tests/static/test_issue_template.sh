#!/bin/bash
# plan-features copies references/issue-template.md's fenced body literally into every issue. A
# line there that changes work-on-task's behaviour would apply to every issue, so the opt-in
# `SCENE: allowed` lives in the guidance below the template, never inside the fence.

test_issue_template_body_does_not_carry_scene_allowed() {
    local template="$RUNTIME_DIR/../skills/plan-features/references/issue-template.md" body
    body=$(/usr/bin/awk '/^```markdown/{f=1;next} /^```/{if(f){exit}} f' "$template")
    [[ -n "$body" ]] || { echo "  FAIL: no fenced markdown body found in $template"; return 1; }
    if [[ "$body" == *"SCENE: allowed"* ]]; then
        echo "  FAIL: the template body carries SCENE: allowed, so every issue would pre-approve scene wiring"
        return 1
    fi
    assert_contains "$(/bin/cat "$template")" "SCENE: allowed" "the opt-in is still documented, outside the body" || return 1
}
