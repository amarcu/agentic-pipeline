#!/bin/bash
# Static checks: pipeline caps are declared exactly once, in repos.conf.
#
# 2026-09-02: the nightly dispatch deadlocked because the same cap existed
# under four names with four values — repos.conf said WIP_TOTAL_MAX=6 and
# WIP_MAJOR_MAX=2, dispatch-tasks/SKILL.md defaulted TOTAL_MAX=3 and
# PER_REPO_MAX=1, META.md documented 5 and 2, and the night prompt raised
# "TOTAL_MAX=8 for this run only". No single file said what the pipeline
# would actually do. These tests keep the numbers in one place, and the line
# that reports them in one wording.

# Every *_MAX identifier a skill or a routine prompt names, in the files that
# are allowed to name one.
_cap_identifiers_in() {
    # Match the whole SHOUTY_TOKEN, then keep only the ones that end in _MAX —
    # otherwise ROUTINE_MAX_BUDGET_USD reads as a reference to "ROUTINE_MAX".
    /usr/bin/grep -ohE '[A-Z][A-Z0-9_]*_MAX[A-Z0-9_]*' "$@" 2>/dev/null \
        | /usr/bin/grep -E '_MAX$' \
        | /usr/bin/sort -u
}

test_every_cap_named_in_a_skill_or_prompt_is_defined_in_repos_conf() {
    local conf="$RUNTIME_DIR/repos.conf.example"
    local rc=0
    local files=("$REPO_ROOT"/skills/*/SKILL.md "$RUNTIME_DIR"/prompts/*.md)

    local cap
    for cap in $(_cap_identifiers_in "${files[@]}"); do
        if ! /usr/bin/grep -qE "^${cap}=" "$conf"; then
            echo "  FAIL: '$cap' is referenced but not defined in repos.conf. Referenced in:"
            # -w, not an ERE \b: \b is a GNU/BSD extension, not POSIX ERE.
            # -w brackets the fixed string with word boundaries and counts
            # `_` as a word character, so DISPATCH_TOTAL_MAX does not match
            # inside X_DISPATCH_TOTAL_MAX — which is the whole point here.
            /usr/bin/grep -lwF "$cap" "${files[@]}" 2>/dev/null | sed 's/^/    /'
            rc=1
        fi
    done
    return $rc
}

test_no_routine_prompt_overrides_a_cap() {
    # A prompt that says `TOTAL_MAX=8 for this run only` is a second source of
    # truth by another name. Prompts may name a cap; they may never set one.
    local hits
    hits=$(/usr/bin/grep -nE '[A-Z][A-Z0-9_]*_MAX[[:space:]]*=[[:space:]]*[0-9]' \
               "$RUNTIME_DIR"/prompts/*.md 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
        echo "  FAIL: routine prompt hardcodes a cap (caps live in repos.conf only):"
        echo "$hits" | sed 's/^/    /'
        return 1
    fi
    return 0
}

# ── The line that reports the caps ────────────────────────────────────────
#
# 2026-09-05: the dispatch gate went from one global count to per-repo limits
# under a global ceiling, and the gate line grew four fields to say so. That
# line is written out in more than one file — dispatch-tasks/SKILL.md states
# it at Step 2 and again in its output contract, META.md quotes it where it
# explains the gate-closed halt — and a field added to one copy and not the
# others is the same class of bug as a cap defined twice: the log stops
# matching what its reader was told to expect. Byte-for-byte, or it drifts.

# Every DISPATCH GATE *format* line in the docs — the ones carrying `<`
# placeholders. Prose that names the line writes it as `DISPATCH GATE:` in
# backticks, with no trailing space, so it never matches here.
_gate_format_lines() {
    /usr/bin/grep -rhoE 'DISPATCH GATE: .*' \
        "$REPO_ROOT"/skills/*/SKILL.md "$REPO_ROOT"/skills/*/META.md \
        "$REPO_ROOT"/docs/*.md "$RUNTIME_DIR"/prompts/*.md 2>/dev/null \
        | /usr/bin/grep -F '<'
}

test_dispatch_gate_line_is_written_identically_everywhere() {
    local lines distinct count
    lines=$(_gate_format_lines)
    count=$(printf '%s' "$lines" | /usr/bin/grep -c . || true)

    if [[ "$count" -lt 2 ]]; then
        echo "  FAIL: found $count DISPATCH GATE format line(s); expected the"
        echo "        skill body and its output contract to both state one."
        return 1
    fi

    distinct=$(printf '%s\n' "$lines" | /usr/bin/sort -u)
    if [[ $(printf '%s\n' "$distinct" | /usr/bin/wc -l) -ne 1 ]]; then
        echo "  FAIL: the DISPATCH GATE line is worded differently in different files:"
        printf '%s\n' "$distinct" | /usr/bin/sed 's/^/    /'
        /usr/bin/grep -rlE 'DISPATCH GATE: .*<' \
            "$REPO_ROOT"/skills/*/SKILL.md "$REPO_ROOT"/skills/*/META.md \
            "$REPO_ROOT"/docs/*.md "$RUNTIME_DIR"/prompts/*.md 2>/dev/null \
            | /usr/bin/sed 's/^/    in /'
        return 1
    fi

    # Every field the gate is required to report. A rename that kept the line
    # self-consistent across files would otherwise pass silently.
    local rc=0 field
    for field in open_agent_prs cap per_repo run_max budget blocked unmet at_limit eligible; do
        if [[ "$distinct" != *"${field}="* ]]; then
            echo "  FAIL: the DISPATCH GATE line no longer reports '${field}='"
            echo "    $distinct"
            rc=1
        fi
    done
    return $rc
}

test_dispatch_gate_line_appears_in_both_skill_and_meta() {
    # The skill body says what to print; META says what a halted run looks
    # like. Losing either copy costs the test above its second opinion.
    local rc=0 file
    for file in "$REPO_ROOT/skills/dispatch-tasks/SKILL.md" "$REPO_ROOT/skills/dispatch-tasks/META.md"; do
        if ! /usr/bin/grep -qE 'DISPATCH GATE: .*<' "$file"; then
            echo "  FAIL: $file states no DISPATCH GATE format line"
            rc=1
        fi
    done
    return $rc
}

# ── The buckets behind the gate line's fields ─────────────────────────────
#
# Grok on PR #35: Step 1 drops a repo whose requirements check exits 1 into
# `unmet`, and the gate line reports `unmet=` — but Step 1's own verify line
# still asked only that every active repo be "represented in the queue counts
# or named as `skipped:`". An unmet repo is in neither, so the step contradicted
# its own check, and `references/queue-building.md` never mentioned the bucket
# at all. A verify line a correct run cannot satisfy teaches its reader to skip
# verifying.

test_dispatch_step_1_verify_admits_the_unmet_bucket() {
    local skill="$REPO_ROOT/skills/dispatch-tasks/SKILL.md"
    local ref="$REPO_ROOT/skills/dispatch-tasks/references/queue-building.md"
    local rc=0 verify

    # The first `verify:` line inside Step 1, and no further.
    verify=$(/usr/bin/awk '/^### Step 1 /   { step = 1; next }
                           /^### Step /     { step = 0 }
                           step && /verify:/ { print; exit }' "$skill")

    if [[ -z "$verify" ]]; then
        echo "  FAIL: dispatch-tasks Step 1 states no 'verify:' line"
        return 1
    fi
    if [[ "$verify" != *unmet* ]]; then
        echo "  FAIL: Step 1 drops a repo into 'unmet', but its verify line admits no"
        echo "        such bucket — an unmet repo satisfies neither branch of it:"
        echo "    $verify"
        rc=1
    fi
    if ! /usr/bin/grep -q 'unmet' "$ref"; then
        echo "  FAIL: $(/usr/bin/basename "$ref") never mentions 'unmet', and Step 1 sends"
        echo "        its reader there for what it drops and why"
        rc=1
    fi
    return $rc
}
