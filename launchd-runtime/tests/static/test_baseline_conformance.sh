#!/bin/bash
# Static checks: every claim in BASELINE.md and every inheriting skill is
# internally consistent. These would have caught the "four vs five
# principles" drift, the missing preamble bug, etc.

# The skills that inherit BASELINE.md are exactly the ones META.md calls
# `kind: coding`. This was a hardcoded four-name array until 2026-09-04, by
# which time it had drifted from META.md: it omitted daily-summary,
# dispatch-tasks, morning-triage, notify and plan-features, every one of which
# declares `kind: coding`. A roster that has to be edited in a second place is
# a roster that stops matching the first one.
_baseline_coding_skills() {
    local meta skill
    for meta in "$REPO_ROOT"/skills/*/META.md; do
        [[ -f "$meta" ]] || continue
        /usr/bin/grep -qE '^kind:[[:space:]]*coding[[:space:]]*$' "$meta" || continue
        skill=$(/usr/bin/basename "$(/usr/bin/dirname "$meta")")
        [[ "$skill" == _* ]] && continue
        echo "$skill"
    done
    return 0
}

test_baseline_exists() {
    assert_file_exists "$REPO_ROOT/BASELINE.md" "BASELINE.md at repo root"
}

test_baseline_has_five_principles() {
    local count
    count=$(/usr/bin/grep -cE '^## [0-9]\. ' "$REPO_ROOT/BASELINE.md")
    if [[ "$count" -ne 5 ]]; then
        echo "  FAIL: BASELINE.md should have exactly 5 principles, found $count"
        /usr/bin/grep -E '^## [0-9]\. ' "$REPO_ROOT/BASELINE.md" | sed 's/^/    /'
        return 1
    fi
    return 0
}

test_inheriting_skills_have_baseline_preamble() {
    local rc=0
    for skill in $(_baseline_coding_skills); do
        if ! /usr/bin/grep -q "BASELINE.md" "$REPO_ROOT/skills/$skill/SKILL.md"; then
            echo "  FAIL: $skill/SKILL.md is missing BASELINE.md reference"
            rc=1
        fi
    done
    return $rc
}

test_inheriting_skills_preamble_says_five_principles() {
    # This is the regression we just caught manually — BASELINE has 5 but
    # the preambles still said "four". Encode that as a permanent test.
    local rc=0
    for skill in $(_baseline_coding_skills); do
        if /usr/bin/grep -q "four principles" "$REPO_ROOT/skills/$skill/SKILL.md"; then
            echo "  FAIL: $skill/SKILL.md still says 'four principles' — should be 'five'"
            rc=1
        fi
        if ! /usr/bin/grep -q "five principles" "$REPO_ROOT/skills/$skill/SKILL.md"; then
            echo "  WARN: $skill/SKILL.md does not say 'five principles' explicitly"
            # Warn, not fail — phrasing flexibility allowed
        fi
    done
    return $rc
}

test_no_deprecated_jq_telegram_pattern_in_active_skills() {
    # The `printf ... | jq -Rs .` shell construct produced duplicate Telegram
    # sends with emoji payloads on 2026-05-10. Banned in active skills.
    #
    # Match the actual code construct (`printf` piped into `jq -Rs`), not
    # bare mentions — prose may reference the deprecated pattern by name.
    local bad=()
    for f in "$REPO_ROOT"/skills/*/SKILL.md; do
        if /usr/bin/grep -E 'printf[^|]*\|[^|]*jq -Rs' "$f" > /dev/null 2>&1; then
            bad+=("$f")
        fi
    done
    if [[ "${#bad[@]}" -gt 0 ]]; then
        echo "  FAIL: deprecated 'printf … | jq -Rs' Telegram code in:"
        for f in "${bad[@]}"; do echo "    $f"; done
        return 1
    fi
    return 0
}

test_baseline_principle_5_exception_list_is_consistent() {
    # The exception list in BASELINE Principle 5 names skills/routines that
    # are ALLOWED to send on quiet days. Currently: daily-summary,
    # wake-status-digest. Verify the named ones actually exist somewhere.
    local rc=0

    # daily-summary is a SKILL
    if [[ ! -d "$REPO_ROOT/skills/daily-summary" ]]; then
        echo "  FAIL: BASELINE names 'daily-summary' as exception but no such skill"
        rc=1
    fi

    # wake-status-digest is a launchd-runtime PROMPT
    if [[ ! -f "$RUNTIME_DIR/prompts/wake-status-digest.md" ]]; then
        echo "  FAIL: BASELINE names 'wake-status-digest' as exception but no such prompt"
        rc=1
    fi
    return $rc
}

test_line_count_is_not_a_quality_signal_per_baseline() {
    # 2026-05-13: stale "Split X.cs" proposals taught us that line count is
    # a fragile proxy for code quality. BASELINE Principle 2 and propose-
    # tasks Step 3 both explicitly say "don't propose splits based on size."
    # Lock that in — without these guardrails the agent will happily propose
    # mechanical splits whenever a repo's .cursorrules states a line cap.
    local rc=0
    if ! /usr/bin/grep -q "Line count is not a quality signal" "$REPO_ROOT/BASELINE.md"; then
        echo "  FAIL: BASELINE.md missing the 'Line count is not a quality signal' anti-pattern note"
        rc=1
    fi
    if ! /usr/bin/grep -q "Hard exclusion: file-splits based on line count" "$REPO_ROOT/skills/propose-tasks/SKILL.md"; then
        echo "  FAIL: propose-tasks/SKILL.md missing the 'Hard exclusion' guardrail"
        rc=1
    fi
    return $rc
}

test_no_references_to_external_skill_repos() {
    # Per the scope-discipline rule in skill-assess, agentic-skills should
    # not reference external named skill repos (legitimate "do not touch"
    # mentions are allowed only in skill-assess SKILL.md and META.md).
    local rc=0
    local matches
    matches=$(/usr/bin/grep -rln -E 'deficollective|defiscan' "$REPO_ROOT" \
                  --include='*.md' \
                  --exclude-dir='.git' \
                  --exclude-dir='tests' 2>/dev/null | /usr/bin/grep -v 'skill-assess' || true)
    if [[ -n "$matches" ]]; then
        echo "  FAIL: external-skill-repo references found outside skill-assess:"
        echo "$matches" | sed 's/^/    /'
        rc=1
    fi
    return $rc
}

test_skills_cite_the_baseline_through_their_own_directory() {
    # 2026-09-12: every skill cited the baseline by the owner's absolute path, so
    # on any other machine, and inside `claude plugin eval`'s sandbox, which
    # denies reading /Users/dev, a skill started without the baseline it
    # inherits. ${CLAUDE_SKILL_DIR} resolves to the skill's own directory in
    # every install location; ${CLAUDE_PLUGIN_ROOT} is substituted only for
    # plugin installs, and the pipeline host installs skills as symlinks.
    local rc=0 f line
    for f in "$REPO_ROOT"/skills/*/SKILL.md; do
        line=$(/usr/bin/grep -m1 -E '^Read .*BASELINE\.md' "$f")
        [[ -n "$line" ]] || continue
        if [[ "$line" != *'${CLAUDE_SKILL_DIR}/BASELINE.md'* ]]; then
            echo "  FAIL: ${f#"$REPO_ROOT"/} cites the baseline as: $line"
            rc=1
        fi
    done
    return $rc
}

test_every_baseline_a_skill_cites_resolves_from_its_directory() {
    # A citation of ${CLAUDE_SKILL_DIR}/BASELINE.md needs the file to be there.
    # It is a relative symlink to the repo root's copy, and never `..` in the
    # citation: the Read tool normalises a path as text before opening it, so
    # ~/.claude/skills/<skill>/../BASELINE.md collapses to a file that does not
    # exist, while a symlink inside the skill's directory is followed on disk.
    # Plugin installs keep it working: the plugin cache preserves a symlink that
    # resolves within the plugin's own directory.
    local rc=0 f dir name link
    for f in "$REPO_ROOT"/skills/*/SKILL.md; do
        dir=$(/usr/bin/dirname "$f")
        for name in BASELINE.md BASELINE-CODING.md; do
            /usr/bin/grep -qF "\${CLAUDE_SKILL_DIR}/$name" "$f" || continue
            link="$dir/$name"
            if [[ ! -L "$link" ]]; then
                echo "  FAIL: ${f#"$REPO_ROOT"/} cites \${CLAUDE_SKILL_DIR}/$name, but ${link#"$REPO_ROOT"/} is not a symlink"
                rc=1
            elif [[ "$(/usr/bin/readlink "$link")" != "../../$name" ]]; then
                echo "  FAIL: ${link#"$REPO_ROOT"/} points at '$(/usr/bin/readlink "$link")', not ../../$name"
                rc=1
            elif [[ ! -f "$link" ]]; then
                echo "  FAIL: ${link#"$REPO_ROOT"/} does not resolve to a file"
                rc=1
            fi
        done
    done
    return $rc
}
