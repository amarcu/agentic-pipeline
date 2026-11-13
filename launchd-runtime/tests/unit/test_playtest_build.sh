#!/bin/bash
# Tests for launchd-runtime/bin/playtest-build — the owner's build every couple of days. What
# these pin: an unchanged main is never rebuilt; a release carries both targets, is pinned to the
# built commit and lists the commits since the last build; a failed build or smoke test publishes
# nothing and does not advance the state; and no worktree is left behind. gh, Telegram and the
# repo's Tools/build.sh are fakes driven by $PB_TMP.

_pb_setup() {
    PB_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-playtest.XXXXXX)
    /bin/mkdir -p "$PB_TMP/fake" "$PB_TMP/state"
    : > "$PB_TMP/calls.log"

    /usr/bin/git init -q --bare "$PB_TMP/origin.git"
    /usr/bin/git init -q -b main "$PB_TMP/checkout"
    /usr/bin/git -C "$PB_TMP/checkout" config user.email t@example.com
    /usr/bin/git -C "$PB_TMP/checkout" config user.name t
    /bin/mkdir -p "$PB_TMP/checkout/Tools"
    # The repo's build script: a Mac app whose binary keeps running (or exits at once when
    # PB_APP_EXITS is set), a Windows folder with Unity's _DoNotShip debug folder, or a failure.
    /bin/cat > "$PB_TMP/checkout/Tools/build.sh" <<'SH'
#!/bin/bash
echo "build $1" >> "$PB_TMP/calls.log"
[ "$1" = "${PB_FAIL_TARGET:-}" ] && { echo "BUILD: target=$1 exit=1 seconds=1 path=x log=x"; exit 1; }
mkdir -p "$2"
if [ "$1" = mac ]; then
    mkdir -p "$2/Game.app/Contents/MacOS" "$2/Game_BurstDebugInformation_DoNotShip"; echo dbg > "$2/Game_BurstDebugInformation_DoNotShip/x"
    if [ -n "${PB_APP_EXITS:-}" ]; then printf '#!/bin/bash\nexit 0\n' > "$2/Game.app/Contents/MacOS/Game"
    else printf '#!/bin/bash\nexec sleep 30\n' > "$2/Game.app/Contents/MacOS/Game"; fi
    chmod +x "$2/Game.app/Contents/MacOS/Game"
    xattr -w com.example.test 1 "$2/Game.app/Contents/MacOS/Game"
else
    echo exe > "$2/Game.exe"; mkdir -p "$2/Game_BurstDebugInformation_DoNotShip"; echo dbg > "$2/Game_BurstDebugInformation_DoNotShip/x"
fi
echo "BUILD: target=$1 exit=0 seconds=1 path=$2 log=x"
SH
    /bin/chmod +x "$PB_TMP/checkout/Tools/build.sh"
    /usr/bin/git -C "$PB_TMP/checkout" add Tools/build.sh
    /usr/bin/git -C "$PB_TMP/checkout" -c commit.gpgsign=false commit -qm "Add the build script"
    /usr/bin/git -C "$PB_TMP/checkout" remote add origin "$PB_TMP/origin.git"
    /usr/bin/git -C "$PB_TMP/checkout" push -q origin main

    export REPOS_CONF="$PB_TMP/repos.conf"
    /bin/cat > "$REPOS_CONF" <<EOF
get_repo_path() { case "\$1" in acme/game) echo "$PB_TMP/checkout" ;; *) echo "" ;; esac; }
PLAYTEST_BUILD_REPOS=( "acme/game" )
EOF
    /bin/cat > "$PB_TMP/fake/gh" <<'SH'
#!/bin/bash
echo "gh $*" >> "$PB_TMP/calls.log"
for a in "$@"; do case "$a" in *.zip) /usr/bin/unzip -Z1 "$a" | sed "s#^#zip $(basename "$a"): #" >> "$PB_TMP/calls.log" ;; *notes.md) cp "$a" "$PB_TMP/notes.md" ;; esac; done
echo "https://github.com/acme/game/releases/tag/$3"
SH
    /bin/cat > "$PB_TMP/fake/telegram-send" <<'SH'
#!/bin/bash
echo "telegram $(cat "$1")" >> "$PB_TMP/calls.log"
SH
    /bin/chmod +x "$PB_TMP/fake/"*
    export PB_TMP GH_BIN="$PB_TMP/fake/gh" TELEGRAM_SEND_BIN="$PB_TMP/fake/telegram-send"
    export PLAYTEST_BUILD_STATE_DIR="$PB_TMP/state" PLAYTEST_SMOKE_SECONDS=1
}

_pb_teardown() {
    /bin/rm -rf "$PB_TMP"
    unset PB_TMP GH_BIN TELEGRAM_SEND_BIN PLAYTEST_BUILD_STATE_DIR PLAYTEST_SMOKE_SECONDS REPOS_CONF \
        PB_FAIL_TARGET PB_APP_EXITS
}

_pb_commit() {
    echo "$1" > "$PB_TMP/checkout/$1.txt"
    /usr/bin/git -C "$PB_TMP/checkout" add "$1.txt"
    /usr/bin/git -C "$PB_TMP/checkout" -c commit.gpgsign=false commit -qm "$1"
    /usr/bin/git -C "$PB_TMP/checkout" push -q origin main
}

_pb_run() { "$RUNTIME_DIR/bin/playtest-build" acme/game 2>&1; }

test_playtest_build_releases_both_targets_pinned_to_main() {
    _pb_setup
    local rc=0 out sha calls
    sha=$(/usr/bin/git -C "$PB_TMP/checkout" rev-parse HEAD)
    out=$(_pb_run)
    calls=$(/bin/cat "$PB_TMP/calls.log")
    assert_contains "$out" "result=released targets=mac,windows" "a new main is released" || rc=1
    assert_contains "$calls" "--target $sha --prerelease" "pinned to the built commit, as a pre-release" || rc=1
    assert_contains "$calls" "game-$(/bin/date +%Y-%m-%d)-${sha:0:7}-mac.zip" "with the Mac zip" || rc=1
    assert_contains "$calls" "game-$(/bin/date +%Y-%m-%d)-${sha:0:7}-windows.zip" "and the Windows zip" || rc=1
    assert_contains "$calls" "zip game-$(/bin/date +%Y-%m-%d)-${sha:0:7}-mac.zip: Game.app/" "the app is at the zip's top" || rc=1
    assert_contains "$calls" "telegram 🎮 New game playtest build" "the owner gets the link" || rc=1
    assert_contains "$calls" "releases/tag/playtest-" "with the release URL" || rc=1
    assert_equal "$sha" "$(/bin/cat "$PB_TMP/state/acme-game.last")" "the state records the built commit" || rc=1
    _pb_teardown
    return $rc
}

test_playtest_build_leaves_unitys_do_not_ship_folders_out() {
    _pb_setup
    local rc=0
    _pb_run > /dev/null
    if /usr/bin/grep -q "windows.zip: .*DoNotShip" "$PB_TMP/calls.log"; then
        echo "  FAIL: the Windows zip carries the _DoNotShip folder"
        rc=1
    fi
    if /usr/bin/grep -q "mac.zip: .*DoNotShip" "$PB_TMP/calls.log"; then
        echo "  FAIL: the Mac zip carries the _DoNotShip folder"
        rc=1
    fi
    assert_contains "$(/bin/cat "$PB_TMP/calls.log")" "windows.zip: Game.exe" "the game itself is there" || rc=1
    _pb_teardown
    return $rc
}

test_playtest_build_mac_zip_has_no_appledouble_files() {
    _pb_setup
    local rc=0
    _pb_run > /dev/null
    assert_contains "$(/bin/cat "$PB_TMP/calls.log")" "mac.zip: Game.app/Contents/MacOS/Game" "the binary is there" || rc=1
    if /usr/bin/grep -q "mac.zip: .*/\._" "$PB_TMP/calls.log"; then
        echo "  FAIL: the Mac zip carries ._ files, which unzip writes into the bundle and break its seal"
        rc=1
    fi
    _pb_teardown
    return $rc
}

test_playtest_build_skips_an_unchanged_main() {
    _pb_setup
    local rc=0 out
    _pb_run > /dev/null
    : > "$PB_TMP/calls.log"
    out=$(_pb_run)
    assert_contains "$out" "result=skipped reason=unchanged" "the same commit is not rebuilt" || rc=1
    if [[ -s "$PB_TMP/calls.log" ]]; then
        echo "  FAIL: an unchanged main built or published something"; rc=1
    fi
    _pb_teardown
    return $rc
}

test_playtest_build_notes_list_the_commits_since_the_last_build() {
    _pb_setup
    local rc=0 notes
    _pb_run > /dev/null
    _pb_commit "Steer the ship with a rudder"
    _pb_commit "Fix the pause menu"
    _pb_run > /dev/null
    notes=$(/bin/cat "$PB_TMP/notes.md")
    assert_contains "$notes" "- Fix the pause menu" "the newest commit is listed" || rc=1
    assert_contains "$notes" "- Steer the ship with a rudder" "and the one before it" || rc=1
    if [[ "$notes" == *"Add the build script"* ]]; then
        echo "  FAIL: the notes repeat a commit the last build already carried"; rc=1
    fi
    assert_contains "$(/bin/cat "$PB_TMP/calls.log")" "2 change(s)" "the message counts them" || rc=1
    _pb_teardown
    return $rc
}

test_playtest_build_publishes_nothing_when_a_build_fails() {
    _pb_setup
    local rc=0 out
    out=$(PB_FAIL_TARGET=windows _pb_run)
    assert_contains "$out" "result=failed reason=the windows build failed" "a failed build is reported" || rc=1
    if /usr/bin/grep -q "gh release" "$PB_TMP/calls.log"; then
        echo "  FAIL: a failed build was published"; rc=1
    fi
    assert_contains "$(/bin/cat "$PB_TMP/calls.log")" "telegram 🛠 game playtest build failed" "the owner is told" || rc=1
    if [[ -e "$PB_TMP/state/acme-game.last" ]]; then
        echo "  FAIL: a failed build advanced the state, so the next run would skip it"; rc=1
    fi
    _pb_teardown
    return $rc
}

test_playtest_build_fails_a_mac_build_that_does_not_stay_up() {
    _pb_setup
    local rc=0 out
    out=$(PB_APP_EXITS=1 _pb_run)
    assert_contains "$out" "result=failed reason=the mac build exited within 1s of starting" "the smoke test catches it" || rc=1
    if /usr/bin/grep -q "gh release" "$PB_TMP/calls.log"; then
        echo "  FAIL: a build that fails the smoke test was published"; rc=1
    fi
    _pb_teardown
    return $rc
}

test_playtest_build_honours_the_kill_switch() {
    _pb_setup
    local rc=0 out
    : > "$PB_TMP/state/OFF"
    out=$(_pb_run)
    assert_contains "$out" "result=skipped reason=kill-switch" "OFF stops it" || rc=1
    assert_equal "" "$(/bin/cat "$PB_TMP/calls.log")" "and nothing runs" || rc=1
    _pb_teardown
    return $rc
}

test_playtest_build_leaves_no_worktree_behind() {
    _pb_setup
    local rc=0
    _pb_run > /dev/null
    PB_FAIL_TARGET=mac _pb_commit "another" && PB_FAIL_TARGET=mac _pb_run > /dev/null
    assert_equal "1" "$(/usr/bin/git -C "$PB_TMP/checkout" worktree list | /usr/bin/wc -l | /usr/bin/tr -d ' ')" \
        "only the checkout itself, after a release and after a failure" || rc=1
    _pb_teardown
    return $rc
}

test_playtest_build_night_summarises_and_exits_10() {
    _pb_setup
    local rc=0 out code
    out=$("$RUNTIME_DIR/bin/playtest-build-night" 2>&1); code=$?
    assert_equal "10" "$code" "a normal run tells the runner not to start the model" || rc=1
    assert_contains "$(echo "$out" | /usr/bin/head -1)" "PLAYTEST-BUILD-RUN: released=1 skipped=0 failed=0 errors=0 status=0" \
        "the first line is the run summary" || rc=1
    _pb_teardown
    return $rc
}
