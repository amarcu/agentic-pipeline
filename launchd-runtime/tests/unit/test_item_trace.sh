#!/bin/bash
# Tests for launchd-runtime/bin/item-trace — one issue's path through the
# pipeline, stage by stage.
#
# The reader joins two records that were never keyed on the same thing:
# GitHub's timestamps for an issue and its pull request, and this host's
# ledgers, which are keyed on a run. The cases here pin the join. A run that
# worked several issues has ONE cost, so the figures a wrong join would hide
# are the shares: an item must never be charged a whole run it only had part
# of, and a worker on another repo in the same run still takes its share.

_it_setup() {
    IT_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-item.XXXXXX)
    export MOCK_GH_DIR="$IT_TMP/gh"
    export PATH="$FIXTURES_DIR/mock-gh:$PATH"
    export JQ_BIN
    export TZ=UTC
    IT_BIN="$RUNTIME_DIR/bin/item-trace"
    IT_METRICS="$IT_TMP/metrics"
    /bin/mkdir -p "$MOCK_GH_DIR" "$IT_METRICS"
    # 1: approved after 12 h, one clean review round, merged.
    # 2: approved as it was opened, two review rounds, one iterate run, merged.
    # 3: proposed, never approved.
    # 4: approved, no pull request yet.
    # 9: the human's own issue — no pipeline label and no agent PR.
    # 10: a pull request, which the issues listing also returns.
    /bin/cat > "$MOCK_GH_DIR/issues.json" <<'JSON'
[
 {"number": 1,  "title": "Show fuel on the HUD", "state": "closed", "created_at": "2026-10-01T09:00:00Z", "closed_at": "2026-10-02T05:10:00Z", "labels": [{"name": "proposed"}, {"name": "approved"}]},
 {"number": 2,  "title": "Drop XP as pickups",   "state": "closed", "created_at": "2026-10-01T09:00:00Z", "closed_at": "2026-10-03T05:00:00Z", "labels": [{"name": "proposed"}, {"name": "approved"}]},
 {"number": 3,  "title": "Boss framework",       "state": "open",   "created_at": "2026-10-05T09:00:00Z", "closed_at": null, "labels": [{"name": "proposed"}]},
 {"number": 4,  "title": "Shop as data",         "state": "open",   "created_at": "2026-10-05T09:00:00Z", "closed_at": null, "labels": [{"name": "proposed"}, {"name": "approved"}]},
 {"number": 9,  "title": "Buy an asset pack",    "state": "open",   "created_at": "2026-10-05T09:00:00Z", "closed_at": null, "labels": []},
 {"number": 10, "title": "Show fuel on the HUD", "state": "closed", "created_at": "2026-10-02T02:20:00Z", "closed_at": "2026-10-02T05:10:00Z", "labels": [], "pull_request": {"url": "x"}}
]
JSON
    /bin/cat > "$MOCK_GH_DIR/pulls.json" <<'JSON'
[
 {"number": 10, "head": {"ref": "task/issue-1-hud",    "sha": "aaaaaaa0000000000000000000000000000000aa"}, "state": "closed", "created_at": "2026-10-02T02:20:00Z", "merged_at": "2026-10-02T05:10:00Z", "closed_at": "2026-10-02T05:10:00Z"},
 {"number": 11, "head": {"ref": "task/issue-2-pickup", "sha": "bbbbbbb0000000000000000000000000000000bb"}, "state": "closed", "created_at": "2026-10-02T02:40:00Z", "merged_at": "2026-10-03T05:00:00Z", "closed_at": "2026-10-03T05:00:00Z"},
 {"number": 12, "head": {"ref": "tools/my-own-branch", "sha": "ccccccc0000000000000000000000000000000cc"}, "state": "open",   "created_at": "2026-10-04T02:40:00Z", "merged_at": null, "closed_at": null}
]
JSON
    _it_approved 1 2026-10-01T21:00:00Z
    _it_approved 2 2026-10-01T09:00:30Z
    _it_approved 4 2026-10-05T10:00:00Z
    _it_review 10 cursor-review 1 pass           2026-10-02T03:00:00Z
    _it_review 11 cursor-review 1 changes-needed 2026-10-02T03:00:00Z
    _it_review 11 cursor-review 2 pass           2026-10-03T03:00:00Z

    # One dispatch run, three forked workers, one cost: 10, 20 and 10 minutes
    # of $8.00. The third worked another repo and still takes its quarter.
    _it_run  run-D dispatch-tasks-night 8.00
    _it_call 2026-10-02T04:10:00+0200 dispatch-tasks-night run-D Skill 0       "dispatch-tasks"
    _it_call 2026-10-02T04:21:00+0200 dispatch-tasks-night run-D Skill 600000  "work-on-task 1 --repo acme/game"
    _it_call 2026-10-02T04:41:00+0200 dispatch-tasks-night run-D Skill 1200000 "work-on-task 2 --repo acme/game"
    _it_call 2026-10-02T04:51:00+0200 dispatch-tasks-night run-D Skill 600000  "work-on-task 7 --repo acme/other"
    # One iterate run. The skill runs inline, so its row returns at once and
    # its time runs to the last tool call of the run, ten minutes later.
    _it_run  run-I pr-iterate-night 4.00
    _it_call 2026-10-03T06:05:10+0200 pr-iterate-night run-I Skill 0    "iterate-on-pr 11 --repo acme/game"
    _it_call 2026-10-03T06:15:10+0200 pr-iterate-night run-I Bash  2000 "git push"
    # A dry run plans and changes nothing; it is not work on the item.
    _it_run  run-X dispatch-tasks-night 5.00
    _it_call 2026-10-01T04:21:00+0200 dispatch-tasks-night run-X Skill 300000 "work-on-task 1 --repo acme/game --dry-run"
}

_it_teardown() {
    /bin/rm -rf "$IT_TMP"
}

# _it_approved <issue> <at>
_it_approved() {
    "$JQ_BIN" -n --arg at "$2" \
        '[{event: "labeled", label: {name: "proposed"}, created_at: "2026-10-01T09:00:00Z"},
          {event: "labeled", label: {name: "approved"}, created_at: $at}]' \
        > "$MOCK_GH_DIR/issue-events-$1.json"
}

# _it_review <pr> <lane> <round> <verdict> <submitted_at>
_it_review() {
    local f="$MOCK_GH_DIR/reviews-$1.json"
    [[ -f "$f" ]] || echo '[]' > "$f"
    "$JQ_BIN" --arg at "$5" \
        --arg body "<!-- $2 repo=acme/game pr=$1 round=$3 head=abc1234 model=some-model verdict=$4 gate=passed -->
## Review" \
        '. + [{id: 1, body: $body, submitted_at: $at}]' "$f" > "$f.new" && /bin/mv "$f.new" "$f"
}

# _it_run <run_id> <routine> <cost_usd>
_it_run() {
    "$JQ_BIN" -nc --arg rid "$1" --arg r "$2" --argjson c "$3" \
        '{routine: $r, ts: "2026-10-02 04:55:00 CEST", exit: 0, run_id: $rid, cost_usd: $c}' \
        >> "$IT_METRICS/runs.jsonl"
}

# _it_call <ts> <routine> <run_id> <tool> <duration_ms> <what>
_it_call() {
    "$JQ_BIN" -nc --arg ts "$1" --arg r "$2" --arg rid "$3" --arg t "$4" --argjson ms "$5" --arg w "$6" \
        '{ts: $ts, routine: $r, run_id: $rid, session_id: "s", tool: $t, duration_ms: $ms, what: $w}' \
        >> "$IT_METRICS/tool-calls.jsonl"
}

# The table's row for one issue, with runs of spaces squeezed to one.
_it_row() {
    echo "$1" | /usr/bin/awk -v want="$2" '$1 == want' | /usr/bin/tr -s ' ' | /usr/bin/sed 's/ $//'
}

test_item_trace_lists_each_item_with_the_time_it_spent_in_each_stage() {
    _it_setup
    local rc=0 out
    out=$("$IT_BIN" acme/game --metrics-dir "$IT_METRICS")
    assert_exit 0 $? "the table prints" || rc=1
    assert_equal "#1 merged #10 12h 00m 5h 20m 2h 50m 1 10m ~\$2.00" "$(_it_row "$out" "#1")" \
        "approval, queue and review are GitHub's own gaps; the worker's ten minutes are a quarter of the run" || rc=1
    assert_equal "#2 merged #11 30s 17h 39m 26h 20m 2 30m ~\$8.00" "$(_it_row "$out" "#2")" \
        "an item's work and cost add up across its dispatch run and its iterate run" || rc=1
    assert_equal "#3 awaiting approval - - - - 0 - -" "$(_it_row "$out" "#3")" \
        "a proposal nobody approved is held by the human, with no stage behind it" || rc=1
    assert_equal "#4 queued - 1h 00m - - 0 - -" "$(_it_row "$out" "#4")" \
        "an approved issue with no pull request is waiting on the pipeline" || rc=1
    assert_equal "" "$(_it_row "$out" "#9")" "the human's own issue is not a pipeline item" || rc=1
    assert_equal "" "$(_it_row "$out" "#10")" "and a pull request in the issues listing is not an issue" || rc=1
    assert_contains "$(_it_row "$out" "median")" "1h 00m" "the median row covers the items that reached a stage" || rc=1
    assert_contains "$out" "est.cost is the item's share of its runs' spend and is an estimate" \
        "the table says the cost is an estimate" || rc=1
    # With no --metrics-dir and no METRICS_DIR the ledgers are the runtime's
    # own, where every other reader looks.
    /bin/mkdir -p "$IT_TMP/state/routines"
    /bin/cp -R "$IT_METRICS" "$IT_TMP/state/routines/metrics"
    out=$(unset METRICS_DIR; AGENTIC_SKILLS_HOME="$IT_TMP/state" "$IT_BIN" acme/game)
    assert_equal "#1 merged #10 12h 00m 5h 20m 2h 50m 1 10m ~\$2.00" "$(_it_row "$out" "#1")" \
        "the default ledger directory is AGENTIC_SKILLS_HOME's routines/metrics" || rc=1
    out=$("$IT_BIN" acme/game --since 2026-10-05 --metrics-dir "$IT_METRICS")
    assert_equal "#3 #4" "$(echo "$out" | /usr/bin/awk '/^#/ {print $1}' | /usr/bin/paste -sd' ' -)" \
        "--since keeps the issues opened on or after that day" || rc=1
    _it_teardown
    return $rc
}

test_item_trace_prints_one_item_as_a_timeline_with_its_worker_runs() {
    _it_setup
    local rc=0 out
    out=$("$IT_BIN" acme/game 2 --metrics-dir "$IT_METRICS")
    assert_exit 0 $? "one item prints" || rc=1
    assert_contains "$out" "acme/game#2  Drop XP as pickups" "it is named" || rc=1
    assert_contains "$out" "waited 30s for approval" "with the wait for the human" || rc=1
    assert_contains "$out" "queued 17h 39m" "the wait for the pipeline" || rc=1
    assert_equal "review round 1: changes-needed|review round 2: pass" \
        "$(echo "$out" | /usr/bin/grep -o 'review round [0-9]: [a-z-]*' | /usr/bin/paste -sd'|' -)" \
        "and each marked review round in order" || rc=1
    assert_contains "$out" "2026-10-03 05:00  merged" "the end is the merge" || rc=1
    assert_equal "work-on-task #2 20m ~\$4.00 run-D|iterate-on-pr #11 10m ~\$4.00 run-I" \
        "$(echo "$out" | /usr/bin/awk '/run-[DI]$/ {print $3, $4, $5, $6, $7}' | /usr/bin/paste -sd'|' -)" \
        "each worker run is listed with its time, its share of the run's cost and the run to open" || rc=1
    assert_contains "$out" "not a measurement" "and the cost is called an estimate where it is printed" || rc=1
    assert_not_contains "$out" "run-X" "a dry run is not work on the item" || rc=1
    _it_teardown
    return $rc
}

test_item_trace_json_says_how_each_worker_span_was_measured() {
    _it_setup
    local rc=0 out
    out=$("$IT_BIN" acme/game 2 --json --metrics-dir "$IT_METRICS")
    assert_equal "fork to-next" "$(echo "$out" | "$JQ_BIN" -r '[.items[0].work[].measured] | join(" ")')" \
        "a forked worker carries its own duration; an inline skill is timed to the next row" || rc=1
    assert_equal "1800 8 2 merged" \
        "$(echo "$out" | "$JQ_BIN" -r '.items[0] | "\(.work_s | floor) \(.est_cost_usd | floor) \(.rounds) \(.state)"')" \
        "and the item's totals are the same figures the table prints" || rc=1
    _it_teardown
    return $rc
}

test_item_trace_still_prints_githubs_stages_with_no_ledger_on_this_host() {
    _it_setup
    local rc=0 out
    out=$("$IT_BIN" acme/game 1 --metrics-dir "$IT_TMP/never-created")
    assert_exit 0 $? "a host with no ledger still prints the item" || rc=1
    assert_contains "$out" "waited 12h 00m for approval" "GitHub's stages need no ledger" || rc=1
    assert_contains "$out" "worker runs: none in this host's ledger" \
        "and the missing half is said, not printed as zero" || rc=1
    _it_teardown
    return $rc
}

test_item_trace_fails_by_name() {
    _it_setup
    local rc=0 out
    out=$("$IT_BIN" acme/game 77 --metrics-dir "$IT_METRICS" 2>&1)
    assert_exit 1 $? "an issue the repo does not have is exit 1" || rc=1
    assert_contains "$out" "no issue #77 in acme/game" "and the message names it" || rc=1
    out=$("$IT_BIN" not-a-repo 2>&1)
    assert_exit 2 $? "a repo that is not owner/name is a usage error" || rc=1
    out=$("$IT_BIN" acme/game --since yesterday 2>&1)
    assert_exit 2 $? "so is a --since that is not a date" || rc=1
    /bin/rm "$MOCK_GH_DIR/pulls.json"
    out=$("$IT_BIN" acme/game --metrics-dir "$IT_METRICS" 2>&1)
    assert_exit 1 $? "a repo GitHub will not list is exit 1, not an empty table" || rc=1
    assert_contains "$out" "item-trace: acme/game:" "and the message names the repo" || rc=1
    _it_teardown
    return $rc
}
