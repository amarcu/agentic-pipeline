#!/bin/bash
# Tests for launchd-runtime/bin/focus-orphans.
#
# The script exists so `plan-features` Step 4 offers the same retirement list
# twice — a model reading bodies to decide what the focus dropped files the same
# issue differently on two runs, and the human then answers a list that moves.
# So these assert which of the three states each fixture issue lands in.
#
# Fixture repo acme/game, whose FOCUS.md has one focus line and two In-play
# lines:
#   #10  quotes an In-play line under `## Why now`            traces
#   #11  carries a `focus:` comment naming the focus line     traces
#   #12  quotes a line that has left the focus                orphan
#   #13  carries a `focus:` comment naming an old line        orphan
#   #14  neither reference, as a hand-filed issue has         untraceable
#   #15  an orphan, claimed by open PR #20 (`Closes #15`)     orphan, claimed

_fo_setup() {
    FO_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-orphans.XXXXXX)
    FO_BIN="$RUNTIME_DIR/bin/focus-orphans"
    export MOCK_GH_DIR="$FO_TMP/gh"
    export PATH="$FIXTURES_DIR/mock-gh:$PATH"
    export JQ_BIN
    export REPOS_CONF="$FO_TMP/repos.conf"
    /bin/mkdir -p "$MOCK_GH_DIR/acme-game" "$FO_TMP/checkout/agent"

    /bin/cat > "$REPOS_CONF" <<CONF
get_repo_path() {
    case "\$1" in
        acme/game) echo "$FO_TMP/checkout" ;;
        *)           echo "" ;;
    esac
}
CONF

    /bin/cat > "$FO_TMP/checkout/agent/FOCUS.md" <<'FOCUS'
## Focus (week of 2026-09-14)
<!-- one sentence: what the game should be able to do by the end of the week -->
Wire the combat scene end to end so a run can be played from spawn to death.

## In play — features
- Build the enemy prefabs in `Assets/Prefabs/Enemies/`
- Create the `EnemyData` instances

## In play — polish
- Restore `Time.timeScale = 1` on restart

## Not now
- Leaderboards (#9, retired 2026-09-07) — no backend yet

## Open questions for the next session

## Decisions log
- 2026-09-14 — the combat scene is the week's whole focus.
FOCUS

    /usr/bin/python3 - "$MOCK_GH_DIR/acme-game/issue-list.json" <<'PY'
import json, sys
def issue(number, title, body, labels=("proposed",), created="2026-09-01T00:00:00Z"):
    return {"number": number, "title": title, "body": body,
            "labels": [{"name": name} for name in labels], "createdAt": created}
issues = [
    issue(10, "Build the enemy prefabs", "## Goal\nPrefabs exist.\n\n## Why now\n"
          "> Build the enemy prefabs in `Assets/Prefabs/Enemies/`\n\n## Breakdown\n- one\n"),
    issue(11, "Wire the scene", "## Goal\nA run plays.\n\n## Breakdown\n- one\n\n"
          "<!-- plan-features run:2026-09-14 focus:\"Wire the combat scene end to end so a "
          "run can be played from spawn to death.\" -->"),
    issue(12, "Add a leaderboard", "## Goal\nScores post.\n\n## Why now\n"
          "> Ship a leaderboard behind the backend flag\n\n## Breakdown\n- one\n"),
    issue(13, "Tune the shop", "## Goal\nPrices read.\n\n## Breakdown\n- one\n\n"
          "<!-- plan-features run:2026-08-24 focus:\"Make the shop loop readable end to "
          "end.\" -->", ("proposed", "approved")),
    issue(14, "Split ProgressionData", "## Goal\nOne file per concern.\n\n"
          "## Why (verified in the code)\n- `Progression.cs:41` carries three concerns\n",
          ("proposed",)),
    issue(15, "Retune the boss", "## Goal\nThe boss lands.\n\n## Why now\n"
          "> Ship the boss fight\n\n## Breakdown\n- one\n", ("proposed", "approved")),
]
json.dump(issues, open(sys.argv[1], "w"))
PY

    /usr/bin/python3 -c '
import json, sys
json.dump([{"number": 20, "headRefName": "fix/boss-tuning",
            "body": "Retunes the boss.\n\nCloses #15"}], open(sys.argv[1], "w"))
' "$MOCK_GH_DIR/acme-game/pr-list.json"
}

_fo_teardown() {
    /bin/rm -rf "$FO_TMP"
}

_fo_run() {
    "$FO_BIN" "$@" 2>"$FO_TMP/stderr.txt"
}

test_focus_orphans_keeps_an_issue_the_focus_still_asks_for() {
    _fo_setup
    local rc=0 out
    out=$(_fo_run acme/game)
    assert_exit 0 $? "the list printed" || rc=1
    assert_not_contains "$out" "#10 " "an issue quoting an In-play line is not offered" || rc=1
    assert_not_contains "$out" "#11 " "nor one whose focus: comment names the current focus" || rc=1
    assert_contains "$out" "FOCUS: acme/game | wire the combat scene end to end" \
        "the header names the focus line it judged against" || rc=1
    _fo_teardown
    return $rc
}

test_focus_orphans_offers_an_issue_the_focus_has_dropped() {
    _fo_setup
    local rc=0 out
    out=$(_fo_run acme/game)
    assert_contains "$out" "ORPHAN: #12" "a Why now quoting a line that left the focus" || rc=1
    assert_contains "$out" "ORPHAN: #13" "a focus: comment naming an older focus line" || rc=1
    assert_contains "$out" "ORPHAN: #15" "and an orphan an open PR claims" || rc=1
    # approved is exactly the set unstick never surfaces, so it must appear here.
    assert_contains "$out" "proposed,approved" "an approved issue is a candidate like any other" || rc=1
    assert_contains "$out" "orphans=3" "three, and no more" || rc=1
    _fo_teardown
    return $rc
}

test_focus_orphans_counts_an_issue_with_no_focus_reference_instead_of_offering_it() {
    # A backlog written before the template is not evidence the work is unwanted.
    _fo_setup
    local rc=0 out
    out=$(_fo_run acme/game)
    assert_contains "$out" "UNTRACEABLE: 1 | #14" "the hand-filed issue is counted" || rc=1
    assert_contains "$out" "counted, not offered" "and says it is not on offer" || rc=1
    assert_not_contains "$out" "ORPHAN: #14" "it is not an orphan" || rc=1
    assert_contains "$out" "untraceable=1" "the summary carries it too" || rc=1
    _fo_teardown
    return $rc
}

test_focus_orphans_marks_an_orphan_an_open_pull_request_claims() {
    # Closing an issue under a running worker strands its branch, so reconcile
    # lists a claimed issue and never offers it.
    _fo_setup
    local rc=0 out
    out=$(_fo_run acme/game)
    assert_contains "$out" "claimed=#20" "the claiming PR is named on the line" || rc=1
    assert_contains "$out" "claimed=1" "and counted in the summary" || rc=1
    _fo_teardown
    return $rc
}

test_focus_orphans_reads_a_branch_as_a_claim_too() {
    _fo_setup
    local rc=0 out
    /usr/bin/python3 -c '
import json, sys
json.dump([{"number": 21, "headRefName": "task/issue-12-leaderboard", "body": "no keyword here"}],
          open(sys.argv[1], "w"))
' "$MOCK_GH_DIR/acme-game/pr-list.json"
    out=$(_fo_run acme/game)
    assert_contains "$out" "claimed=#21" "a task/issue-<N> branch claims its issue" || rc=1
    _fo_teardown
    return $rc
}

test_focus_orphans_refuses_a_repo_with_no_focus_file() {
    _fo_setup
    local rc=0
    /bin/rm -f "$FO_TMP/checkout/agent/FOCUS.md"
    _fo_run acme/game > /dev/null
    assert_exit 2 $? "no FOCUS.md is a refusal, not an empty list" || rc=1
    assert_contains "$(/bin/cat "$FO_TMP/stderr.txt")" "has no" "and says which file is missing" || rc=1
    _fo_teardown
    return $rc
}

test_focus_orphans_refuses_a_repo_outside_the_map() {
    _fo_setup
    local rc=0
    _fo_run acme/unmapped > /dev/null
    assert_exit 2 $? "a repo repos.conf does not map is a refusal" || rc=1
    assert_contains "$(/bin/cat "$FO_TMP/stderr.txt")" "get_repo_path" \
        "naming the map rather than scanning the filesystem" || rc=1
    _fo_teardown
    return $rc
}

test_focus_orphans_says_when_it_could_not_read_the_pull_requests() {
    # Without the PR list an issue a worker is building looks unclaimed, and
    # offering that for retirement is the one mistake here that costs work.
    _fo_setup
    local rc=0 out
    /bin/rm -f "$MOCK_GH_DIR/acme-game/pr-list.json"
    out=$(_fo_run acme/game)
    assert_exit 1 $? "a failed query is exit 1, not a silent pass" || rc=1
    assert_contains "$out" "ERROR:" "and an ERROR line naming it" || rc=1
    # Without it a worker's issue looks unclaimed, and retiring that strands the
    # branch — work-on-task then refuses the closed issue (Grok, PR #63 f3).
    assert_not_contains "$out" "ORPHAN: #" "no orphan is offered when claims are unknowable" || rc=1
    assert_contains "$out" "WITHHELD:" "and the run says why it is offering none" || rc=1
    assert_contains "$out" "orphans=0" "the summary agrees" || rc=1
    assert_equal "0" "$(_fo_run acme/game --json | "$JQ_BIN" -r '.orphans | length')" \
        "and so does --json, which reconcile reads" || rc=1
    _fo_teardown
    return $rc
}

test_focus_orphans_json_carries_both_lists() {
    _fo_setup
    local rc=0 out
    out=$(_fo_run acme/game --json)
    assert_equal "12 13 15" \
        "$(printf '%s' "$out" | "$JQ_BIN" -r '[.orphans[].number] | join(" ")')" \
        "the orphans, in issue order" || rc=1
    assert_equal "14" "$(printf '%s' "$out" | "$JQ_BIN" -r '[.untraceable[].number] | join(" ")')" \
        "the untraceable ones, separately" || rc=1
    assert_equal "20" "$(printf '%s' "$out" | "$JQ_BIN" -r '.orphans[] | select(.number == 15) | .claimed_by | tostring')" \
        "the claim is machine-readable" || rc=1
    assert_contains "$(printf '%s' "$out" | "$JQ_BIN" -r '.orphans[] | select(.number == 13) | .why')" \
        "left the focus" "each orphan says why it is one" || rc=1
    _fo_teardown
    return $rc
}

test_focus_orphans_changes_nothing_on_github() {
    _fo_setup
    local rc=0
    export MOCK_GH_LOG="$FO_TMP/gh-calls.log"
    _fo_run acme/game > /dev/null
    if /usr/bin/grep -qE '(--method (POST|PATCH|PUT|DELETE)|issue (close|edit|comment)|pr (merge|ready))' \
            "$MOCK_GH_LOG" 2>/dev/null; then
        echo "  FAIL: focus-orphans is read-only, but it called a writing command"
        /bin/cat "$MOCK_GH_LOG"
        rc=1
    fi
    unset MOCK_GH_LOG
    _fo_teardown
    return $rc
}
