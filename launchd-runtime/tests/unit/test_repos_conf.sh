#!/bin/bash
# Tests for repos.conf — the get_repo_path() function.

test_repos_conf_resolves_all_known_repos() {
    . "$RUNTIME_DIR/repos.conf.example"

    local rc=0
    local known_repos=(
        "amarcu/StarBonk"
        "amarcu/StarBonk-backend"
        "acme/GameTwo"
        "acme/engine-toolkit"
        "acme/game-engine"
        "acme/portfolio-site"
        "acme/club-site"
        "acme/club_app"
        "acme/notes"
    )
    for repo in "${known_repos[@]}"; do
        local path=$(get_repo_path "$repo")
        if [[ -z "$path" ]]; then
            echo "  FAIL: $repo not in get_repo_path map"
            rc=1
        elif [[ "$path" != /Users/* ]]; then
            echo "  FAIL: $repo → $path (not an absolute /Users/ path)"
            rc=1
        fi
    done
    return $rc
}

test_repos_conf_returns_empty_for_unknown_repo() {
    . "$RUNTIME_DIR/repos.conf.example"

    local result=$(get_repo_path "acme/nonexistent-repo-xyz")
    if [[ -n "$result" ]]; then
        echo "  FAIL: unknown repo should return empty, got '$result'"
        return 1
    fi
    return 0
}

test_repos_conf_parses_under_bash_3() {
    # macOS default is bash 3.2 (no associative arrays). Verify our
    # case-statement-based function works there.
    local out
    out=$(/bin/bash -c '. "'"$REPOS_CONF"'" && get_repo_path "acme/club-site"')
    if [[ "$out" != "$HOME/code/club-site" ]]; then
        echo "  FAIL: bash 3 fallback failed, got '$out'"
        return 1
    fi
    return 0
}

test_workspaces_array_matches_defined_arrays() {
    # The bug this catches: defining a WORKSPACE_* array and forgetting to
    # register it in WORKSPACES (so it is silently never scanned), or the
    # reverse. Asserting a fixed workspace count instead would just have to
    # be edited every time a project is added or retired, which is churn
    # that teaches people to update the number without reading the test.
    . "$RUNTIME_DIR/repos.conf.example"
    local rc=0 entry var defined registered

    for entry in "${WORKSPACES[@]}"; do
        var="${entry#*:}"
        if ! declare -p "$var" >/dev/null 2>&1; then
            echo "  FAIL: WORKSPACES names $var, which is not defined"
            rc=1
            continue
        fi
        # bash 3.2 (macOS default) has no namerefs — use indirect expansion.
        local count
        eval "count=\${#${var}[@]}"
        if [[ "$count" -eq 0 ]]; then
            echo "  FAIL: $var is registered in WORKSPACES but empty"
            rc=1
        fi
    done

    registered=$(printf '%s\n' "${WORKSPACES[@]}" | /usr/bin/sed 's/.*://' | /usr/bin/sort)
    defined=$(/usr/bin/grep -oE '^WORKSPACE_[A-Z_]+' "$RUNTIME_DIR/repos.conf.example" | /usr/bin/sort -u)
    if [[ "$registered" != "$defined" ]]; then
        echo "  FAIL: WORKSPACE_* arrays and WORKSPACES registrations disagree"
        /usr/bin/diff <(echo "$defined") <(echo "$registered") | /usr/bin/sed 's/^/    /'
        rc=1
    fi
    return $rc
}

test_repos_conf_stale_days_defaults_to_14_and_excepts_personal_sites() {
    # MT-1: the thresholds used to live in morning-triage's prose, named for
    # three of the six workspaces. A workspace added after that prose was
    # written got no threshold at all, and the model picked one per run.
    . "$RUNTIME_DIR/repos.conf.example"

    local rc=0
    assert_equal 30 "$(get_stale_days "Personal Sites")" \
        "the workspace display name resolves" || rc=1
    assert_equal 30 "$(get_stale_days "acme/club_app")" \
        "so does a repo inside that workspace" || rc=1
    assert_equal 14 "$(get_stale_days "amarcu/StarBonk")" \
        "a repo in any other workspace gets the default" || rc=1
    assert_equal 14 "$(get_stale_days "Strategy Game")" \
        "and so does a workspace with no entry of its own" || rc=1
    assert_equal 14 "$(get_stale_days "acme/not-a-repo")" \
        "an unknown name gets the default rather than an empty string" || rc=1
    return $rc
}

test_repos_conf_stale_days_covers_every_personal_sites_repo() {
    # The workspace name and its member repos must not disagree: a repo added
    # to WORKSPACE_PERSONAL without a case arm would silently be triaged at 14
    # days while its workspace header said 30.
    . "$RUNTIME_DIR/repos.conf.example"

    local rc=0 repo
    for repo in "${WORKSPACE_PERSONAL[@]}"; do
        if [[ "$(get_stale_days "$repo")" != "$(get_stale_days "Personal Sites")" ]]; then
            echo "  FAIL: $repo is in WORKSPACE_PERSONAL but get_stale_days disagrees with the workspace"
            rc=1
        fi
    done
    return $rc
}

test_repos_conf_dispatch_caps_hold_the_relation_the_gate_assumes() {
    # dispatch-tasks' gate arithmetic is prose, not a script:
    #     slots   = DISPATCH_TOTAL_MAX    - open_agent_prs
    #     slots_r = DISPATCH_PER_REPO_MAX - open_agent_prs_r   (per repo)
    #     budget  = min(slots, DISPATCH_RUN_MAX)
    # It only behaves if the three numbers stand in the right relation. A
    # per-repo cap at or above the global ceiling is a cap that can never bind
    # before the ceiling does, which silently restores the weakest-link gate it
    # was added to remove: one repo alone could shut dispatch for the roster. A
    # run cap above the ceiling can never bind at all. Zero anywhere stops
    # dispatch entirely, which no cap is meant to do on its own.
    . "$RUNTIME_DIR/repos.conf.example"

    # Indirect expansion, not eval: `${!cap}` reads the variable $cap names
    # without handing its contents to the parser. bash 3.2 (macOS default) has
    # had it since 2.0 — it is namerefs that need 4.3.
    local rc=0 cap value
    for cap in DISPATCH_TOTAL_MAX DISPATCH_PER_REPO_MAX DISPATCH_RUN_MAX; do
        value="${!cap:-}"
        if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
            echo "  FAIL: $cap is '$value', not a positive integer"
            rc=1
        fi
    done
    [[ "$rc" -eq 0 ]] || return 1

    if [[ "$DISPATCH_PER_REPO_MAX" -ge "$DISPATCH_TOTAL_MAX" ]]; then
        echo "  FAIL: DISPATCH_PER_REPO_MAX ($DISPATCH_PER_REPO_MAX) must be below"
        echo "        DISPATCH_TOTAL_MAX ($DISPATCH_TOTAL_MAX), or one repo can reach"
        echo "        the global ceiling alone and stall every other repo."
        rc=1
    fi
    if [[ "$DISPATCH_RUN_MAX" -gt "$DISPATCH_TOTAL_MAX" ]]; then
        echo "  FAIL: DISPATCH_RUN_MAX ($DISPATCH_RUN_MAX) exceeds DISPATCH_TOTAL_MAX"
        echo "        ($DISPATCH_TOTAL_MAX), so budget = min(slots, run_max) can never"
        echo "        be the run cap and the per-run bound is decorative."
        rc=1
    fi
    return $rc
}

test_repos_conf_get_repo_base_sends_gametwo_work_to_live_dev() {
    # GameTwo ships from live-dev; its GitHub default main diverged in 2025,
    # so work based on main never reached a player.
    local rc=0
    assert_equal "live-dev" "$(. "$RUNTIME_DIR/repos.conf.example" && get_repo_base acme/GameTwo)" \
        "GameTwo work is based on live-dev" || rc=1
    # Any other repo falls back to its GitHub default branch, so a skill filing an
    # issue and a worker picking its base ask one function (Grok, PR #71 f1).
    local stub; stub=$(/usr/bin/mktemp -d /tmp/agentic-test-base.XXXXXX)
    printf '#!/bin/bash\n[[ "$*" == "repo view amarcu/StarBonk --json defaultBranchRef -q .defaultBranchRef.name" ]] && echo main\n' > "$stub/gh"
    /bin/chmod +x "$stub/gh"
    assert_equal "main" "$(PATH="$stub:$PATH"; . "$RUNTIME_DIR/repos.conf.example" && get_repo_base amarcu/StarBonk)" \
        "any other repo gets its default branch" || rc=1
    /bin/rm -rf "$stub"
    return $rc
}

test_repos_conf_every_skill_resolves_its_base_through_get_repo_base() {
    # An issue's BASE BRANCH line outranks the map in work-on-task, so a skill
    # that stamped issues with the default branch would route GameTwo work
    # back to main whatever the map says.
    local rc=0 skill
    for skill in work-on-task propose-tasks plan-features; do
        if ! /usr/bin/grep -q 'get_repo_base' "$REPO_ROOT/skills/$skill/SKILL.md"; then
            echo "  FAIL: $skill/SKILL.md does not resolve its base through get_repo_base"; rc=1
        fi
        if /usr/bin/grep -q 'defaultBranchRef' "$REPO_ROOT/skills/$skill/SKILL.md"; then
            echo "  FAIL: $skill/SKILL.md looks up the default branch itself, bypassing the map"; rc=1
        fi
    done
    return $rc
}
