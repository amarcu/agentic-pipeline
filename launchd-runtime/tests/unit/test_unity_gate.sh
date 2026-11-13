#!/bin/bash
# Tests for bin/unity-gate.
#
# Unity is never invoked here. The gate takes its editor from $UNITY_EDITOR so
# these run on any machine, including one with no editor installed — which is
# most of them. The mocks under fixtures/mock-unity-editor reproduce the exit
# code and report shape of each real outcome, all captured from actual runs.

GATE="$RUNTIME_DIR/bin/unity-gate"
UNITY_MOCKS="$FIXTURES_DIR/mock-unity-editor"

# A one-commit repo is enough: the gate only needs a ref it can worktree.
_gate_repo() {
    local dir
    dir=$(/usr/bin/mktemp -d /tmp/unity-gate-test.XXXXXX)
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name "Test"
    echo "placeholder" > "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" -c commit.gpgsign=false commit -qm "init"
    echo "$dir"
}

_run_gate() {
    local mock="$1" repo="$2"
    UNITY_EDITOR="$UNITY_MOCKS/$mock" "$GATE" "$repo" main 2>/dev/null
}

# ── Verdict classification ────────────────────────────────────────────────

test_unity_gate_reports_pass_with_test_count() {
    local repo out; repo=$(_gate_repo)
    out=$(_run_gate pass-with-tests "$repo")
    /bin/rm -rf "$repo"
    assert_contains "$out" '"verdict":"pass"' "green suite" || return 1
    assert_contains "$out" '"tests":3' "test count carried through" || return 1
}

# An empty suite exits 0 and reports result="Passed". Collapsing it into
# "pass" is what let non-compiling tests reach StarBonk's main.
test_unity_gate_separates_empty_suite_from_green_suite() {
    local repo out; repo=$(_gate_repo)
    out=$(_run_gate pass-no-tests "$repo")
    /bin/rm -rf "$repo"
    assert_contains "$out" '"verdict":"pass-no-tests"' "empty suite" || return 1
    assert_not_contains "$out" '"verdict":"pass"' "must not read as green" || return 1
}

test_unity_gate_names_the_failing_tests() {
    local repo out; repo=$(_gate_repo)
    out=$(_run_gate tests-failed "$repo")
    /bin/rm -rf "$repo"
    assert_contains "$out" '"verdict":"tests-failed"' "failure verdict" || return 1
    assert_contains "$out" '"failed":1' "failure count" || return 1
    assert_contains "$out" 'GateContractTest.FailingTest' "names the failure" || return 1
    assert_not_contains "$out" 'GateContractTest.PassingTest' "only failures listed" || return 1
}

test_unity_gate_quotes_the_compiler_errors() {
    local repo out; repo=$(_gate_repo)
    out=$(_run_gate compile-error "$repo")
    /bin/rm -rf "$repo"
    assert_contains "$out" '"verdict":"compile-error"' "compile verdict" || return 1
    assert_contains "$out" 'CS0246' "cites the error code" || return 1
    assert_contains "$out" 'SectorData' "cites the missing type" || return 1
}

# Exit 6 covers both a failed compile and a dead licence. Only the first has
# error CS lines, and a reviewer must not be handed one as though it were the
# other.
test_unity_gate_separates_infrastructure_failure_from_compile_failure() {
    local repo out; repo=$(_gate_repo)
    out=$(_run_gate infra-error "$repo")
    /bin/rm -rf "$repo"
    assert_contains "$out" '"verdict":"infra-error"' "infra verdict" || return 1
    assert_not_contains "$out" 'compile-error' "not misreported as a compile failure" || return 1
}

# ── CLI version guard ─────────────────────────────────────────────────────

# Unity Hub still ships beta.5, which reports a failed test as exit 6. If the
# gate accepted it, "tests failed" would silently arrive as "compile error".
test_unity_gate_ends_a_run_that_never_finishes() {
    local repo out; repo=$(_gate_repo)
    out=$(GATE_TIMEOUT=2 _run_gate hangs "$repo")
    /bin/rm -rf "$repo"
    assert_contains "$out" '"verdict":"infra-error"' "a hung editor is no verdict, not a wait" || return 1
    assert_contains "$out" 'did not finish within 2s' "and says why" || return 1
}

test_unity_gate_finds_the_editor_through_hubs_install_path() {
    # The merge lane sets no UNITY_EDITOR. The pipeline host's Hub keeps its
    # editors outside /Applications, under the path in secondaryInstallPath.json.
    local repo out fake_home exe; repo=$(_gate_repo); fake_home=$(/usr/bin/mktemp -d /tmp/unity-gate-home.XXXXXX)
    /bin/mkdir -p "$repo/ProjectSettings" "$fake_home/Library/Application Support/UnityHub"
    echo "m_EditorVersion: 1999.9.9f1" > "$repo/ProjectSettings/ProjectVersion.txt"
    git -C "$repo" add ProjectSettings
    git -C "$repo" -c commit.gpgsign=false commit -qm "pin an editor"
    printf '"%s"' "$fake_home/Unity/Editors" \
        > "$fake_home/Library/Application Support/UnityHub/secondaryInstallPath.json"
    exe="$fake_home/Unity/Editors/1999.9.9f1/Unity.app/Contents/MacOS"
    /bin/mkdir -p "$exe"
    /bin/cp "$UNITY_MOCKS/pass-with-tests" "$exe/Unity"
    out=$(HOME="$fake_home" "$GATE" "$repo" main 2>/dev/null)
    /bin/rm -rf "$repo" "$fake_home"
    assert_contains "$out" '"verdict":"pass","tests":3' "the editor under Hub's install path ran" || return 1
}

test_unity_gate_names_an_editor_that_is_not_installed() {
    # No UNITY_EDITOR: the gate resolves the editor from ProjectVersion.txt
    # and Unity Hub's install path, and HOME here has no Hub settings.
    local repo out fake_home; repo=$(_gate_repo); fake_home=$(/usr/bin/mktemp -d /tmp/unity-gate-home.XXXXXX)
    /bin/mkdir -p "$repo/ProjectSettings"
    echo "m_EditorVersion: 1999.9.9f1" > "$repo/ProjectSettings/ProjectVersion.txt"
    git -C "$repo" add ProjectSettings
    git -C "$repo" -c commit.gpgsign=false commit -qm "pin an editor"
    out=$(HOME="$fake_home" "$GATE" "$repo" main 2>/dev/null)
    /bin/rm -rf "$repo" "$fake_home"
    assert_contains "$out" '"verdict":"error"' "a missing editor is an error" || return 1
    assert_contains "$out" '1999.9.9f1 is not installed' "naming the version it looked for" || return 1
}

# ── Argument handling ─────────────────────────────────────────────────────

test_unity_gate_rejects_a_path_that_is_not_a_repo() {
    local out rc
    out=$(UNITY_EDITOR="$UNITY_MOCKS/pass-with-tests" "$GATE" /nonexistent/repo 2>/dev/null); rc=$?
    assert_exit 2 "$rc" "non-repo exits 2" || return 1
    assert_contains "$out" 'not a git repository' "names the real problem" || return 1
}

test_unity_gate_rejects_a_missing_argument() {
    local out rc
    out=$(UNITY_EDITOR="$UNITY_MOCKS/pass-with-tests" "$GATE" 2>/dev/null); rc=$?
    assert_exit 2 "$rc" "no args exits 2" || return 1
    assert_contains "$out" 'usage:' "prints usage as JSON, not a shell error" || return 1
}

test_unity_gate_rejects_an_unknown_ref() {
    local repo out rc; repo=$(_gate_repo)
    out=$(UNITY_EDITOR="$UNITY_MOCKS/pass-with-tests" "$GATE" "$repo" no-such-ref 2>/dev/null); rc=$?
    /bin/rm -rf "$repo"
    assert_exit 2 "$rc" "unknown ref exits 2" || return 1
    assert_contains "$out" 'no-such-ref' "names the ref" || return 1
    # "invalid reference" and "already checked out" need different fixes, and
    # this JSON is all the caller sees.
    assert_contains "$out" 'invalid reference' "keeps git's own reason" || return 1
}

# ── Isolation ─────────────────────────────────────────────────────────────

# Importing a project writes .meta files into whatever tree it runs on, so the
# gate must never run against the caller's checkout.
test_unity_gate_leaves_no_worktree_behind() {
    local repo out; repo=$(_gate_repo)
    _run_gate pass-with-tests "$repo" >/dev/null
    out=$(git -C "$repo" worktree list)
    local count; count=$(echo "$out" | /usr/bin/grep -c .)
    /bin/rm -rf "$repo"
    assert_equal "1" "$count" "only the main worktree remains" || return 1
}

test_unity_gate_leaves_the_checkout_clean() {
    local repo status; repo=$(_gate_repo)
    _run_gate pass-with-tests "$repo" >/dev/null
    status=$(git -C "$repo" status --porcelain)
    /bin/rm -rf "$repo"
    assert_equal "" "$status" "source checkout untouched" || return 1
}
