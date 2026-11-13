#!/bin/bash
# Static checks: every active repo's host tooling is declared, or its absence is.
#
# 2026-09-07: two GameTwo workers each spent a dispatch slot and halted at
# the gate — the game-engine checkout the Mac client links against was not on disk
# and full Xcode was absent — while `pr-review-bundle` could build no bundle at
# all on the same host, because its gh predates `closingIssuesReferences`.
# Nothing declared any of it, so the only way to learn it was to spend a worker.
#
# These tests do not check the host (that is `make doctor`, which is
# host-dependent by nature and cannot live in a suite that must pass on every
# machine). They check that the DECLARATION exists and parses.

_REQ_EXCEPTIONS="$TESTS_DIR/static/requirements-exceptions.txt"
_REQ_TEMPLATES="$RUNTIME_DIR/requirements-templates"
_REQ_VERBS="cmd path env check"

# Every `owner/repo` listed as an exception, reasons stripped.
_req_excepted_repos() {
    /usr/bin/sed 's/#.*//' "$_REQ_EXCEPTIONS" 2>/dev/null \
        | /usr/bin/awk 'NF { print $1 }'
}

# Is this repo's host tooling declared anywhere check-requirements will read?
# Two places, in the order the script itself searches them: the checkout's own
# manifest, then the template staged under `<owner>-<repo>.conf`.
_req_repo_is_covered() {
    local repo="$1" path
    path=$(get_repo_path "$repo")
    [[ -n "$path" && -f "$path/agent/requirements.conf" ]] && return 0
    [[ -f "$_REQ_TEMPLATES/${repo/\//-}.conf" ]] && return 0
    return 1
}

test_requirements_every_active_repo_declares_or_excepts_its_tooling() {
    . "$RUNTIME_DIR/repos.conf.example"
    local rc=0 repo excepted
    excepted=$(_req_excepted_repos)

    for repo in "${ACTIVE_REPOS[@]}"; do
        # Declared in the repo itself (where it belongs) or staged as a
        # template check-requirements falls back to. Either is coverage.
        _req_repo_is_covered "$repo" && continue
        if printf '%s\n' "$excepted" | /usr/bin/grep -qxF "$repo"; then
            continue
        fi
        echo "  FAIL: $repo has no agent/requirements.conf, no staged template in"
        echo "        requirements-templates/, and no line in"
        echo "        $(basename "$_REQ_EXCEPTIONS") saying why."
        rc=1
    done
    return $rc
}

test_requirements_no_repo_is_both_covered_and_excepted() {
    # Grok on PR #35: GameTwo and StarBonk were the two host gaps this
    # feature was built to close, and both sat in the exception list while
    # their manifests sat unread in requirements-templates/. Now that
    # check-requirements reads those templates, an exception for a covered repo
    # is stale text claiming a gap that no longer exists — and the next reader
    # trusts it over the file that is actually being evaluated.
    . "$RUNTIME_DIR/repos.conf.example"
    local rc=0 repo
    for repo in $(_req_excepted_repos); do
        if _req_repo_is_covered "$repo"; then
            echo "  FAIL: exception '$repo' names a repo whose tooling IS declared"
            echo "        (its own manifest, or requirements-templates/) — delete the line"
            rc=1
        fi
    done
    return $rc
}

test_requirements_exceptions_are_documented_and_still_active() {
    # An exception with no reason is an exception nobody can retire, and one
    # naming a repo that has left ACTIVE_REPOS is stale text that reads as
    # policy. Both rot the file into decoration.
    . "$RUNTIME_DIR/repos.conf.example"
    local rc=0 line repo reason

    while IFS= read -r line; do
        [[ -z "${line// }" || "${line:0:1}" == "#" ]] && continue
        repo="${line%%#*}"
        repo="${repo// }"
        reason="${line#*#}"
        [[ "$reason" == "$line" ]] && reason=""

        if [[ -z "${reason// }" ]]; then
            echo "  FAIL: exception '$repo' has no reason after its '#'"
            rc=1
        fi
        if ! is_active_repo "$repo"; then
            echo "  FAIL: exception '$repo' is not in ACTIVE_REPOS — delete the line"
            rc=1
        fi
    done < "$_REQ_EXCEPTIONS"
    return $rc
}

# Every manifest this repo ships: its own, plus the ones staged for a repo
# whose checkout was not clean enough to commit into.
_req_manifest_files() {
    local file
    [[ -f "$REPO_ROOT/agent/requirements.conf" ]] && echo "$REPO_ROOT/agent/requirements.conf"
    for file in "$_REQ_TEMPLATES"/*.conf; do
        [[ -f "$file" ]] && echo "$file"
    done
    return 0
}

test_requirements_manifests_use_only_the_four_verbs() {
    # A typo'd verb fails check-requirements outright at runtime — exit 1,
    # status manifest-error, nothing probed — so a manifest committed with one
    # blocks every issue in that repo until a human fixes it. Catching it here
    # turns a night that halts into a suite that goes red before the commit.
    local rc=0 file lineno verb spec
    while IFS= read -r file; do
        lineno=0
        while IFS= read -r line; do
            lineno=$((lineno + 1))
            spec="${line%% #*}"
            [[ -z "${spec// }" || "${spec:0:1}" == "#" ]] && continue
            [[ "$spec" == gate:* ]] && continue
            verb=$(printf '%s' "$spec" | /usr/bin/awk '{ print $1 }')
            if [[ " $_REQ_VERBS " != *" $verb "* ]]; then
                echo "  FAIL: $file:$lineno unknown verb '$verb' (one of: $_REQ_VERBS)"
                rc=1
            elif [[ $(printf '%s' "$spec" | /usr/bin/awk '{ print NF }') -lt 2 ]]; then
                echo "  FAIL: $file:$lineno '$verb' has no argument"
                rc=1
            fi
        done < "$file"
    done < <(_req_manifest_files)
    return $rc
}

test_requirements_manifests_declare_a_known_gate() {
    local rc=0 file value
    while IFS= read -r file; do
        while IFS= read -r line; do
            [[ "$line" == gate:* ]] || continue
            value=$(printf '%s' "${line#gate:}" | /usr/bin/tr -d ' ')
            if [[ "$value" != "required" && "$value" != "advisory" ]]; then
                echo "  FAIL: $file declares gate '$value' (required|advisory)"
                rc=1
            fi
        done < "$file"
    done < <(_req_manifest_files)
    return $rc
}

test_requirements_templates_are_named_for_the_repo_they_belong_to() {
    # The filename is the instruction: <owner>-<repo>.conf copies to
    # <owner/repo>'s own agent/requirements.conf. A template whose name matches
    # no known repo is a template nobody will ever install.
    . "$RUNTIME_DIR/repos.conf.example"
    local rc=0 file base repo
    for file in "$_REQ_TEMPLATES"/*.conf; do
        [[ -f "$file" ]] || continue
        base=$(/usr/bin/basename "$file" .conf)
        repo="${base%%-*}/${base#*-}"
        if [[ -z "$(get_repo_path "$repo")" ]]; then
            echo "  FAIL: $(basename "$file") names '$repo', which repos.conf cannot resolve"
            rc=1
        fi
    done
    return $rc
}

# ── The doctor targets ────────────────────────────────────────────────────
#
# Copilot on PR #35: the Makefile advertised `make doctor-acme/GameTwo`,
# and make splits a target on `/` before matching a pattern rule, so
# `doctor-%` never saw it and the documented command died with "No rule to
# make target". A command written in the docs as runnable has to run.

# Every `make doctor…` command written in the docs or the Makefile's own help.
# The trailing name must start alphanumerically, so the placeholder form
# `make doctor-<repo>` contributes `make doctor` and not a target with a stem
# of `<repo>`.
_req_documented_doctor_targets() {
    /usr/bin/grep -ohE 'make doctor(-[A-Za-z0-9][A-Za-z0-9_/.-]*)?' \
        "$REPO_ROOT/README.md" "$RUNTIME_DIR/COMMANDS.md" "$REPO_ROOT/Makefile" 2>/dev/null \
        | /usr/bin/sed 's/^make //' \
        | /usr/bin/sort -u
}

test_requirements_every_documented_doctor_target_resolves() {
    local rc=0 target out
    local found=0

    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        found=$((found + 1))
        # -n prints the recipe without running it, so this costs nothing and
        # still fails on a target make cannot match.
        if ! out=$(/usr/bin/make -C "$REPO_ROOT" -n "$target" 2>&1); then
            echo "  FAIL: 'make $target' is documented but is not a target make can build:"
            printf '%s\n' "$out" | /usr/bin/head -3 | /usr/bin/sed 's/^/    /'
            rc=1
        fi
    done < <(_req_documented_doctor_targets)

    if [[ "$found" -lt 2 ]]; then
        echo "  FAIL: found $found documented 'make doctor' command(s); expected at least"
        echo "        the roster form and the per-repo form."
        rc=1
    fi
    return $rc
}

test_requirements_a_slashed_doctor_target_is_not_documented_anywhere() {
    # The other half: make cannot match one, so nothing may advertise one.
    local hits
    hits=$(/usr/bin/grep -rnE 'make doctor-[A-Za-z0-9_.-]+/' \
               "$REPO_ROOT/README.md" "$RUNTIME_DIR/COMMANDS.md" "$REPO_ROOT/Makefile" \
               2>/dev/null || true)
    if [[ -n "$hits" ]]; then
        echo "  FAIL: a 'make doctor-<owner>/<repo>' form is documented; make splits a"
        echo "        target on '/' before matching 'doctor-%', so it resolves to nothing:"
        printf '%s\n' "$hits" | /usr/bin/sed 's/^/    /'
        return 1
    fi
    return 0
}

test_requirements_cmd_lines_use_the_only_operator_there_is() {
    # `>=` or nothing. The runtime refuses everything else, and it refuses the
    # WHOLE file, so a manifest committed with `cmd gh <2.92` blocks every
    # issue in that repo until a human fixes it. Same grammar as
    # CMD_SPEC_RE in bin/check-requirements; catch it before the commit.
    local rc=0 file lineno line spec
    while IFS= read -r file; do
        lineno=0
        while IFS= read -r line; do
            lineno=$((lineno + 1))
            spec="${line%% #*}"
            spec="${spec#"${spec%%[![:space:]]*}"}"
            [[ "$spec" == cmd\ * ]] || continue
            spec="${spec#cmd }"
            spec="${spec%"${spec##*[![:space:]]}"}"
            if [[ ! "$spec" =~ ^[^[:space:]]+([[:space:]]+\>=[[:space:]]*[^[:space:]]+)?$ ]]; then
                echo "  FAIL: $file:$lineno 'cmd $spec' — the only shapes are"
                echo "        'cmd <name>' and 'cmd <name> >=<version>'"
                rc=1
            fi
        done < "$file"
    done < <(_req_manifest_files)
    return $rc
}
