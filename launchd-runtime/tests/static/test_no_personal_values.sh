#!/bin/bash
# No published file carries one person's machine, network, secrets or projects.
#
# This repository is published as a snapshot built by `git archive`, so what
# counts is every tracked file that .gitattributes does not mark
# `export-ignore`. The checks are shapes, not names: a home path, a MAC
# address, a tailnet name, a private address, a launchd label under someone's
# own prefix, an e-mail address, a key. The examples and fixtures use a small
# allowed set (/Users/dev, 02:00:00:AA:BB:CC, example.com) so they pass.
#
# Names cannot be checked by shape, and a list of private names cannot live in
# a published file. Each machine may keep its own in
# launchd-runtime/tests/private-names.local (git-ignored, one fixed string per
# line); when the file exists, none of its lines may appear either.

_PV_SCAN="$RUNTIME_DIR/tests/static/scan-personal-values.py"

test_no_published_file_carries_a_personal_value() {
    local out rc
    out=$(/usr/bin/python3 "$_PV_SCAN" "$REPO_ROOT" "$RUNTIME_DIR/tests/private-names.local")
    rc=$?
    [[ -z "$out" ]] || echo "$out" | /usr/bin/head -40
    return $rc
}

test_the_personal_value_scan_catches_each_kind_it_claims_to() {
    # A guard that passes proves nothing until it has been seen to fail. One
    # planted value per check, in a tree with no .git, and the allowed
    # stand-ins beside them: every plant is reported and no stand-in is.
    local tmp out rc=0 kind
    tmp=$(/usr/bin/mktemp -d /tmp/agentic-test-pvscan.XXXXXX)
    /bin/mkdir -p "$tmp/tree/sub"
    /bin/cat > "$tmp/tree/sub/planted.txt" <<'PLANT'
path /Users/alice/code/thing and /home/bob/x
mac 3C:22:FB:12:34:56
host box.tail1a2b3c.ts.net at 100.101.102.103 and 192.168.1.42
label com.alice.routines.morning-triage
mail alice@corp.io
bot 1234567890:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
key ghp_0123456789abcdefghijklmnopqrstuv
project Hidden-Thing
PLANT
    /bin/cat > "$tmp/tree/allowed.txt" <<'OK'
path /Users/dev/code/thing, mac 02:00:00:AA:BB:CC, broadcast 192.168.1.255
label com.agentic-skills.routines.morning-triage, mail t@example.com and git@github.com
OK
    echo "hidden-thing" > "$tmp/names"
    out=$(/usr/bin/python3 "$_PV_SCAN" "$tmp/tree" "$tmp/names")
    assert_exit 1 $? "a tree with planted values fails" || rc=1
    for kind in "home path: /Users/alice" "home path: /home/bob" "MAC address" "tailnet name" "tailnet address" \
                "LAN address" "launchd label" "e-mail address: alice@corp.io" "Telegram token" "API key" \
                "a name from private-names.local"; do
        assert_contains "$out" "$kind" "the scan reports: $kind" || rc=1
    done
    assert_not_contains "$out" "allowed.txt" "and none of the allowed stand-ins" || rc=1
    /bin/rm -rf "$tmp"
    return $rc
}
