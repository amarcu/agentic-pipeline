#!/bin/bash
# install.sh --skills-only is what puts the skills where Claude Code looks for
# them. Nothing in the repo did that before, so the two machines drifted: the
# pipeline host had directory links in ~/.claude/skills/, this workstation had
# legacy single-file links (~/.claude/commands/<name>.md -> <repo>/<name>/SKILL.md)
# that hide META.md, reference.md and scripts/, and was missing four skills
# outright. Every test here runs against a throwaway HOME.

INSTALL_SH="$RUNTIME_DIR/bin/install.sh"

_skills_tmp() {
    local tmp; tmp=$(/usr/bin/mktemp -d /tmp/agentic-skills-install.XXXXXX)
    /bin/mkdir -p "$tmp/home/.claude/commands"
    echo "$tmp"
}

_install_skills() {
    HOME="$1" /bin/bash "$INSTALL_SH" --skills-only
}

# Path -> link target for everything the installer touches, so a comparison
# across runs sees state and not the fresh mtime `ln -sfn` always leaves.
_link_state() {
    local p
    for p in "$1"/.claude/skills/* "$1"/.claude/commands/*; do
        [[ -e "$p" || -L "$p" ]] || continue
        echo "${p#$1/} -> $(/usr/bin/readlink "$p" 2>/dev/null || echo '(not a link)')"
    done | /usr/bin/sort
}

test_install_skills_links_every_skill_directory() {
    local tmp; tmp=$(_skills_tmp)
    local home="$tmp/home" rc=0 out
    out=$(_install_skills "$home")

    local skill
    for skill in notify work-on-task review-pr skill-assess triage-repo; do
        if [[ ! -L "$home/.claude/skills/$skill" ]]; then
            echo "  FAIL: ~/.claude/skills/$skill is not a symlink"
            rc=1
        elif [[ ! -f "$home/.claude/skills/$skill/META.md" ]]; then
            echo "  FAIL: $skill link does not reach META.md — a single-file link?"
            rc=1
        fi
    done

    # Not a skill, and so not linked: docs, anchor, launchd-runtime and
    # permissions have no SKILL.md; _templates has one but is scaffolding,
    # excluded by the leading underscore in its directory name.
    local other
    for other in docs anchor launchd-runtime permissions _templates; do
        if [[ -e "$home/.claude/skills/$other" || -L "$home/.claude/skills/$other" ]]; then
            echo "  FAIL: $other linked into skills/ but is not a skill directory"
            rc=1
        fi
    done

    # _templates/SKILL.md is the skeleton new skills are copied from, not a
    # skill: the installer skips any directory whose name starts with `_`, so
    # those must not be counted here either.
    local linked expected
    linked=$(/bin/ls "$home/.claude/skills" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
    expected=$(/bin/ls -d "$REPO_ROOT"/skills/*/SKILL.md | /usr/bin/grep -vc "^$REPO_ROOT/_")
    assert_equal "$expected" "$linked" "one link per skill directory" || rc=1
    assert_contains "$out" "$expected skill(s) linked" "summary counts the links" || rc=1

    /bin/rm -rf "$tmp"
    return $rc
}

test_install_skills_removes_only_legacy_links_into_this_repo() {
    local tmp; tmp=$(_skills_tmp)
    local home="$tmp/home" rc=0
    /bin/mkdir -p "$tmp/elsewhere"
    /usr/bin/touch "$tmp/elsewhere/notify.md" "$tmp/elsewhere/cursor-helper.md"
    /bin/ln -sfn "$REPO_ROOT/skills/work-on-task/SKILL.md" "$home/.claude/commands/work-on-task.md"
    # Same name as a skill, but pointing outside the repo — not ours to delete.
    /bin/ln -sfn "$tmp/elsewhere/notify.md"        "$home/.claude/commands/notify.md"
    /bin/ln -sfn "$tmp/elsewhere/cursor-helper.md" "$home/.claude/commands/cursor-helper.md"

    local out; out=$(_install_skills "$home")

    if [[ -L "$home/.claude/commands/work-on-task.md" ]]; then
        echo "  FAIL: legacy link pointing into this repo was not removed"
        rc=1
    fi
    if [[ ! -L "$home/.claude/commands/notify.md" ]]; then
        echo "  FAIL: foreign link named after a skill was removed"
        rc=1
    fi
    if [[ ! -L "$home/.claude/commands/cursor-helper.md" ]]; then
        echo "  FAIL: unrelated link in commands/ was removed"
        rc=1
    fi
    assert_contains "$out" "removed legacy commands/work-on-task.md" "the removal is reported" || rc=1
    assert_contains "$out" "1 legacy command link(s) removed" "summary counts the removal" || rc=1

    /bin/rm -rf "$tmp"
    return $rc
}

test_install_skills_second_run_changes_nothing() {
    local tmp; tmp=$(_skills_tmp)
    local home="$tmp/home" rc=0
    /bin/ln -sfn "$REPO_ROOT/skills/notify/SKILL.md" "$home/.claude/commands/notify.md"

    _install_skills "$home" > /dev/null
    local first; first=$(_link_state "$home")

    local out; out=$(_install_skills "$home")
    local second; second=$(_link_state "$home")

    assert_equal "$first" "$second" "a second run leaves the same links" || rc=1
    assert_contains "$out" "0 legacy command link(s) removed" "nothing left to migrate" || rc=1

    /bin/rm -rf "$tmp"
    return $rc
}
