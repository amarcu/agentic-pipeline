#!/bin/bash
# Tests for launchd-runtime/bin/build-smoke — the merge lane's "does the game still start?" check
# for scene and prefab changes. The repo's Tools/build.sh is a fake that makes a Mac app whose
# binary behaves as each test needs, driven by $BS_MODE.

_bs_setup() {
    BS_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-buildsmoke.XXXXXX)
    /usr/bin/git init -q -b main "$BS_TMP/checkout"
    /usr/bin/git -C "$BS_TMP/checkout" config user.email t@example.com
    /usr/bin/git -C "$BS_TMP/checkout" config user.name t
    /bin/mkdir -p "$BS_TMP/checkout/Tools"
    /bin/cat > "$BS_TMP/checkout/Tools/build.sh" <<'SH'
#!/bin/bash
[ "${BS_MODE:-}" = build-fails ] && { echo "BUILD: target=$1 exit=1 seconds=1 path=x log=x"; exit 1; }
mkdir -p "$2/Game.app/Contents/MacOS"
cat > "$2/Game.app/Contents/MacOS/Game" <<'APP'
#!/bin/bash
while [ $# -gt 0 ]; do [ "$1" = -logFile ] && LOG="$2"; shift; done
[ "${BS_MODE:-}" = missing-script ] && echo "The referenced script on this Behaviour (Game Object 'PickupPool') is missing!" > "$LOG"
[ "${BS_MODE:-}" = exits ] && exit 1
[ "${BS_MODE:-}" = no-log ] || echo "player started" >> "$LOG"
exec sleep 30
APP
chmod +x "$2/Game.app/Contents/MacOS/Game"
echo "BUILD: target=$1 exit=0 seconds=1 path=$2 log=x"
SH
    /bin/chmod +x "$BS_TMP/checkout/Tools/build.sh"
    /usr/bin/git -C "$BS_TMP/checkout" add Tools/build.sh
    /usr/bin/git -C "$BS_TMP/checkout" -c commit.gpgsign=false commit -qm "build script"
    export BS_TMP BUILD_SMOKE_SECONDS=1
}

_bs_teardown() {
    /bin/rm -rf "$BS_TMP"
    unset BS_TMP BUILD_SMOKE_SECONDS BS_MODE
}

_bs_run() { "$RUNTIME_DIR/bin/build-smoke" "$BS_TMP/checkout" main; }

test_build_smoke_passes_a_player_that_stays_up() {
    _bs_setup
    local rc=0 out code
    out=$(_bs_run); code=$?
    assert_equal "0" "$code" || rc=1
    assert_contains "$out" "SMOKE: result=pass reason=the player ran 1s with no missing script" || rc=1
    assert_equal "1" "$(/usr/bin/git -C "$BS_TMP/checkout" worktree list | /usr/bin/wc -l | /usr/bin/tr -d ' ')" "no worktree left behind" || rc=1
    _bs_teardown
    return $rc
}

test_build_smoke_fails_a_player_that_exits() {
    _bs_setup
    local rc=0 out code
    out=$(BS_MODE=exits _bs_run); code=$?
    assert_equal "1" "$code" || rc=1
    assert_contains "$out" "SMOKE: result=fail reason=the player exited within 1s of starting" || rc=1
    _bs_teardown
    return $rc
}

test_build_smoke_fails_a_scene_with_a_missing_script() {
    _bs_setup
    local rc=0 out
    out=$(BS_MODE=missing-script _bs_run)
    assert_contains "$out" "SMOKE: result=fail reason=the player log reports 1 missing script(s)" "broken wiring is caught" || rc=1
    _bs_teardown
    return $rc
}

test_build_smoke_fails_a_build_that_fails() {
    _bs_setup
    local rc=0 out
    out=$(BS_MODE=build-fails _bs_run)
    assert_contains "$out" "SMOKE: result=fail reason=the mac build failed (BUILD: target=mac exit=1" || rc=1
    _bs_teardown
    return $rc
}

test_build_smoke_fails_a_player_that_writes_no_log() {
    _bs_setup
    local rc=0 out code
    out=$(BS_MODE=no-log _bs_run); code=$?
    assert_equal "1" "$code" "no log is not a pass" || rc=1
    assert_contains "$out" "SMOKE: result=fail reason=the player wrote no log, so its scenes were not checked" || rc=1
    _bs_teardown
    return $rc
}
