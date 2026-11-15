#!/bin/bash
# Tests for launchd-runtime/bin/focus-queue.
#
# The script exists so `refill-queue` cuts each In-play line once. A model
# deciding which lines an issue already covers files the same line differently
# on two runs, and the second run cuts a duplicate. So these assert which lines
# come back as uncut, and that the three things that must stop a refill — the
# repo's own opt-in, a queue that is not empty, a query that failed — are read
# from the script and never inferred.
#
# Fixture repo acme/game. Its FOCUS.md has six In-play lines:
#   Enemy variety   an OPEN approved issue #10 quotes it              cut
#   Run telemetry   a CLOSED issue #11 quotes it                      cut
#   Booster pickups the line names its issue (#7) itself              cut
#   Boss            nothing quotes it                                 uncut, features
#   Restore …       nothing quotes it                                 uncut, polish
#   Move … C#12     nothing quotes it, and C#12 names no issue        uncut, polish
# and the other open issues are one of each queue state:
#   #12 approved, claimed by open PR #20   in review
#   #13 approved and blocked:needs-human   blocked
#   #14 proposed, not approved             waiting on the human

_fq_setup() {
    FQ_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-fqueue.XXXXXX)
    FQ_BIN="$RUNTIME_DIR/bin/focus-queue"
    export MOCK_GH_DIR="$FQ_TMP/gh"
    export PATH="$FIXTURES_DIR/mock-gh:$PATH"
    export JQ_BIN
    export REPOS_CONF="$FQ_TMP/repos.conf"
    /bin/mkdir -p "$MOCK_GH_DIR/acme-game" "$FQ_TMP/checkout/agent"

    /bin/cat > "$REPOS_CONF" <<CONF
get_repo_path() {
    case "\$1" in
        acme/game) echo "$FQ_TMP/checkout" ;;
        *)           echo "" ;;
    esac
}
CONF

    /bin/cat > "$FQ_TMP/checkout/agent/FOCUS.md" <<'FOCUS'
# Game — Focus

refill-queue: approve

## Focus (weeks of 2026-11-02 to 2026-11-23)
Reach a polished one-sector slice.

## In play — features
**Track 1 — ship and combat**
- **Enemy variety:** at least 3 enemy types across both factions.
- **Run telemetry:** log kills and pickups to the JSONL log.
- **Booster pickups:** short power-ups in the field. Issue #7.
- **Boss:** a boss framework and the first boss.

## In play — polish
- Restore `Time.timeScale = 1` on restart.
- Move the scripts to C#12 collection expressions.

## Not now
- Sectors 2 and 3, until the slice is fun.

## Decisions log
- 2026-11-04 — the slice includes the macro loop.
FOCUS

    /usr/bin/python3 - "$MOCK_GH_DIR/acme-game/issue-list.json" <<'PY'
import json, sys
def issue(number, title, body, labels=("proposed", "approved"), state="OPEN"):
    return {"number": number, "title": title, "body": body, "state": state,
            "labels": [{"name": name} for name in labels]}
issues = [
    issue(10, "Add two enemy types", "## Goal\nThree types.\n\n## Why now\n"
          "FOCUS.md In play: \"**Enemy variety:** at least 3 enemy types across both "
          "factions.\"\n\n## Breakdown\n- one\n"),
    issue(11, "Log run telemetry", "## Goal\nA run is measured.\n\n## Why now\n"
          "> Run telemetry: log kills and pickups\n> to the JSONL log.\n\n## Breakdown\n- one\n",
          state="CLOSED"),
    issue(12, "Wire the shop", "## Goal\nThe shop opens.\n\n## Why now\n"
          "> A line that has left the focus\n"),
    issue(13, "Buy an asset pack", "## Goal\nEffects.\n", ("proposed", "approved", "blocked:needs-human")),
    issue(14, "Tune the camera", "## Goal\nIt reads.\n", ("proposed",)),
    issue(15, "An old chore", "## Goal\nDone.\n", ("proposed",), state="CLOSED"),
]
json.dump(issues, open(sys.argv[1], "w"))
PY

    /usr/bin/python3 -c '
import json, sys
json.dump([{"number": 20, "headRefName": "task/issue-12-wire-the-shop", "body": "Closes #12"}],
          open(sys.argv[1], "w"))
' "$MOCK_GH_DIR/acme-game/pr-list.json"
}

_fq_teardown() {
    /bin/rm -rf "$FQ_TMP"
}

_fq_run() {
    "$FQ_BIN" "$@" 2>"$FQ_TMP/stderr.txt"
}

test_focus_queue_offers_only_the_lines_no_issue_was_cut_from() {
    _fq_setup
    local rc=0 out
    out=$(_fq_run acme/game)
    assert_exit 0 $? "the list prints" || rc=1
    assert_equal "UNCUT: 1 | features | **Boss:** a boss framework and the first boss.
UNCUT: 2 | polish | Restore \`Time.timeScale = 1\` on restart.
UNCUT: 3 | polish | Move the scripts to C#12 collection expressions." "$(echo "$out" | /usr/bin/grep '^UNCUT:')" \
        "the uncut lines come back verbatim, in the document's order, with the list they are under" || rc=1
    assert_contains "$out" "C#12" "a language version is not an issue number, so that line is not cut" || rc=1
    assert_not_contains "$out" "Enemy variety" "a line an open issue quotes is cut" || rc=1
    assert_not_contains "$out" "Run telemetry" "a line a closed issue quotes, reflowed, is cut: finished is an answer" || rc=1
    assert_not_contains "$out" "Booster pickups" "a line that names its own issue is cut" || rc=1
    assert_not_contains "$out" "Sectors 2 and 3" "a Not now line is never offered" || rc=1
    assert_not_contains "$out" "Track 1" "and a track heading is not a line" || rc=1
    assert_contains "$out" "FOCUSQUEUE: acme/game in_play=6 cut=3 uncut=3" "the count line adds up" || rc=1
    _fq_teardown
    return $rc
}

test_focus_queue_counts_what_is_already_waiting() {
    _fq_setup
    local rc=0 out
    out=$(_fq_run acme/game)
    assert_contains "$out" "QUEUE: acme/game approved_waiting=1 in_review=1 blocked=1 proposed_unapproved=1" \
        "an approved issue a PR claims is in review, a blocked one is not dispatchable, and neither is waiting work" || rc=1
    out=$(_fq_run acme/game --json)
    assert_equal "approve 1 3 Boss" \
        "$(echo "$out" | "$JQ_BIN" -r '"\(.mode) \(.queue.approved_waiting) \(.uncut | length) \(.uncut[0].line | split(":")[0] | gsub("\\*"; ""))"')" \
        "--json carries the same mode, queue and lines" || rc=1
    _fq_teardown
    return $rc
}

test_focus_queue_reads_the_repos_own_opt_in_and_nothing_looser() {
    _fq_setup
    local rc=0 focus="$FQ_TMP/checkout/agent/FOCUS.md"
    assert_contains "$(_fq_run acme/game)" "MODE: acme/game | approve" "the approve line is read" || rc=1
    /usr/bin/sed -i '' 's/^refill-queue: approve$/refill-queue: propose/' "$focus"
    assert_contains "$(_fq_run acme/game)" "MODE: acme/game | propose" "so is the propose line" || rc=1
    /usr/bin/sed -i '' 's/^refill-queue: propose$/A note: refill-queue: approve was discussed/' "$focus"
    local off
    off=$(_fq_run acme/game)
    assert_contains "$off" "MODE: acme/game | off" \
        "a sentence that mentions the words is not the line, so the mode is off" || rc=1
    assert_not_contains "$off" "UNCUT:" "and with the mode off no line is offered" || rc=1
    assert_contains "$off" "in_play=6 cut=3 uncut=3" "though the count still says what is waiting" || rc=1
    assert_equal "0" "$(_fq_run acme/game --json | "$JQ_BIN" -r '.uncut | length')" \
        "--json offers none either" || rc=1
    /usr/bin/sed -i '' 's/^A note: .*$/refill-queue: approve everything/' "$focus"
    assert_contains "$(_fq_run acme/game)" "MODE: acme/game | off" \
        "nor is a line with anything after the mode" || rc=1
    _fq_teardown
    return $rc
}

test_focus_queue_offers_nothing_when_github_cannot_be_read() {
    # Without the issue list every line looks uncut, and a refill would cut
    # the whole focus again.
    _fq_setup
    local rc=0 out
    /bin/rm -f "$MOCK_GH_DIR/acme-game/issue-list.json"
    out=$(_fq_run acme/game)
    assert_exit 1 $? "a failed query is exit 1, not a silent pass" || rc=1
    assert_contains "$out" "ERROR:" "with an ERROR line" || rc=1
    assert_not_contains "$out" "UNCUT:" "and no line is offered" || rc=1
    _fq_teardown
    return $rc
}

test_focus_queue_refuses_a_repo_it_cannot_place() {
    _fq_setup
    local rc=0
    _fq_run not-a-repo >/dev/null
    assert_exit 2 $? "a malformed repo is a usage error" || rc=1
    _fq_run acme/unknown >/dev/null
    assert_exit 2 $? "a repo outside the map is refused, never searched for" || rc=1
    assert_contains "$(/bin/cat "$FQ_TMP/stderr.txt")" "get_repo_path" "and the message says why" || rc=1
    /bin/rm -f "$FQ_TMP/checkout/agent/FOCUS.md"
    _fq_run acme/game >/dev/null
    assert_exit 2 $? "a repo with no FOCUS.md has no focus to cut from" || rc=1
    assert_equal "" "$(ls "$RUNTIME_DIR/bin/__pycache__" 2>/dev/null)" \
        "importing focus-orphans leaves no bytecode beside the scripts" || rc=1
    _fq_teardown
    return $rc
}
