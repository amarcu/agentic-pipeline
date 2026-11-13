#!/bin/bash
# permissions/bin/protected-paths-hook is a PreToolUse hook on Bash that refuses
# commands which would destroy protected paths. It exists because static rules
# match the command STRING: `Bash(rm -rf /abs/trash)` can be denied while
# `cd /abs && rm -rf trash` matches nothing. These tests drive the real hook
# with crafted payloads against a fixture root list.
#
# Would have caught: removing a git worktree that reports clean under
# `git status --untracked-files=all` while holding a live server/.env.

HOOK="$REPO_ROOT/permissions/bin/protected-paths-hook"

# Runs the hook. Sets HOOK_RC and HOOK_MSG. $1 = cwd, $2 = command.
_run_hook() {
    HOOK_MSG=$(printf '{"cwd":%s,"tool_input":{"command":%s}}' \
        "$(/usr/bin/python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
        "$(/usr/bin/python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")" \
        | PROTECTED_ROOTS_CONF="$HOOK_CONF" "$HOOK" 2>&1 >/dev/null)
    HOOK_RC=$?
}

_assert_hook() {  # $1 = DENY|ALLOW, $2 = cwd, $3 = command, $4 = label
    _run_hook "$2" "$3"
    local got="ALLOW"
    [[ "$HOOK_RC" -eq 2 ]] && got="DENY"
    if [[ "$got" != "$1" ]]; then
        echo "  FAIL: $4 — got $got, wanted $1"
        echo "        command: $3   (cwd $2)"
        return 1
    fi
    return 0
}

_setup_hook_env() {
    HOOK_TMP=$(/usr/bin/mktemp -d /tmp/agentic-hook.XXXXXX)
    /bin/mkdir -p "$HOOK_TMP/vault/logs" "$HOOK_TMP/open/sub"
    /usr/bin/touch "$HOOK_TMP/vault/logs/run.log" "$HOOK_TMP/open/sub/junk.txt"
    HOOK_CONF="$HOOK_TMP/roots.conf"
    /bin/cat > "$HOOK_CONF" <<EOF
# fixture
$HOOK_TMP/vault
*.env
*.db
EOF
}

test_hook_denies_a_relative_delete_after_cd() {
    _setup_hook_env
    local rc=0
    # The case static rules structurally cannot see: the protected path is
    # never named in the command.
    _assert_hook DENY "$HOOK_TMP/vault/logs" "rm -rf run.log" "relative rm inside a protected root" || rc=1
    _assert_hook DENY "$HOOK_TMP" "cd vault && rm -rf logs" "cd then rm in one command" || rc=1
    return $rc
}

test_hook_denies_deleting_a_parent_of_a_protected_root() {
    _setup_hook_env
    # Removing the parent destroys the protected path just as completely.
    _assert_hook DENY "/tmp" "rm -rf $HOOK_TMP" "rm of a parent directory"
}

test_hook_denies_truncating_redirect_onto_a_protected_file() {
    _setup_hook_env
    local rc=0
    _assert_hook DENY  "/tmp" "echo x > $HOOK_TMP/vault/logs/run.log" "truncating redirect" || rc=1
    # Appending is not destructive and must stay allowed.
    _assert_hook ALLOW "/tmp" "echo x >> $HOOK_TMP/vault/logs/run.log" "append redirect" || rc=1
    return $rc
}

test_hook_denies_removing_a_worktree_that_holds_ignored_secrets() {
    _setup_hook_env
    /bin/mkdir -p "$HOOK_TMP/wt/server"
    /usr/bin/touch "$HOOK_TMP/wt/server/.env"
    local rc=0
    _assert_hook DENY "/tmp" "git worktree remove $HOOK_TMP/wt" "worktree holding a .env" || rc=1
    if [[ "$HOOK_MSG" != *".env"* ]]; then
        echo "  FAIL: refusal did not name the file at risk"
        rc=1
    fi
    # A worktree with nothing irreplaceable in it must still be removable.
    /bin/mkdir -p "$HOOK_TMP/wt2/src"
    /usr/bin/touch "$HOOK_TMP/wt2/src/main.js"
    _assert_hook ALLOW "/tmp" "git worktree remove $HOOK_TMP/wt2" "worktree with nothing at risk" || rc=1
    return $rc
}

test_hook_denies_by_filename_pattern_anywhere() {
    _setup_hook_env
    local rc=0
    _assert_hook DENY "$HOOK_TMP/open" "rm sub/../server.env" "an .env by any path" || rc=1
    _assert_hook DENY "/tmp" "rm $HOOK_TMP/open/emails.db" "a .db by any path" || rc=1
    return $rc
}

test_hook_allows_ordinary_work() {
    _setup_hook_env
    local rc=0
    # A hook that blocks routine commands gets disabled, so this matters as
    # much as the denials.
    _assert_hook ALLOW "/tmp" "ls -la"                              "plain ls" || rc=1
    _assert_hook ALLOW "/tmp" "git status --porcelain"              "git status" || rc=1
    _assert_hook ALLOW "/tmp" "npm run build 2>/dev/null"           "redirect to /dev/null" || rc=1
    _assert_hook ALLOW "/tmp" "rm -rf $HOOK_TMP/open/sub"           "delete outside every root" || rc=1
    _assert_hook ALLOW "/tmp" "rm -rf /tmp/x/node_modules"          "delete a regenerable tree" || rc=1
    return $rc
}

test_hook_fails_closed_on_a_missing_root_list_but_only_for_deletes() {
    _setup_hook_env
    local rc=0
    HOOK_CONF="$HOOK_TMP/does-not-exist.conf"
    # No protection list means no protection, so a delete must not proceed...
    _assert_hook DENY  "/tmp" "rm -rf $HOOK_TMP/open" "delete with no root list" || rc=1
    # ...but a bug here must never brick every Bash call in the session.
    _assert_hook ALLOW "/tmp" "ls -la" "harmless command with no root list" || rc=1
    return $rc
}

test_hook_ignores_input_it_cannot_parse() {
    _setup_hook_env
    printf 'not json at all' | PROTECTED_ROOTS_CONF="$HOOK_CONF" "$HOOK" >/dev/null 2>&1
    local rc_bad=$?
    if [[ "$rc_bad" -ne 0 ]]; then
        echo "  FAIL: malformed hook input should be ignored, got exit $rc_bad"
        return 1
    fi
    return 0
}

_assert_reason() {  # $1 = text the refusal must contain, $2 = label
    if [[ "$HOOK_MSG" != *"$1"* ]]; then
        echo "  FAIL: $2 — the refusal does not say \"$1\""
        echo "        got: ${HOOK_MSG:0:200}"
        return 1
    fi
    return 0
}

test_hook_allows_prose_with_an_apostrophe_in_a_heredoc_body() {
    # Issue #58. shlex read a heredoc body as shell words, so an apostrophe was an
    # unclosed quote; "confirmed" or "normal" holds `rm`, so the command looked
    # destructive and was refused as unanalysable. A routine's Telegram digest was
    # denied three times on 2026-09-12 until the model rewrote its message.
    _setup_hook_env
    local rc=0
    _assert_hook ALLOW "/tmp" $'cat <<EOF > /dev/null\nStarBonk\'s queue is full, confirmed\nEOF' \
        "a bare delimiter" || rc=1
    _assert_hook ALLOW "/tmp" $'cat <<\'EOF\'\nthe halt reason that doesn\'t self-resolve, confirmed\nEOF' \
        "a single-quoted delimiter" || rc=1
    _assert_hook ALLOW "/tmp" $'cat <<"EOF"\nit\'s confirmed\nEOF' "a double-quoted delimiter" || rc=1
    _assert_hook ALLOW "/tmp" $'cat <<-EOF\n\tit\'s indented, confirmed\n\tEOF' "a <<- heredoc" || rc=1
    _assert_hook ALLOW "/tmp" $'git commit -F - <<\'EOF\'\nDon\'t warn on a normal finish\nEOF' \
        "a commit message fed to git" || rc=1
    _assert_hook ALLOW "/tmp" $'cat > /tmp/notify-message.txt << \'EOF\'\n> it\'s confirmed -> done\nEOF' \
        "the notify skill's message file, with a blockquote" || rc=1
    _assert_hook ALLOW "/tmp" $'gh pr create --draft --body "$(cat <<\'EOF\'\nIt says "never printed and doesn\'t, confirmed\nEOF\n)"' \
        "a pull request body inside \$(...), with an odd double quote too" || rc=1
    return $rc
}

test_hook_still_checks_a_delete_beside_a_heredoc() {
    _setup_hook_env
    local rc=0
    _assert_hook DENY "/tmp" $'cat <<\'EOF\' > notes\ndon\'t\nEOF\nrm -rf '"$HOOK_TMP/vault" \
        "a delete after the heredoc" || rc=1
    _assert_reason "protected by" "it is refused as a protected path, not as unparseable" || rc=1
    _assert_hook DENY "/tmp" "rm -rf $HOOK_TMP/vault && git commit -F - <<'EOF'"$'\nDon\'t\nEOF' \
        "a delete before the heredoc" || rc=1
    _assert_reason "protected by" "refused as a protected path" || rc=1
    _assert_hook DENY "/tmp" "cd $HOOK_TMP/vault && cat <<'EOF' > /dev/null"$'\nit\'s\nEOF\nrm -rf logs' \
        "a relative delete after a cd and a heredoc" || rc=1
    _assert_reason "protected by" "the cd before the heredoc still counts" || rc=1
    _assert_hook DENY "/tmp" "cat > $HOOK_TMP/vault/logs/run.log <<'EOF'"$'\nit\'s\nEOF' \
        "a heredoc that truncates a protected file" || rc=1
    _assert_reason "protected by" "refused as a protected path" || rc=1
    return $rc
}

test_hook_checks_a_heredoc_body_fed_to_a_shell() {
    # A body run by a shell holds real commands, so it is checked, not skipped.
    _setup_hook_env
    local rc=0
    _assert_hook DENY "/tmp" $'bash <<\'EOF\'\necho it\'s done\nrm -rf '"$HOOK_TMP/vault"$'\nEOF' \
        "a delete in a body fed to bash" || rc=1
    _assert_reason "protected by" "refused as a protected path" || rc=1
    _assert_hook DENY "/tmp" $'cat <<\'EOF\' | bash\nrm -rf '"$HOOK_TMP/vault"$'\necho don\'t\nEOF' \
        "a delete in a body piped to bash" || rc=1
    _assert_hook DENY "/tmp" "cd $HOOK_TMP && bash <<'EOF'"$'\ncd vault\nrm -rf logs\necho it\'s\nEOF' \
        "a relative delete after a cd inside the body" || rc=1
    _assert_reason "protected by" "the body's own cd carries to its next line" || rc=1
    _assert_hook DENY "/tmp" $'bash <<\'EOF\'\nrm -rf '"$HOOK_TMP/vault"$'; echo it\'s gone\nEOF' \
        "a delete before an unclosed quote on a body line" || rc=1
    _assert_reason "protected by" "the words before the quote are checked" || rc=1
    return $rc
}

test_hook_still_denies_an_unparseable_command_that_may_delete() {
    _setup_hook_env
    local rc=0
    _assert_hook DENY "/tmp" "rm -rf $HOOK_TMP/open/sub 'oops" "an unclosed quote on a delete" || rc=1
    _assert_reason "could not analyse" "refused under the failure policy" || rc=1
    _assert_hook DENY "/tmp" "rm -rf $HOOK_TMP/open/sub 'oops"$'\ncat <<EOF\nbody\nEOF' \
        "the same, with a heredoc beside it" || rc=1
    _assert_reason "could not analyse" "the code outside the body is judged as before" || rc=1
    # Unparseable code must not hide the delete in a body beside it (Grok, PR #60 f2).
    _assert_hook DENY "/tmp" $'echo "oops\nbash <<\'EOF\'\nrm -rf '"$HOOK_TMP/vault"$'\nEOF' \
        "an unclosed quote, then a bash heredoc that deletes" || rc=1
    # bash accepts $'it\'s' and shlex does not, so this one really runs the delete.
    _assert_hook DENY "/tmp" $'echo $\'it\\\'s\'\nbash <<\'EOF\'\nrm -rf '"$HOOK_TMP/vault"$'\nEOF' \
        "ANSI-C quoting shlex cannot read, then a bash heredoc that deletes" || rc=1
    return $rc
}

test_hook_checks_a_command_on_a_later_line() {
    # shlex read a line break as whitespace, so a second line joined the first
    # line's command and its delete was never looked at.
    _setup_hook_env
    local rc=0
    _assert_hook DENY "/tmp" $'echo hi\nrm -rf '"$HOOK_TMP/vault" "a delete on the second line" || rc=1
    _assert_hook DENY "/tmp" "cd $HOOK_TMP/vault"$'\nrm -rf logs' "a cd, then a relative delete below it" || rc=1
    _assert_hook DENY "/tmp" $'echo a # it\'s a comment\nrm -rf '"$HOOK_TMP/vault" \
        "a delete after a comment line" || rc=1
    _assert_hook DENY "/tmp" $'rm -rf \\\n  '"$HOOK_TMP/vault" "a delete continued onto the next line" || rc=1
    _assert_hook DENY "/tmp" "sleep 1 & rm -rf $HOOK_TMP/vault" "a delete after a background job" || rc=1
    return $rc
}

test_hook_allows_a_message_that_quotes_a_delete() {
    # A body that only becomes a message is not commands (Grok, PR #60 f1).
    _setup_hook_env
    local rc=0
    _assert_hook ALLOW "/tmp" $'cat <<EOF\nrm -rf '"$HOOK_TMP/vault"$'\nEOF' "a cat heredoc" || rc=1
    _assert_hook ALLOW "/tmp" $'cat > /tmp/notes.md <<\'EOF\'\nThen run: mv a.txt '"$HOOK_TMP/vault"$'\nEOF' \
        "a cat heredoc written to a file" || rc=1
    _assert_hook ALLOW "/tmp" $'git commit -F - <<\'EOF\'\nStop running rm -rf '"$HOOK_TMP/vault"$'\nrm -rf '"$HOOK_TMP/vault"$'\nEOF' \
        "a commit message" || rc=1
    _assert_hook ALLOW "/tmp" $'gh pr create --draft --title "Fix the hook" --body "$(cat <<\'EOF\'\nrm -rf '"$HOOK_TMP/vault"$' is refused now\nEOF\n)"' \
        "a pull request body passed as \$(cat ...)" || rc=1
    return $rc
}

test_hook_checks_a_body_that_only_looks_like_a_message() {
    _setup_hook_env
    local rc=0
    _assert_hook DENY "/tmp" $'cat <<\'EOF\'\nhi\nEOF\nrm -rf '"$HOOK_TMP/vault"$'\nEOF' \
        "a delete after the delimiter line, where bash ends the heredoc" || rc=1
    _assert_hook DENY "/tmp" $'cat <<\'EOF\' > run.sh && bash run.sh\nrm -rf '"$HOOK_TMP/vault"$'\nEOF' \
        "a cat heredoc with a second command after it" || rc=1
    _assert_hook DENY "/tmp" $'cat > run.sh <<\'EOF\'\nrm -rf '"$HOOK_TMP/vault"$'\nEOF\nbash run.sh' \
        "a script written by a heredoc and run on the next line" || rc=1
    _assert_hook DENY "/tmp" $'gh pr create --body "$(cat <<\'EOF\'\nhello\nEOF\n)" | bash\nrm -rf '"$HOOK_TMP/vault" \
        "a message command piped on, with a delete after it" || rc=1
    _assert_hook DENY "/tmp" "cat > $HOOK_TMP/vault/logs/run.log <<'EOF'"$'\nrm is fine here\nEOF' \
        "a message written onto a protected file" || rc=1
    _assert_reason "protected by" "the redirect is still checked" || rc=1
    return $rc
}

test_hook_protects_the_paths_a_machine_lists_locally() {
    # The tracked list names defaults under the home directory. A machine
    # whose state lives elsewhere lists its real paths in a git-ignored
    # roots.local.conf beside it; the hook reads both, and the local file can
    # only add protection.
    _setup_hook_env
    local rc=0
    /bin/mkdir -p "$HOOK_TMP/elsewhere/metrics"
    _assert_hook ALLOW "$HOOK_TMP" "rm -rf elsewhere/metrics" "with no local file the path is not protected" || rc=1
    echo "$HOOK_TMP/elsewhere/metrics" > "$HOOK_TMP/roots.local.conf"
    _assert_hook DENY "$HOOK_TMP" "rm -rf elsewhere/metrics" "a path the local file lists is protected" || rc=1
    _assert_hook DENY "$HOOK_TMP" "rm -rf vault/logs" "and the tracked list still applies" || rc=1
    /bin/rm -rf "$HOOK_TMP"
    return $rc
}
