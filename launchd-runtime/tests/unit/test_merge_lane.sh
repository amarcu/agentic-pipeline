#!/bin/bash
# Tests for launchd-runtime/bin/merge-lane — the only path by which an agent PR
# merges without the owner. What these pin: it merges only when Grok passed the
# exact head, unity-gate passes with no fewer tests than the last merge, and
# every changed file is in the phase-1 allowlist; the merge is pinned to that
# head; and every refusal is a normal outcome with a reason. gh, agent-prs,
# cursor-review and unity-gate are fakes driven by files in $ML_TMP.

_ml_setup() {
    ML_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-mergelane.XXXXXX)
    ML_STATE="$ML_TMP/state"
    /bin/mkdir -p "$ML_TMP/fake" "$ML_TMP/data" "$ML_STATE"
    : > "$ML_TMP/calls.log"

    # A real checkout whose origin carries refs/pull/7/head, so the lane's
    # `git fetch origin pull/7/head` works without a network.
    /usr/bin/git init -q --bare "$ML_TMP/origin.git"
    /usr/bin/git init -q -b main "$ML_TMP/checkout"
    /usr/bin/git -C "$ML_TMP/checkout" config user.email t@example.com
    /usr/bin/git -C "$ML_TMP/checkout" config user.name t
    echo base > "$ML_TMP/checkout/README.md"
    /usr/bin/git -C "$ML_TMP/checkout" add README.md
    /usr/bin/git -C "$ML_TMP/checkout" -c commit.gpgsign=false commit -qm base
    /usr/bin/git -C "$ML_TMP/checkout" remote add origin "$ML_TMP/origin.git"
    /usr/bin/git -C "$ML_TMP/checkout" push -q origin main
    echo change > "$ML_TMP/checkout/Change.cs"
    /usr/bin/git -C "$ML_TMP/checkout" add Change.cs
    /usr/bin/git -C "$ML_TMP/checkout" -c commit.gpgsign=false commit -qm change
    ML_HEAD=$(/usr/bin/git -C "$ML_TMP/checkout" rev-parse HEAD)
    /usr/bin/git -C "$ML_TMP/checkout" push -q origin "HEAD:refs/pull/7/head"
    /usr/bin/git -C "$ML_TMP/checkout" reset -q --hard HEAD~1

    export REPOS_CONF="$ML_TMP/repos.conf"
    /bin/cat > "$REPOS_CONF" <<EOF
get_repo_path() { case "\$1" in acme/game) echo "$ML_TMP/checkout" ;; *) echo "" ;; esac; }
MERGE_LANE_REPOS=( "acme/game" )
MERGE_LANE_MAX_PER_RUN=3
EOF

    # gh: answers from $ML_TMP/data and logs every call.
    /bin/cat > "$ML_TMP/fake/gh" <<'SH'
#!/bin/bash
echo "gh $*" >> "$ML_TMP/calls.log"
d="$ML_TMP/data"
case "$1 $2" in
    "repo view") echo '{"defaultBranchRef":{"name":"main"}}' ;;
    "pr view")
        if [[ "$*" == *"--json mergeable" ]]; then
            echo "{\"mergeable\": \"$(/bin/cat "$d/mergeable-$3" 2>/dev/null || echo MERGEABLE)\"}"
        elif [[ "$*" == *"--json headRefOid"* && "$*" != *"files"* ]]; then
            /usr/bin/python3 -c 'import json,sys; print(json.dumps({"headRefOid": json.load(open(sys.argv[1]))["headRefOid"]}))' "$d/pr-$3.json"
        else
            /bin/cat "$d/pr-$3.json"
        fi ;;
    "pr ready"|"pr merge"|"pr comment") exit 0 ;;
    api*) n=$(echo "$2" | /usr/bin/sed -E 's#.*/pulls/([0-9]+)/reviews#\1#'); /bin/cat "$d/reviews-$n.json" 2>/dev/null || echo '[]' ;;
    *) echo "fake gh: unhandled $*" >&2; exit 1 ;;
esac
SH
    /bin/cat > "$ML_TMP/fake/agent-prs" <<'SH'
#!/bin/bash
/bin/cat "$ML_TMP/data/agent-prs.txt"
SH
    /bin/cat > "$ML_TMP/fake/cursor-review" <<'SH'
#!/bin/bash
echo "cursor-review $* REVIEW_ROUND_MAX=$REVIEW_ROUND_MAX" >> "$ML_TMP/calls.log"
exit "$(/bin/cat "$ML_TMP/data/cursor-exit" 2>/dev/null || echo 0)"
SH
    /bin/cat > "$ML_TMP/fake/unity-gate" <<'SH'
#!/bin/bash
echo "unity-gate $*" >> "$ML_TMP/calls.log"
/bin/cat "$ML_TMP/data/gate.json"
SH
    /bin/cat > "$ML_TMP/fake/build-smoke" <<'SH'
#!/bin/bash
echo "build-smoke $*" >> "$ML_TMP/calls.log"
/bin/cat "$ML_TMP/data/smoke.txt" 2>/dev/null || echo "SMOKE: result=pass reason=ran seconds=30"
[ -e "$ML_TMP/data/smoke-fails" ] && exit 1
exit 0
SH
    /bin/chmod +x "$ML_TMP/fake/"*
    export ML_TMP GH_BIN="$ML_TMP/fake/gh" AGENT_PRS_BIN="$ML_TMP/fake/agent-prs"
    export CURSOR_REVIEW_BIN="$ML_TMP/fake/cursor-review" UNITY_GATE_BIN="$ML_TMP/fake/unity-gate"
    export MERGE_LANE_STATE_DIR="$ML_STATE" BUILD_SMOKE_BIN="$ML_TMP/fake/build-smoke" MERGE_LANE_MERGEABLE_WAIT=0

    printf '7\ttask/issue-3-x\tdraft\t2026-10-13T00:00:00Z\n' > "$ML_TMP/data/agent-prs.txt"
    _ml_pr 7 "Assets/_Game/Scripts/Systems/Change.cs" "Assets/_Game/Scripts/Tests/EditMode/ChangeTests.cs"
    _ml_review 7 "$ML_HEAD" pass passed 1
    echo '{"verdict":"pass","tests":5,"failed":0}' > "$ML_TMP/data/gate.json"
    echo 3 > "$ML_STATE/acme-game.tests"
}

_ml_teardown() {
    /bin/rm -rf "$ML_TMP"
    unset ML_TMP GH_BIN AGENT_PRS_BIN CURSOR_REVIEW_BIN UNITY_GATE_BIN MERGE_LANE_STATE_DIR REPOS_CONF \
        BUILD_SMOKE_BIN MERGE_LANE_MERGEABLE_WAIT
}

# _ml_pr number file... — an open, mergeable draft based on main at $ML_HEAD.
_ml_pr() {
    local n="$1"; shift
    /usr/bin/python3 - "$ML_TMP/data/pr-$n.json" "$ML_HEAD" "$@" <<'PY'
import json, sys
path, head, files = sys.argv[1], sys.argv[2], sys.argv[3:]
json.dump({"state": "OPEN", "baseRefName": "main", "headRefOid": head, "mergeable": "MERGEABLE",
           "reviewDecision": "", "isDraft": True, "files": [{"path": f} for f in files]}, open(path, "w"))
PY
}

# _ml_review number head verdict gate round — one cursor-review review body.
_ml_review() {
    /usr/bin/python3 - "$ML_TMP/data/reviews-$1.json" "$@" <<'PY'
import json, sys
path, n, head, verdict, gate, rnd = sys.argv[1:]
body = ("<!-- cursor-review repo=acme/game pr=%s round=%s head=%s model=m verdict=%s request_id=x -->\n"
        "## Independent review\n\n- Gate: `%s` - ok\n- Round %s of 3\n") % (n, rnd, head, verdict, gate, rnd)
json.dump([{"body": "A human comment"}, {"body": body}], open(path, "w"))
PY
}

_ml() { "$RUNTIME_DIR/bin/merge-lane" acme/game "$@"; }

test_merge_lane_merges_only_the_reviewed_head_when_every_check_passes() {
    _ml_setup
    local rc=0 out
    out=$(_ml)
    assert_contains "$out" "result=merged" || rc=1
    assert_contains "$(/bin/cat "$ML_TMP/calls.log")" "gh pr merge 7 --repo acme/game --squash --match-head-commit $ML_HEAD" \
        "the merge is pinned to the head Grok reviewed" || rc=1
    assert_contains "$(/bin/cat "$ML_TMP/calls.log")" "gh pr ready 7" "a draft is marked ready first" || rc=1
    assert_contains "$(/bin/cat "$ML_TMP/calls.log")" "unity-gate $ML_TMP/checkout $ML_HEAD" "the gate runs on that exact head" || rc=1
    assert_equal 5 "$(/bin/cat "$ML_STATE/acme-game.tests")" "the new test count becomes the floor" || rc=1
    _ml_teardown
    return $rc
}

test_merge_lane_waits_for_grok_on_a_new_head() {
    _ml_setup
    local rc=0 out
    _ml_review 7 0000000000000000000000000000000000000000 pass passed 1
    out=$(_ml)
    assert_contains "$out" "result=waiting" || rc=1
    assert_contains "$out" "no Grok review of head" || rc=1
    assert_contains "$(/bin/cat "$ML_TMP/calls.log")" "cursor-review acme/game 7 --post REVIEW_ROUND_MAX=3" "Grok is asked, capped at 3 rounds" || rc=1
    assert_not_contains "$(/bin/cat "$ML_TMP/calls.log")" "pr merge" || rc=1
    _ml_review 7 "$ML_HEAD" changes-needed passed 2
    out=$(_ml)
    assert_contains "$out" "result=waiting reason=Grok verdict changes-needed at round 2" || rc=1
    echo 7 > "$ML_TMP/data/cursor-exit"
    _ml_review 7 0000000000000000000000000000000000000000 changes-needed passed 3
    out=$(_ml)
    assert_contains "$out" "review rounds exhausted" "after 3 rounds the owner decides" || rc=1
    _ml_teardown
    return $rc
}

test_merge_lane_holds_imported_packs_and_csvs_for_the_owner() {
    _ml_setup
    local rc=0 out
    _ml_pr 7 "Assets/_Game/Scripts/Systems/Change.cs" "Assets/Imported/PolygonSciFiSpace/Prefabs/Ship.prefab"
    out=$(_ml)
    assert_contains "$out" "result=batch" "an imported pack's prefab is not the game's own" || rc=1
    assert_contains "$out" "Ship.prefab" "the reason names the file" || rc=1
    assert_not_contains "$(/bin/cat "$ML_TMP/calls.log")" "pr merge" || rc=1
    _ml >/dev/null
    assert_equal 1 "$(/usr/bin/grep -c "pr comment" "$ML_TMP/calls.log")" "one comment per head, not one per night" || rc=1
    _ml_pr 7 "Assets/_Game/Data/Progression/CSV/enemies.csv"
    out=$(_ml)
    assert_contains "$out" "result=batch" "a balance CSV is the owner's too" || rc=1
    _ml_teardown
    return $rc
}

test_merge_lane_merges_a_scene_change_only_after_the_build_smoke_test() {
    _ml_setup
    local rc=0 out
    _ml_pr 7 "Assets/_Game/Scripts/Systems/Change.cs" "Assets/_Game/Scenes/GameScene.unity" \
        "Assets/_Game/Editor/Wiring/PickupWiring.cs" "Assets/_Game/Prefabs/UI/Hud.prefab"
    out=$(_ml)
    assert_contains "$out" "result=merged" "phase 2: the game's own scenes and prefabs" || rc=1
    assert_contains "$(/bin/cat "$ML_TMP/calls.log")" "build-smoke $ML_TMP/checkout $ML_HEAD" "smoke-tested at that exact head" || rc=1
    _ml_teardown
    return $rc
}

test_merge_lane_holds_a_scene_change_whose_build_smoke_test_fails() {
    _ml_setup
    local rc=0 out
    _ml_pr 7 "Assets/_Game/Scenes/GameScene.unity"
    : > "$ML_TMP/data/smoke-fails"
    echo "SMOKE: result=fail reason=the player log reports 2 missing script(s) seconds=40" > "$ML_TMP/data/smoke.txt"
    out=$(_ml)
    assert_contains "$out" "result=skipped reason=scene change, and the build smoke test did not pass: result=fail reason=the player log reports 2 missing script(s)" || rc=1
    assert_not_contains "$(/bin/cat "$ML_TMP/calls.log")" "pr merge" || rc=1
    _ml_teardown
    return $rc
}

test_merge_lane_runs_no_build_for_a_code_only_change() {
    _ml_setup
    local rc=0
    _ml > /dev/null
    assert_not_contains "$(/bin/cat "$ML_TMP/calls.log")" "build-smoke" "a build costs minutes; code-only changes do not need one" || rc=1
    _ml_teardown
    return $rc
}

test_merge_lane_waits_out_githubs_unknown_mergeable_state() {
    _ml_setup
    local rc=0 out
    /usr/bin/sed -i '' 's/"MERGEABLE"/"UNKNOWN"/' "$ML_TMP/data/pr-7.json"
    out=$(_ml)
    assert_contains "$out" "result=merged" "UNKNOWN is GitHub still computing, not a refusal" || rc=1
    echo UNKNOWN > "$ML_TMP/data/mergeable-7"
    _ml_pr 7 "Assets/_Game/Scripts/Systems/Change.cs"
    /usr/bin/sed -i '' 's/"MERGEABLE"/"UNKNOWN"/' "$ML_TMP/data/pr-7.json"
    out=$(_ml)
    assert_contains "$out" "result=skipped reason=GitHub says UNKNOWN" "but it does not wait forever" || rc=1
    _ml_teardown
    return $rc
}

test_merge_lane_refuses_fewer_tests_or_no_tests() {
    _ml_setup
    local rc=0 out
    echo '{"verdict":"pass","tests":2,"failed":0}' > "$ML_TMP/data/gate.json"
    out=$(_ml)
    assert_contains "$out" "result=skipped reason=test count 2 (last merge 3)" || rc=1
    echo '{"verdict":"pass-no-tests","tests":0}' > "$ML_TMP/data/gate.json"
    out=$(_ml)
    assert_contains "$out" "unity-gate verdict pass-no-tests" "nothing tested is never a pass" || rc=1
    echo '{"verdict":"compile-error","errors":"CS0103"}' > "$ML_TMP/data/gate.json"
    out=$(_ml)
    assert_contains "$out" "unity-gate verdict compile-error" || rc=1
    assert_not_contains "$(/bin/cat "$ML_TMP/calls.log")" "pr merge" || rc=1
    _ml_teardown
    return $rc
}

test_merge_lane_respects_changes_requested_kill_switch_dry_run_and_roster() {
    _ml_setup
    local rc=0 out
    out=$(_ml --dry-run)
    assert_contains "$out" "result=would-merge" || rc=1
    assert_not_contains "$(/bin/cat "$ML_TMP/calls.log")" "pr merge" "a dry run merges nothing" || rc=1
    /usr/bin/python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["reviewDecision"]="CHANGES_REQUESTED"; json.dump(d,open(p,"w"))' "$ML_TMP/data/pr-7.json"
    out=$(_ml)
    assert_contains "$out" "result=skipped reason=changes requested" || rc=1
    : > "$ML_STATE/OFF"
    out=$(_ml)
    assert_contains "$out" "result=refused reason=kill switch" || rc=1
    out=$("$RUNTIME_DIR/bin/merge-lane" acme/other)
    assert_contains "$out" "result=refused reason=repo not in MERGE_LANE_REPOS" || rc=1
    assert_not_contains "$(/bin/cat "$ML_TMP/calls.log")" "pr merge" || rc=1
    _ml_teardown
    return $rc
}

test_merge_lane_stops_at_the_per_run_limit() {
    _ml_setup
    local rc=0 out
    printf '7\ttask/issue-3-x\tdraft\tt\n8\ttask/issue-4-y\tdraft\tt\n' > "$ML_TMP/data/agent-prs.txt"
    /bin/cp "$ML_TMP/data/pr-7.json" "$ML_TMP/data/pr-8.json"
    _ml_review 8 "$ML_HEAD" pass passed 1
    /usr/bin/git -C "$ML_TMP/checkout" push -q origin "$ML_HEAD:refs/pull/8/head"
    out=$(_ml --max 1)
    assert_equal 1 "$(printf '%s\n' "$out" | /usr/bin/grep -c "result=merged")" "one merge with --max 1" || rc=1
    assert_contains "$out" "merge limit for this run reached" || rc=1
    _ml_teardown
    return $rc
}

test_merge_lane_night_skips_the_model_unless_the_lane_fails() {
    # The routine's precheck: exit 10 tells _run.sh "done, do not start the
    # model"; any other exit starts the failure-report prompt instead.
    _ml_setup
    local rc=0 out status
    /bin/cat > "$ML_TMP/fake/lane" <<'SH'
#!/bin/bash
echo "MERGE-LANE: repo=$1 pr=7 result=merged reason=ok"
echo "MERGE-LANE: repo=$1 pr=8 result=batch reason=scene"
exit "$(/bin/cat "$ML_TMP/data/lane-exit" 2>/dev/null || echo 0)"
SH
    /bin/chmod +x "$ML_TMP/fake/lane"
    export MERGE_LANE_BIN="$ML_TMP/fake/lane"
    out=$("$RUNTIME_DIR/bin/merge-lane-night"); status=$?
    assert_equal 10 "$status" "a clean lane run never starts the model" || rc=1
    assert_equal "MERGE-LANE-RUN: merged=1 waiting=0 batch=1 skipped=0 errors=0 status=0" "$(printf '%s\n' "$out" | /usr/bin/head -1)" \
        "the first line is the summary the runner records" || rc=1
    assert_contains "$out" "repo=acme/game pr=7 result=merged" "every decision line is logged" || rc=1
    echo 1 > "$ML_TMP/data/lane-exit"
    out=$("$RUNTIME_DIR/bin/merge-lane-night"); status=$?
    assert_equal 1 "$status" "a failed lane hands over to the failure report" || rc=1
    unset MERGE_LANE_BIN
    _ml_teardown
    return $rc
}
