#!/bin/bash
# Unit tests for bin/install-requirements.
#
# The script's header makes four safety claims, and until this file existed
# nothing checked any of them: it never runs as root, never installs Xcode or
# activates a Unity licence, never installs unattended, and never reports
# success it has not verified. A guardrail nobody tests is a guardrail that
# quietly stops working.
#
# The fourth is here because Copilot found it broken on PR #35: a manifest
# check-requirements rejects carries NO requirements in its report, so the plan
# built from it was empty and the script printed "nothing missing" and exited 0
# over a file nobody could read — the same lie the checker itself had just been
# fixed for.
#
# Everything runs in dry-run mode, which is also what a non-TTY invocation gets
# by design, so no test here can install anything. The run branch is reachable
# only from a terminal, on purpose, and is exercised by hand.

_inst_setup() {
    TEST_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-inst.XXXXXX)
    INST_BIN="$RUNTIME_DIR/bin/install-requirements"
    INST_ROOT="$TEST_TMP/repo"
    INST_CONF="$TEST_TMP/repos.conf"
    /bin/mkdir -p "$INST_ROOT/agent" "$TEST_TMP/empty"

    /bin/cat > "$INST_CONF" <<EOF
ACTIVE_REPOS=("acme/fixture")
get_repo_path() {
    case "\$1" in
        acme/fixture) echo "$INST_ROOT" ;;
        acme/empty)   echo "$TEST_TMP/empty" ;;
        *)              echo "" ;;
    esac
}
EOF
}

_inst_teardown() {
    /bin/rm -rf "$TEST_TMP"
}

_inst_manifest() {
    /bin/cat > "$INST_ROOT/agent/requirements.conf"
}

# Stdin is closed, so this also exercises the not-a-TTY default on every call.
_inst_run() {
    REPOS_CONF="$INST_CONF" "$INST_BIN" "$@" < /dev/null 2>&1
}

test_install_requirements_refuses_to_plan_from_an_unparsable_manifest() {
    _inst_setup
    local rc=0 out
    _inst_manifest <<'EOF'
cmd gh
binary jq
EOF

    out=$(_inst_run acme/fixture --dry-run)
    assert_exit 1 $? "an unreadable manifest is not an empty plan" || rc=1
    assert_contains "$out" "manifest-error" || rc=1
    assert_not_contains "$out" "nothing missing" \
        "the failure this test exists for: an empty plan read as success" || rc=1
    assert_contains "$out" "unknown verb 'binary'" "and it says which line" || rc=1
    _inst_teardown
    return $rc
}

test_install_requirements_reports_nothing_missing_only_when_nothing_is() {
    _inst_setup
    local rc=0 out
    _inst_manifest <<'EOF'
cmd sh
EOF

    out=$(_inst_run acme/fixture --dry-run)
    assert_exit 0 $? "a satisfied manifest has nothing to install" || rc=1
    assert_contains "$out" "nothing missing" || rc=1

    # A repo that declares nothing needs nothing — the same output, and it must
    # not be confused with the manifest-error case above.
    out=$(_inst_run acme/empty --dry-run)
    assert_exit 0 $? "nor does a repo with no manifest at all" || rc=1
    assert_contains "$out" "nothing missing" || rc=1
    _inst_teardown
    return $rc
}

test_install_requirements_defaults_to_a_dry_run_without_a_tty() {
    # The guard that stops a routine ever triggering an install. Every call in
    # this file has stdin closed, so no flag is passed here on purpose.
    _inst_setup
    local rc=0 out
    _inst_manifest <<'EOF'
cmd definitely-not-on-this-host  # install: touch ran-anyway
EOF

    out=$(_inst_run acme/fixture)
    assert_exit 1 $? "something is still missing" || rc=1
    assert_contains "$out" "stdin is not a TTY" "it says why it did not install" || rc=1
    assert_contains "$out" "mode=dry-run" || rc=1
    assert_contains "$out" "would run: touch ran-anyway" || rc=1
    # The install command is a side effect on the filesystem rather than a
    # string in the output, so "it did not run" is a fact this can check
    # directly. Matching on the absence of the command's own stdout would mean
    # a needle carrying a literal newline to tell it apart from the plan line
    # that quotes the same text — brittle, and testing the log rather than the
    # behaviour.
    if [[ -e "$INST_ROOT/ran-anyway" ]]; then
        echo "  ASSERT FAIL: the install command ran under a dry run"
        rc=1
    fi
    _inst_teardown
    return $rc
}

test_install_requirements_demotes_root_xcode_and_licence_commands_to_manual() {
    _inst_setup
    local rc=0 out
    _inst_manifest <<'EOF'
cmd tool-needing-root      # hint: root only # install: sudo make me a sandwich
cmd tool-needing-xcode     # hint: full Xcode # install: xcode-select --install
cmd tool-needing-licence   # hint: sign in # install: unity licence activate
cmd tool-with-no-installer # hint: do it by hand
EOF

    out=$(_inst_run acme/fixture --dry-run)
    assert_exit 1 $? || rc=1
    assert_contains "$out" "manual: tool-needing-root — needs root" \
        "a manifest must not be able to hand this script a root shell" || rc=1
    assert_contains "$out" "manual: tool-needing-xcode" || rc=1
    assert_contains "$out" "manual: tool-needing-licence" || rc=1
    assert_contains "$out" "manual: tool-with-no-installer — no install command" || rc=1
    assert_contains "$out" "hint: do it by hand" "each manual step carries its hint" || rc=1
    assert_not_contains "$out" "would run:" "none of these is ever offered as automatic" || rc=1
    assert_contains "$out" "manual=4" || rc=1
    _inst_teardown
    return $rc
}

test_install_requirements_rejects_a_repo_it_cannot_resolve() {
    _inst_setup
    local rc=0
    _inst_run acme/not-in-the-map --dry-run > /dev/null
    assert_exit 2 $? "an unresolvable repo is a usage error, not an empty plan" || rc=1
    _inst_run --dry-run > /dev/null
    assert_exit 2 $? "and so is naming no repo at all" || rc=1
    _inst_teardown
    return $rc
}
