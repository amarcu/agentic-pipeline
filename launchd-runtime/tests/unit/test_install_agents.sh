#!/bin/bash
# Tests for how install.sh installs the LaunchAgents.
#
# The tracked plists are templates under one label. A host that was installed
# under an earlier label still has those agents loaded, and loading the new
# ones beside them fires every routine twice on the same repos (Cursor review,
# PR #98 f2). install.sh has to retire the old agent for a routine before it
# loads the new one, and it must not touch an agent for anything else.

test_install_retires_an_agent_installed_under_an_earlier_label() {
    local tmp out rc=0
    tmp=$(/usr/bin/mktemp -d /tmp/agentic-test-install-agents.XXXXXX)
    /bin/mkdir -p "$tmp/LaunchAgents"
    : > "$tmp/LaunchAgents/com.example.routines.morning-triage.plist"
    : > "$tmp/LaunchAgents/com.example.unrelated-tool.plist"
    out=$(AGENTIC_SKILLS_HOME="$tmp/state" LAUNCH_AGENTS_DIR="$tmp/LaunchAgents" \
          /bin/bash "$RUNTIME_DIR/bin/install.sh" --dry-run 2>&1)
    assert_exit 0 $? "the dry run succeeds" || rc=1
    assert_contains "$out" "bootout 'gui/$(/usr/bin/id -u)/com.example.routines.morning-triage'" \
        "the agent under the earlier label is booted out" || rc=1
    assert_contains "$out" "/bin/mv -f '$tmp/LaunchAgents/com.example.routines.morning-triage.plist' '$tmp/state/routines/retired-agents/'" \
        "and its plist is set aside, not deleted" || rc=1
    assert_contains "$out" "bootstrap 'gui/$(/usr/bin/id -u)' '$tmp/LaunchAgents/com.agentic-skills.routines.morning-triage.plist'" \
        "the new agent is loaded" || rc=1
    assert_not_contains "$out" "unrelated-tool" "an agent for anything else is left alone" || rc=1
    assert_file_exists "$tmp/LaunchAgents/com.example.routines.morning-triage.plist" "a dry run changes nothing" || rc=1
    /bin/rm -rf "$tmp"
    return $rc
}

test_make_doctor_takes_the_owner_from_the_roster() {
    # `make doctor-<name>` used to assume one owner, which no longer matched the
    # roster (Cursor review, PR #98 f3). The roster is where a full name lives.
    local out rc=0
    out=$(REPOS_CONF="$RUNTIME_DIR/repos.conf.example" /usr/bin/make -n -C "$REPO_ROOT" doctor-StarBonk 2>&1)
    assert_contains "$out" "check-requirements" "the recipe runs check-requirements" || rc=1
    out=$(REPOS_CONF="$RUNTIME_DIR/repos.conf.example" /bin/bash -c '. "$1" && for r in "${REPOS_BY_PRIORITY[@]}"; do [ "${r##*/}" = "$2" ] && echo "$r"; done' _ "$RUNTIME_DIR/repos.conf.example" StarBonk | /usr/bin/head -1)
    assert_equal "amarcu/StarBonk" "$out" "the roster gives StarBonk its real owner" || rc=1
    out=$(REPOS_CONF="$RUNTIME_DIR/repos.conf.example" /usr/bin/make -C "$REPO_ROOT" doctor-no-such-repo 2>&1)
    assert_contains "$out" "no repo named 'no-such-repo' in the roster" "an unknown name is refused by name" || rc=1
    return $rc
}
