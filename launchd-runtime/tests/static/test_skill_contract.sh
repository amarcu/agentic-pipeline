#!/bin/bash
# Static checks: every SKILL.md meets the mechanical half of the skill
# definition standard (docs/skill-standard.md).
#
# 2026-09-03: an audit scored the eleven skills then in the repo 33-40 out of
# 56 against a rubric built from Anthropic's own skill-authoring guidance.
# Nothing was broken — each skill had simply solved argument parsing, Telegram,
# caps, halts and attribution its own way, so a fix in one never reached the
# others. The standard is what the rewrites land into; these tests are what
# keeps them there.
#
# 2026-09-26: the SKILL.md byte budget came out (now a runaway ceiling at twice
# the old cap). It was deciding what lived in SKILL.md by the byte. What stays is
# what a real outage or a containment rule depends on.

_CONTRACT_EFFORTS="low medium high xhigh max"

# Twice the old 10 KB budget. See the ceiling test for why it is not a budget.
_CONTRACT_SKILL_MD_CEILING=20480

# ── Enumeration ───────────────────────────────────────────────────────────

# A skill is a top-level directory holding a SKILL.md. A directory whose name
# starts with `_` is scaffolding (_templates), not a skill — install.sh applies
# the same rule when it links skills into ~/.claude/skills.
_contract_skills() {
    local dir name
    for dir in "$REPO_ROOT"/skills/*/; do
        [[ -f "$dir/SKILL.md" ]] || continue
        name=$(/usr/bin/basename "$dir")
        [[ "$name" == _* ]] && continue
        echo "$name"
    done
}

# Record one failing finding.
_contract_finding() {
    local skill="$1" msg="$2"
    echo "  FAIL: $skill: $msg"
    return 1
}

# ── Frontmatter parsing ───────────────────────────────────────────────────

# Line number of the closing `---`. Empty when line 1 is not `---` or no
# closing delimiter follows it.
_contract_fm_end() {
    /usr/bin/awk 'NR==1 && $0 != "---" { exit } NR > 1 && $0 == "---" { print NR; exit }' "$1"
}

_contract_fm_lines() {
    local file="$1" end="$2"
    [[ "$end" -gt 2 ]] || return 0
    /usr/bin/sed -n "2,$((end - 1))p" "$file"
}

# First value for a key, unquoted and trimmed. `cut -f2-` keeps every later
# colon, so `allowed-tools: Bash(gh issue:*)` survives intact.
_contract_fm_value() {
    local file="$1" end="$2" key="$3"
    _contract_fm_lines "$file" "$end" \
        | /usr/bin/grep -E "^${key}:" \
        | /usr/bin/head -1 \
        | /usr/bin/cut -d: -f2- \
        | /usr/bin/tr -d "\"'" \
        | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# ── Tests ─────────────────────────────────────────────────────────────────

test_contract_frontmatter_is_a_delimited_key_value_block() {
    local rc=0 skill file end bad
    for skill in $(_contract_skills); do
        file="$REPO_ROOT/skills/$skill/SKILL.md"
        if [[ "$(/usr/bin/head -1 "$file")" != "---" ]]; then
            _contract_finding "$skill" "SKILL.md does not open with a '---' frontmatter line" || rc=1
            continue
        fi
        end=$(_contract_fm_end "$file")
        if [[ -z "$end" ]]; then
            _contract_finding "$skill" "frontmatter is never closed by a '---' line" || rc=1
            continue
        fi
        # One `key: value` per line is the repo's convention. Claude Code also
        # accepts YAML lists, but nothing here uses one and a flat block is
        # what makes every other check below a grep.
        bad=$(_contract_fm_lines "$file" "$end" \
                  | /usr/bin/grep -vE '^[[:space:]]*$' \
                  | /usr/bin/grep -vE '^[A-Za-z][A-Za-z0-9_-]*:' || true)
        if [[ -n "$bad" ]]; then
            _contract_finding "$skill" "frontmatter line is not 'key: value': $(echo "$bad" | /usr/bin/head -1)" || rc=1
        fi
    done
    return $rc
}

test_contract_name_matches_its_directory() {
    # The command comes from the directory name, so a `name` that disagrees
    # produces a skill whose listing label and invocation are different words.
    local rc=0 skill file end declared
    for skill in $(_contract_skills); do
        file="$REPO_ROOT/skills/$skill/SKILL.md"
        end=$(_contract_fm_end "$file") || true
        [[ -n "$end" ]] || continue
        declared=$(_contract_fm_value "$file" "$end" name)
        if [[ "$declared" != "$skill" ]]; then
            _contract_finding "$skill" "frontmatter says name='$declared'" || rc=1
        fi
    done
    return $rc
}

test_contract_argument_hint_flags_appear_in_the_body() {
    # A flag advertised in autocomplete that the body never parses is a flag
    # that silently does nothing.
    local rc=0 skill file end hint body flag
    for skill in $(_contract_skills); do
        file="$REPO_ROOT/skills/$skill/SKILL.md"
        end=$(_contract_fm_end "$file") || true
        [[ -n "$end" ]] || continue
        hint=$(_contract_fm_value "$file" "$end" argument-hint)
        [[ -n "$hint" ]] || continue
        body=$(/usr/bin/tail -n "+$((end + 1))" "$file")
        for flag in $(echo "$hint" | /usr/bin/grep -oE -- '--[A-Za-z][A-Za-z0-9-]*' | /usr/bin/sort -u); do
            if [[ "$body" != *"$flag"* ]]; then
                _contract_finding "$skill" "argument-hint offers '$flag' but the body never mentions it" || rc=1
            fi
        done
    done
    return $rc
}

# Split allowed-tools on commas and on spaces that are NOT inside parentheses,
# so `Bash(git add *)` stays one entry instead of three.
_contract_tool_entries() {
    echo "$1" | /usr/bin/awk '{
        depth = 0; entry = ""
        for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            if (c == "(") depth++
            if (c == ")") depth--
            if (depth == 0 && (c == " " || c == ",")) {
                if (entry != "") { print entry; entry = "" }
            } else {
                entry = entry c
            }
        }
        if (entry != "") print entry
    }'
}

test_contract_allowed_tools_are_prefix_scoped() {
    # allowed-tools pre-approves tools for the invoking turn without prompting.
    # Bare `Bash` therefore hands a scheduled run an unreviewed shell; a scoped
    # entry grants only the commands the body actually runs. Non-Bash tool
    # names may stay bare — they are not a command surface.
    local rc=0 skill file end tools entry
    for skill in $(_contract_skills); do
        file="$REPO_ROOT/skills/$skill/SKILL.md"
        end=$(_contract_fm_end "$file") || true
        [[ -n "$end" ]] || continue
        tools=$(_contract_fm_value "$file" "$end" allowed-tools)
        [[ -n "$tools" ]] || continue
        while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            if [[ "$entry" == "Bash" ]]; then
                _contract_finding "$skill" "allowed-tools grants bare 'Bash' — scope it, e.g. Bash(gh issue:*)" || rc=1
            elif [[ "$entry" =~ ^[A-Za-z_][A-Za-z0-9_-]*\(.+\)$ ]]; then
                : # prefix-scoped
            elif [[ "$entry" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
                : # a non-Bash tool name
            else
                _contract_finding "$skill" "allowed-tools entry '$entry' is neither a tool name nor Tool(prefix:*)" || rc=1
            fi
        done <<< "$(_contract_tool_entries "$tools")"
    done
    return $rc
}

test_contract_routine_invoked_skills_disable_model_invocation() {
    # On the nights of 2026-09-05 and 2026-09-06 every scheduled routine whose
    # prompt says "run the /name skill" halted without doing its work —
    # morning-triage ("the Skill tool refuses to run it"), morning-proposals,
    # dispatch-tasks-night and daily-summary-routine. The cause was
    # `disable-model-invocation: true` in the frontmatter of those skills. A
    # headless `claude -p` run is handed the routine prompt as natural language,
    # so it is the MODEL that reaches the skill, through the Skill tool — the one
    # path that flag blocks. A skill-to-skill `Skill(name="…")` call takes the
    # same path and dies the same silent death (five-run probe, 2026-09-03).
    #
    # This check used to REQUIRE the flag on any skill a prompt named, so the
    # suite enforced the outage. The rule is now the opposite: a skill a routine
    # prompt runs by /name, or another skill calls through the Skill tool, must
    # NOT carry the flag. A skill that carries it must be reachable by neither
    # route — it is a skill a human types. What replaces the flag for a routine
    # skill is its Step 0 precondition (refuse unless `ROUTINE` is exported or
    # `--dry-run` / `--force` was passed), not frontmatter.
    local rc=0 skill file end pattern declared by_prompt by_skill
    for skill in $(_contract_skills); do
        file="$REPO_ROOT/skills/$skill/SKILL.md"
        end=$(_contract_fm_end "$file") || true
        [[ -n "$end" ]] || continue

        # An invocation, not a citation: a run/invoke/fire/call verb has to
        # precede the `/name` token on the same line. The trailing boundary
        # keeps /dispatch-tasks from matching inside /dispatch-tasks-night, and
        # excludes `/` so a prompt naming a skill file by absolute path is not
        # read as calling it. `— use /plan-features`, quoted inside the HALT
        # text of another skill, stays a citation.
        pattern="(^|[^A-Za-z])(run|invoke|fire|call)[A-Za-z]*([^A-Za-z].*)?/${skill}"'([^A-Za-z0-9_/-]|$)'
        by_prompt=no
        /usr/bin/grep -rqiE -- "$pattern" "$RUNTIME_DIR"/prompts/ 2>/dev/null && by_prompt=yes

        by_skill=no
        /usr/bin/grep -qF -- "Skill(name=\"$skill\"" "$REPO_ROOT"/skills/*/SKILL.md 2>/dev/null && by_skill=yes

        declared=$(_contract_fm_value "$file" "$end" disable-model-invocation)
        [[ "$declared" == "true" ]] || continue

        if [[ "$by_prompt" == yes ]]; then
            _contract_finding "$skill" "a routine prompt runs /$skill, so disable-model-invocation must be absent — it blocks the Skill tool that a headless run reaches the skill through (2026-09-05/06 outage)" || rc=1
        fi
        if [[ "$by_skill" == yes ]]; then
            _contract_finding "$skill" "another skill calls Skill(name=\"$skill\"), so disable-model-invocation must be absent — with it set that call silently does nothing" || rc=1
        fi
    done
    return $rc
}

test_contract_model_and_effort_values_are_usable() {
    # Both fields are documented Claude Code frontmatter and both were verified
    # to override the CLI's --model / --effort in headless runs. A misspelled
    # effort is only warned about by the CLI, which then runs at its default.
    #
    # Presence is required, not just validity: S2 says the skill picks its own
    # model and effort and the runner's flags are the fallback. Checking only
    # the values let a skill omit both and silently inherit whatever the
    # routine was given, which is the drift S2 exists to stop. (The function
    # name predates the presence check; renaming it would churn three PRs
    # stacked on this branch.)
    local rc=0 skill file end value
    for skill in $(_contract_skills); do
        file="$REPO_ROOT/skills/$skill/SKILL.md"
        end=$(_contract_fm_end "$file") || true
        [[ -n "$end" ]] || continue

        if ! _contract_fm_lines "$file" "$end" | /usr/bin/grep -qE '^model:'; then
            _contract_finding "$skill" "no model: in frontmatter — S2 wants the skill to choose, not inherit" || rc=1
        else
            value=$(_contract_fm_value "$file" "$end" model)
            if [[ -z "$value" ]]; then
                _contract_finding "$skill" "model: is present but empty" || rc=1
            fi
        fi

        if ! _contract_fm_lines "$file" "$end" | /usr/bin/grep -qE '^effort:'; then
            _contract_finding "$skill" "no effort: in frontmatter — S2 wants the skill to choose, not inherit" || rc=1
        else
            value=$(_contract_fm_value "$file" "$end" effort)
            if [[ " $_CONTRACT_EFFORTS " != *" $value "* ]]; then
                _contract_finding "$skill" "effort: '$value' is not one of $_CONTRACT_EFFORTS" || rc=1
            fi
        fi
    done
    return $rc
}

test_contract_meta_declares_a_kind() {
    # `kind: coding` is how test_baseline_conformance.sh finds the skills that
    # must cite BASELINE.md, which is the only way a headless run is shown
    # Respect the Denial. A skill that loses the field drops out of that check
    # silently, so its presence is checked here.
    local rc=0 skill meta value
    for skill in $(_contract_skills); do
        meta="$REPO_ROOT/skills/$skill/META.md"
        if [[ ! -f "$meta" ]]; then
            _contract_finding "$skill" "META.md is missing" || rc=1
            continue
        fi
        value=$(/usr/bin/grep -E '^kind:' "$meta" | /usr/bin/head -1 \
                    | /usr/bin/cut -d: -f2- | /usr/bin/sed -e 's/[[:space:]]//g')
        case "$value" in
            coding|readonly|meta) ;;
            "") _contract_finding "$skill" "META.md has no 'kind:' line" || rc=1 ;;
            *)  _contract_finding "$skill" "META.md declares kind='$value' (expected coding, readonly or meta)" || rc=1 ;;
        esac
    done
    return $rc
}

test_contract_skill_md_stays_under_a_runaway_ceiling() {
    # Not a budget to write up to. The old 6/10 KB budgets decided what lived in
    # SKILL.md by the byte, and PRs moved rationale into references/ to fit. This
    # is a tripwire at twice the old cap: SKILL.md loads whole on every run, so a
    # body that doubles by accident should fail loudly rather than grow unseen.
    local rc=0 skill size
    for skill in $(_contract_skills); do
        size=$(/usr/bin/wc -c < "$REPO_ROOT/skills/$skill/SKILL.md" | /usr/bin/tr -d ' ')
        if [[ "$size" -gt "$_CONTRACT_SKILL_MD_CEILING" ]]; then
            _contract_finding "$skill" "SKILL.md is ${size}B, over the ${_CONTRACT_SKILL_MD_CEILING}B runaway ceiling" || rc=1
        fi
    done
    return $rc
}

test_contract_skills_invoked_with_arguments_carry_the_arguments_token() {
    # The 2026-09-07 dispatch outage. `dispatch-tasks` called
    # `Skill(name="work-on-task", args="18 --repo acme/GameTwo")` twice.
    # `work-on-task` runs with `context: fork`, so each worker's whole prompt is
    # its SKILL.md body after substitution — and that body held no `$ARGUMENTS`
    # placeholder for the arguments to land in. Both workers were handed the
    # file verbatim, both replied "I don't have an issue number to work on", the
    # dispatcher tripped its systemic-failure breaker, and issues #18–#24 went
    # untouched.
    #
    # `$0` is not a substitute. It is documented as the FIRST argument
    # (shorthand for `$ARGUMENTS[0]`, https://code.claude.com/docs/en/skills.md),
    # so the skills using it are using it correctly — but it names one argument
    # instead of proving the invocation arrived at all, and an empty one is
    # indistinguishable from an absent one. `$ARGUMENTS` is what a skill echoes
    # to make "no arguments reached me" a refusal rather than a confused run.
    local rc=0 skill file end body pattern by_skill by_prompt
    for skill in $(_contract_skills); do
        file="$REPO_ROOT/skills/$skill/SKILL.md"
        end=$(_contract_fm_end "$file") || true
        [[ -n "$end" ]] || continue

        # Invoked through the Skill tool by a *different* skill.
        by_skill=no
        if /usr/bin/grep -lF -- "Skill(name=\"$skill\"" "$REPO_ROOT"/skills/*/SKILL.md 2>/dev/null \
               | /usr/bin/grep -qvxF "$REPO_ROOT/skills/$skill/SKILL.md"; then
            by_skill=yes
        fi

        # Run by a routine prompt that passes a literal argument: `/name`
        # followed by a `<placeholder>` or a digit. Prose that names the skill
        # with no argument ("Run `/daily-summary`.") is not covered.
        pattern="/${skill}"'`?[[:space:]]+(<|[0-9])'
        by_prompt=no
        /usr/bin/grep -rqE -- "$pattern" "$RUNTIME_DIR"/prompts/ 2>/dev/null && by_prompt=yes

        [[ "$by_skill" == yes || "$by_prompt" == yes ]] || continue

        body=$(/usr/bin/tail -n "+$((end + 1))" "$file")
        if [[ "$body" != *'$ARGUMENTS'* ]]; then
            _contract_finding "$skill" "is invoked with arguments but its body has no \$ARGUMENTS placeholder — a forked skill sees only its substituted body, so the arguments never arrive (2026-09-07 dispatch outage)" || rc=1
        fi
    done
    return $rc
}

test_contract_headless_skills_disallow_the_agent_tool() {
    # The 2026-09-07 dispatch outage, part two. A forked `work-on-task
    # --dry-run`, invoked by `dispatch-tasks` through the Skill tool, received
    # its arguments (PR #31 had just fixed that), read the issue and the code —
    # and then spawned a background research subagent, ending its turn with
    # "Waiting on the primitives-search agent … before finalizing the plan."
    # A forked skill that ends its turn has RETURNED: no `PLANNED:` line and no
    # `WORK:` line ever arrived. `dispatch-tasks` scores a missing `WORK:` line
    # as `halted`, two halts in a row trip its systemic-failure breaker, and the
    # night dispatched nothing.
    #
    # A skill that runs headless gets one turn to print its contract line, so it
    # must not hold the tool that can end that turn early. `disallowed-tools`
    # removes a tool from the pool for as long as the skill is active
    # (https://code.claude.com/docs/en/skills.md, where `Agent` — not the older
    # `Task` — is the name of the subagent tool). The worker reads the code
    # itself.
    local rc=0 skill file end pattern tools forked by_prompt found entry
    for skill in $(_contract_skills); do
        file="$REPO_ROOT/skills/$skill/SKILL.md"
        end=$(_contract_fm_end "$file") || true
        [[ -n "$end" ]] || continue

        forked=no
        [[ "$(_contract_fm_value "$file" "$end" context)" == "fork" ]] && forked=yes

        # Same shape as the $ARGUMENTS check above: a routine prompt running
        # `/name` with a literal argument is a headless invocation.
        pattern="/${skill}"'`?[[:space:]]+(<|[0-9])'
        by_prompt=no
        /usr/bin/grep -rqE -- "$pattern" "$RUNTIME_DIR"/prompts/ 2>/dev/null && by_prompt=yes

        [[ "$forked" == yes || "$by_prompt" == yes ]] || continue

        tools=$(_contract_fm_value "$file" "$end" disallowed-tools)
        found=no
        while IFS= read -r entry; do
            [[ "$entry" == "Agent" ]] && found=yes
        done <<< "$(_contract_tool_entries "$tools")"
        if [[ "$found" != yes ]]; then
            _contract_finding "$skill" "runs headless (context: fork, or a routine prompt runs /$skill with arguments) but its frontmatter does not disallow 'Agent' — a skill that delegates ends its turn without its contract line, and a return without that line reads as a halt (2026-09-07 dispatch outage)" || rc=1
        fi
    done
    return $rc
}
