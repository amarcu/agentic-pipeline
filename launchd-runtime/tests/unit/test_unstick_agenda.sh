#!/bin/bash
# Tests for unstick/scripts/agenda and unstick/scripts/log-session.
#
# The agenda is the list the daily review sitting walks. It is a script and not
# prose for the reason triage-repo.sh is: a model assembling a queue by
# reasoning files the same item differently on two runs. So these assert which
# SECTION every fixture item lands in and the ORDER the sitting meets them in,
# against the shared mock gh, which also records every call: the agenda must
# never be the thing that changes GitHub.
#
# Fixture roster, AGENDA_NOW=2026-09-11T12:00:00Z, DISPATCH_PER_REPO_MAX=2,
# and acme/engine is a driver (get_driver acme/engine-docs):
#   acme/game    two agent PRs (#49 branch, #51 `Closes #60` - at the per-repo
#                  cap) with approved #61 queued behind them; ready PR #50;
#                  draft #51 Cursor passed on its current head, draft #52 it
#                  passed on an OLDER head, draft #53 whose Copilot round is
#                  green; proposal #44; blocked proposal #47; FOCUS.md last
#                  decided nine days ago; four approved or proposed issues
#   acme/engine  host check fails with three approved issues waiting (#18 is
#                  also blocked); no FOCUS.md but focus PR #7 is open; draft #8
#                  is an agent's only by work-on-task's marker
#   acme/site    host ok, FOCUS.md decided two days ago: contributes nothing
#   amarcu/agentic-pipeline  outside ACTIVE_REPOS; one pipeline draft, #40

_ua_setup() {
    UA_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-unstick.XXXXXX)
    UA_AGENDA="$REPO_ROOT/skills/unstick/scripts/agenda"
    UA_LOG_SESSION="$REPO_ROOT/skills/unstick/scripts/log-session"
    export MOCK_GH_DIR="$UA_TMP/gh"
    export MOCK_GH_LOG="$UA_TMP/gh-calls.log"
    export PATH="$FIXTURES_DIR/mock-gh:$PATH"
    export JQ_BIN
    export AGENDA_NOW="2026-09-11T12:00:00Z"
    export REPOS_CONF="$UA_TMP/repos.conf"
    export CHECK_REQUIREMENTS="$UA_TMP/bin/check-requirements"
    export PR_REVIEW_ROUND="$UA_TMP/bin/pr-review-round"
    export SSH_BIN="$UA_TMP/bin/ssh"
    export UA_TMP
    /bin/mkdir -p "$UA_TMP/bin" "$UA_TMP/req" "$UA_TMP/round" "$UA_TMP/ssh" \
        "$MOCK_GH_DIR/acme-game/contents/agent" "$MOCK_GH_DIR/acme-engine" \
        "$MOCK_GH_DIR/acme-site/contents/agent" "$MOCK_GH_DIR/amarcu-agentic-pipeline"

    /bin/cat > "$REPOS_CONF" <<'CONF'
ACTIVE_REPOS=(
    "acme/game"
    "acme/engine"
    "acme/site"
)
REPOS_BY_PRIORITY=(
    "acme/game"
    "acme/engine"
    "acme/site"
    "acme/engine-docs"
)
DISPATCH_PER_REPO_MAX=2
get_driver() {
    case "$1" in
        acme/engine-docs) echo "acme/engine" ;;
        *)                  echo "" ;;
    esac
}
CONF

    # check-requirements: serves req/<owner>-<name>.json, else no manifest.
    /bin/cat > "$CHECK_REQUIREMENTS" <<'SH'
#!/bin/bash
echo "$1 PATH=$PATH" >> "$UA_TMP/req/calls.log"
f="$UA_TMP/req/$(echo "$1" | /usr/bin/tr / -).json"
if [[ -f "$f" ]]; then /bin/cat "$f"; exit 1; fi
printf '{"repo": "%s", "status": "no-manifest", "missing": [], "errors": [], "requirements": []}\n' "$1"
SH

    # pr-review-round: green only for PRs with a round/<owner>-<name>-<n> file.
    /bin/cat > "$PR_REVIEW_ROUND" <<'SH'
#!/bin/bash
echo "$*" >> "$UA_TMP/round/calls.log"
[[ -f "$UA_TMP/round/$(echo "$2" | /usr/bin/tr / -)-$3" ]] && exit 0
exit 1
SH

    # ssh: records its argv, then exits with ssh/rc or prints ssh/out.
    /bin/cat > "$SSH_BIN" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "$UA_TMP/ssh/argv"
[[ -f "$UA_TMP/ssh/rc" ]] && exit "$(/bin/cat "$UA_TMP/ssh/rc")"
/bin/cat "$UA_TMP/ssh/out"
exit 1
SH
    /bin/chmod +x "$CHECK_REQUIREMENTS" "$PR_REVIEW_ROUND" "$SSH_BIN"
    : > "$UA_TMP/round/acme-game-53"

    /bin/cat > "$UA_TMP/req/acme-engine.json" <<'JSON'
{"repo": "acme/engine", "status": "missing", "source": "template", "missing": ["xcodebuild -version", "../game-engine"], "below_floor": [], "errors": [], "requirements": [{"verb": "check", "spec": "xcodebuild -version", "status": "missing", "hint": "install full Xcode", "install": ""}, {"verb": "path", "spec": "../game-engine", "status": "missing", "hint": "", "install": "git clone git@github.com:acme/game-engine.git ../game-engine"}, {"verb": "cmd", "spec": "gh", "status": "ok", "hint": "brew upgrade gh", "install": ""}]}
JSON
    /bin/cat > "$UA_TMP/req/acme-site.json" <<'JSON'
{"repo": "acme/site", "status": "ok", "source": "repo", "missing": [], "below_floor": [], "errors": [], "requirements": []}
JSON

    /bin/cat > "$MOCK_GH_DIR/acme-game/issue-list.json" <<'JSON'
[
  {"number": 44, "title": "Camera baseline", "labels": [{"name": "proposed"}],
   "createdAt": "2026-09-07T09:00:00Z", "url": "https://github.com/acme/game/issues/44"},
  {"number": 45, "title": "Session log", "labels": [{"name": "proposed"}, {"name": "approved"}],
   "createdAt": "2026-09-07T09:00:00Z", "url": "https://github.com/acme/game/issues/45"},
  {"number": 47, "title": "Needs a design call", "labels": [{"name": "proposed"}, {"name": "blocked:needs-design"}],
   "createdAt": "2026-09-08T09:00:00Z", "url": "https://github.com/acme/game/issues/47"},
  {"number": 61, "title": "Queued behind the cap", "labels": [{"name": "approved"}],
   "createdAt": "2026-09-01T09:00:00Z", "url": "https://github.com/acme/game/issues/61"}
]
JSON
    /bin/cat > "$MOCK_GH_DIR/acme-game/pr-list.json" <<'JSON'
[
  {"number": 49, "title": "Log runs to JSONL", "isDraft": true, "headRefName": "task/issue-45-telemetry",
   "headRefOid": "4949494949494949494949494949494949494949", "body": "", "reviews": [],
   "createdAt": "2026-09-10T09:00:00Z", "url": "https://github.com/acme/game/pull/49"},
  {"number": 50, "title": "A human feature, not a draft", "isDraft": false, "headRefName": "feature/x",
   "headRefOid": "5050505050505050505050505050505050505050", "body": "", "reviews": [],
   "createdAt": "2026-09-05T09:00:00Z", "url": "https://github.com/acme/game/pull/50"},
  {"number": 51, "title": "Cursor passed this head", "isDraft": true, "headRefName": "wip/sixty",
   "headRefOid": "5151515151515151515151515151515151515151", "body": "Closes #60",
   "createdAt": "2026-09-09T09:00:00Z", "url": "https://github.com/acme/game/pull/51",
   "reviews": [
     {"body": "late round 1\n<!-- cursor-review repo=acme/game pr=51 round=1 head=aaaa000000000000000000000000000000000000 model=m verdict=changes-needed request_id=r1 -->",
      "submittedAt": "2026-09-10T11:00:00Z"},
     {"body": "round 2\n<!-- cursor-review repo=acme/game pr=51 round=2 head=5151515151515151515151515151515151515151 model=m verdict=pass request_id=r2 -->",
      "submittedAt": "2026-09-10T10:00:00Z"}]},
  {"number": 52, "title": "Cursor passed an older head", "isDraft": true, "headRefName": "spike/lighting",
   "headRefOid": "5252525252525252525252525252525252525252", "body": "",
   "createdAt": "2026-09-03T09:00:00Z", "url": "https://github.com/acme/game/pull/52",
   "reviews": [
     {"body": "<!-- cursor-review repo=acme/game pr=52 round=1 head=bbbb000000000000000000000000000000000000 model=m verdict=pass request_id=r3 -->",
      "submittedAt": "2026-09-04T10:00:00Z"}]},
  {"number": 53, "title": "Copilot round is green", "isDraft": true, "headRefName": "chore/deps",
   "headRefOid": "5353535353535353535353535353535353535353", "body": "", "reviews": [],
   "createdAt": "2026-09-09T09:00:00Z", "url": "https://github.com/acme/game/pull/53"}
]
JSON
    /bin/cat > "$MOCK_GH_DIR/acme-game/contents/agent/FOCUS.md" <<'MD'
# Focus

## Focus (week of 2026-09-02)
Ship the camera work.

## Decisions log
- 2026-09-02 — Product work is features and polish from this file.
- 2026-08-26 — An earlier session.

## Parking lot
- 2026-09-10 an idea that is not a decision
MD

    /bin/cat > "$MOCK_GH_DIR/acme-engine/issue-list.json" <<'JSON'
[
  {"number": 18, "title": "Draw connecting paths", "labels": [{"name": "proposed"}, {"name": "approved"}, {"name": "blocked:could-not-run"}],
   "createdAt": "2026-09-04T09:00:00Z", "url": "https://github.com/acme/engine/issues/18"},
  {"number": 20, "title": "Map node icons", "labels": [{"name": "approved"}],
   "createdAt": "2026-09-04T09:00:00Z", "url": "https://github.com/acme/engine/issues/20"},
  {"number": 21, "title": "Log data load failures", "labels": [{"name": "proposed"}, {"name": "approved"}],
   "createdAt": "2026-09-05T09:00:00Z", "url": "https://github.com/acme/engine/issues/21"}
]
JSON
    /bin/cat > "$MOCK_GH_DIR/acme-engine/pr-list.json" <<'JSON'
[
  {"number": 7, "title": "Focus - week of 2026-09-10", "isDraft": true, "headRefName": "docs/focus-2026-09-10",
   "headRefOid": "0707070707070707070707070707070707070707", "body": "", "reviews": [],
   "createdAt": "2026-09-10T09:00:00Z", "url": "https://github.com/acme/engine/pull/7"},
  {"number": 8, "title": "Guard the loader deref", "isDraft": true, "headRefName": "fix/loader",
   "headRefOid": "0808080808080808080808080808080808080808", "reviews": [],
   "body": "Guards the deref.\n\n<!-- agentic-skills: skill=work-on-task repo=acme/engine issue=22 pr=8 routine=dispatch-tasks-night run=r1 model=m -->",
   "createdAt": "2026-09-09T09:00:00Z", "url": "https://github.com/acme/engine/pull/8"}
]
JSON

    /bin/cat > "$MOCK_GH_DIR/acme-site/issue-list.json" <<'JSON'
[
  {"number": 3, "title": "Approved and waiting", "labels": [{"name": "proposed"}, {"name": "approved"}],
   "createdAt": "2026-08-01T09:00:00Z", "url": "https://github.com/acme/site/issues/3"}
]
JSON
    echo '[]' > "$MOCK_GH_DIR/acme-site/pr-list.json"
    /bin/cat > "$MOCK_GH_DIR/acme-site/contents/agent/FOCUS.md" <<'MD'
## Decisions log
- 2026-09-09 — Fresh enough that no session is due.
MD

    echo '[]' > "$MOCK_GH_DIR/amarcu-agentic-pipeline/issue-list.json"
    /bin/cat > "$MOCK_GH_DIR/amarcu-agentic-pipeline/pr-list.json" <<'JSON'
[
  {"number": 40, "title": "Package the repo as a plugin", "isDraft": true, "headRefName": "pipeline/plugin-packaging",
   "headRefOid": "4040404040404040404040404040404040404040", "body": "", "reviews": [],
   "createdAt": "2026-09-10T09:00:00Z", "url": "https://github.com/amarcu/agentic-pipeline/pull/40"}
]
JSON
}

_ua_teardown() {
    /bin/rm -rf "$UA_TMP"
}

# The sections an item landed in, space-separated: "<repo> <number|null>".
_ua_sections() {
    printf '%s' "$1" | "$JQ_BIN" -r --arg repo "$2" --argjson n "$3" \
        '[.items[] | select(.repo == $repo and .number == $n) | .section] | join(" ")'
}

_ua_field() {
    printf '%s' "$1" | "$JQ_BIN" -r --arg id "$2" --arg f "$3" \
        '.items[] | select(.id == $id) | .[$f] | if type == "array" then join("|") else tostring end'
}

_ua_more_ids() {
    printf '%s' "$1" | "$JQ_BIN" -r --arg s "$2" '[.more[] | select(.section == $s) | .ids[]] | join(" ")'
}

_ua_more_line() {
    printf '%s' "$1" | "$JQ_BIN" -r --arg s "$2" '.more[] | select(.section == $s) | .line'
}

test_unstick_agenda_orders_items_by_what_each_unblocks() {
    _ua_setup
    local rc=0 got expected
    got=$("$UA_AGENDA" --json 2>/dev/null | "$JQ_BIN" -r '.items[].id')
    expected="host:acme/engine
merge:acme/game#51
review:acme/game#49
merge:acme/game#50
merge:acme/game#53
blocked:acme/engine#18
blocked:acme/game#47
review:acme/engine#8
approve:acme/game#44
direction:acme/engine"
    if [[ "$got" != "$expected" ]]; then
        echo "  FAIL: the agenda order is not unblocks, then section, then oldest:"
        /usr/bin/diff <(printf '%s\n' "$expected") <(printf '%s\n' "$got") | /usr/bin/sed 's/^/    /'
        rc=1
    fi
    _ua_teardown
    return $rc
}

test_unstick_agenda_host_counts_the_queued_issues_a_failing_repo_sits_on() {
    _ua_setup
    local rc=0 out
    out=$("$UA_AGENDA" --json 2>/dev/null)
    assert_equal "HOST" "$(_ua_sections "$out" acme/engine null | /usr/bin/tr ' ' '\n' | /usr/bin/grep HOST)" \
        "a missing requirement is a HOST item" || rc=1
    assert_equal 3 "$(_ua_field "$out" host:acme/engine unblocks)" \
        "every approved issue without a PR waits on the host, blocked ones included" || rc=1
    assert_equal 7 "$(_ua_field "$out" host:acme/engine age_days)" \
        "a HOST item is as old as the oldest issue waiting on it" || rc=1
    assert_contains "$(_ua_field "$out" host:acme/engine detail)" \
        "missing: xcodebuild -version, ../game-engine (template); sitting on 3 approved issue(s)" || rc=1
    assert_equal "install full Xcode|git clone git@github.com:acme/game-engine.git ../game-engine" \
        "$(_ua_field "$out" host:acme/engine hints)" "the hand-back carries each missing hint" || rc=1
    assert_not_contains "$out" '"host:acme/site"' "a passing check is not an item" || rc=1
    assert_not_contains "$out" '"host:acme/game"' "a repo with no manifest is not an item" || rc=1
    assert_not_contains "$(/bin/cat "$UA_TMP/req/calls.log")" "agentic-skills" \
        "HOST covers ACTIVE_REPOS only" || rc=1
    _ua_teardown
    return $rc
}

test_unstick_agenda_splits_prs_into_merge_and_review() {
    _ua_setup
    local rc=0 out
    out=$("$UA_AGENDA" --json 2>/dev/null)
    assert_equal MERGE  "$(_ua_sections "$out" acme/game 50)" "a non-draft PR is a merge decision" || rc=1
    assert_equal MERGE  "$(_ua_sections "$out" acme/game 51)" \
        "a draft is green when the newest cursor-review about its head says pass" || rc=1
    assert_equal MERGE  "$(_ua_sections "$out" acme/game 53)" "a draft is green when pr-review-round says so" || rc=1
    assert_equal REVIEW "$(_ua_sections "$out" acme/game 49)" "an agent draft nobody passed awaits review" || rc=1
    assert_equal ""     "$(_ua_sections "$out" acme/game 52)" \
        "a pass on an older head is not a pass, and a non-agent draft is not listed" || rc=1
    assert_equal 2 "$(_ua_field "$out" review:acme/game#49 unblocks)" \
        "an agent PR in a repo at the per-repo cap frees the issue queued behind it" || rc=1
    assert_equal 1 "$(_ua_field "$out" merge:acme/game#50 unblocks)" "a human PR frees no dispatch slot" || rc=1
    if /usr/bin/grep -qE ' (50|51)$' "$UA_TMP/round/calls.log"; then
        echo "  FAIL: pr-review-round was asked about a non-draft or an already-green draft:"
        /usr/bin/sed 's/^/    /' "$UA_TMP/round/calls.log"
        rc=1
    fi
    if /usr/bin/grep -vqE '^status [a-z]+/[a-z-]+ [0-9]+$' "$UA_TMP/round/calls.log"; then
        echo "  FAIL: pr-review-round was called with something other than status:"
        /usr/bin/sed 's/^/    /' "$UA_TMP/round/calls.log"
        rc=1
    fi
    _ua_teardown
    return $rc
}

test_unstick_agenda_merge_steps_mark_a_draft_ready_before_merging_it() {
    # Grok on PR #41 (f1): GitHub refuses to merge a draft, and a refused merge
    # retried as `gh pr ready` is the workaround Respect the Denial forbids. So
    # the item says up front that a green draft takes two confirmed steps.
    _ua_setup
    local rc=0 out text
    out=$("$UA_AGENDA" --json 2>/dev/null)
    text=$("$UA_AGENDA" 2>/dev/null)
    assert_equal "ready|merge" "$(_ua_field "$out" merge:acme/game#51 steps)" \
        "a draft with a cursor-review pass is marked ready, then merged" || rc=1
    assert_equal "ready|merge" "$(_ua_field "$out" merge:acme/game#53 steps)" \
        "so is a draft whose Copilot round is green" || rc=1
    assert_equal "merge" "$(_ua_field "$out" merge:acme/game#50 steps)" \
        "a PR that is not a draft is merged, with no ready step" || rc=1
    assert_equal "" "$(_ua_field "$out" review:acme/game#49 steps)" \
        "a draft still under review has no step: ready waits for a passed review (Grok, PR #41 f3)" || rc=1
    assert_contains "$(printf '%s\n' "$text" | /usr/bin/grep -F '[merge:acme/game#51]')" \
        "mark ready, then merge" "the text line says it too" || rc=1
    assert_contains "$(printf '%s\n' "$text" | /usr/bin/grep -F '[merge:acme/game#50]')" \
        "not a draft; merge" || rc=1
    _ua_teardown
    return $rc
}

test_unstick_agenda_lists_agent_drafts_and_counts_the_other_drafts() {
    _ua_setup
    local rc=0 out
    out=$("$UA_AGENDA" --json 2>/dev/null)
    assert_equal REVIEW "$(_ua_sections "$out" acme/game 49)" "an agent branch makes a draft an agent's" || rc=1
    assert_equal REVIEW "$(_ua_sections "$out" acme/engine 8)" "so does work-on-task's marker" || rc=1
    assert_equal ""     "$(_ua_sections "$out" acme/engine 7)" "a focus-docs draft is not an agent's" || rc=1
    assert_equal ""     "$(_ua_sections "$out" amarcu/agentic-pipeline 40)" "nor is a pipeline draft" || rc=1
    assert_equal 2 "$(printf '%s' "$out" | "$JQ_BIN" -r '.counts.REVIEW')" "only the two agent drafts are items" || rc=1
    assert_equal "review:acme/game#52 review:acme/engine#7 review:amarcu/agentic-pipeline#40" \
        "$(_ua_more_ids "$out" REVIEW)" "every other draft is still named, in agenda order" || rc=1
    assert_equal "REVIEW +3 other drafts (bootstrap/pipeline PRs): acme/game#52, acme/engine#7, amarcu/agentic-pipeline#40" \
        "$(_ua_more_line "$out" REVIEW)" || rc=1
    _ua_teardown
    return $rc
}

test_unstick_agenda_without_pr_review_round_says_so_and_trusts_only_cursor() {
    _ua_setup
    local rc=0 out
    export PR_REVIEW_ROUND="$UA_TMP/bin/absent"
    out=$("$UA_AGENDA" --json 2>/dev/null)
    assert_equal "" "$(_ua_sections "$out" acme/game 53)" "no round script, no round green" || rc=1
    assert_contains "$(_ua_more_ids "$out" REVIEW)" "review:acme/game#53" "so #53 is an other draft again" || rc=1
    assert_equal MERGE "$(_ua_sections "$out" acme/game 51)" "a cursor pass still counts" || rc=1
    assert_contains "$(printf '%s' "$out" | "$JQ_BIN" -r '.notes[]')" "pr-review-round not found at" || rc=1
    _ua_teardown
    return $rc
}

test_unstick_agenda_files_proposals_and_blocked_issues() {
    _ua_setup
    local rc=0 out
    out=$("$UA_AGENDA" --json 2>/dev/null)
    assert_equal APPROVE "$(_ua_sections "$out" acme/game 44)" "proposed and not approved" || rc=1
    assert_equal ""      "$(_ua_sections "$out" acme/game 45)" "an approved proposal is not waiting on approval" || rc=1
    assert_equal BLOCKED "$(_ua_sections "$out" acme/game 47)" "a blocked proposal is blocked, and only that" || rc=1
    assert_equal BLOCKED "$(_ua_sections "$out" acme/engine 18)" "any blocked:* label" || rc=1
    assert_equal "blocked:could-not-run" "$(_ua_field "$out" blocked:acme/engine#18 detail)" "the reason is the label" || rc=1
    assert_equal ""      "$(_ua_sections "$out" acme/engine 20)" "an approved issue is queued work, not an item" || rc=1
    assert_equal ""      "$(_ua_sections "$out" acme/site 3)" "same in a repo with nothing else" || rc=1
    _ua_teardown
    return $rc
}

test_unstick_agenda_lists_one_direction_repo_and_counts_the_rest() {
    # Each DIRECTION item is a half-hour plan-features session, so a daily list
    # that itemised all of them promised a sitting nobody could finish.
    _ua_setup
    local rc=0 out
    out=$("$UA_AGENDA" --json 2>/dev/null)
    assert_equal 1 "$(printf '%s' "$out" | "$JQ_BIN" -r '.counts.DIRECTION')" "one direction session per agenda" || rc=1
    assert_equal "no agent/FOCUS.md; focus PR #7 is open; driver repo, 3 approved or proposed issue(s)" \
        "$(_ua_field "$out" direction:acme/engine detail)" \
        "a driver repo is chosen over one with more work, and the detail says why" || rc=1
    assert_contains "$(_ua_more_ids "$out" REVIEW)" "review:acme/engine#7" \
        "the focus PR the detail names takes its own PR route, never a merge from DIRECTION (Grok, PR #41 f2)" || rc=1
    assert_equal null "$(_ua_field "$out" direction:acme/engine age_days)" "never set has no age" || rc=1
    assert_equal "direction:acme/game" "$(_ua_more_ids "$out" DIRECTION)" "the rest are counted" || rc=1
    assert_equal "DIRECTION +1 more repo needs a direction session (one per day): acme/game" \
        "$(_ua_more_line "$out" DIRECTION)" || rc=1
    assert_not_contains "$out" "direction:acme/site" "a decision two days old needs no session" || rc=1
    assert_not_contains "$out" "direction:amarcu/agentic-pipeline" "DIRECTION covers ACTIVE_REPOS only" || rc=1
    assert_equal 65 "$(printf '%s' "$out" | "$JQ_BIN" -r '.minutes')" \
        "the estimate counts one 25-minute session, not one per repo" || rc=1
    _ua_teardown
    return $rc
}

test_unstick_agenda_direction_rotates_through_every_drilled_repo() {
    # One drill a day, and a drilled repo waits one day per drilled repo, so
    # every repo comes round within that many days whatever the pick order.
    # A driven repo is never drilled: its driver's session covers it.
    _ua_setup
    local rc=0 out
    /usr/bin/awk '/^ACTIVE_REPOS=\(/{f=1} f&&/^\)/{print "    \"acme/engine-docs\""; f=0} {print}' "$REPOS_CONF" > "$UA_TMP/conf" \
        && /bin/mv "$UA_TMP/conf" "$REPOS_CONF"
    /bin/mkdir -p "$MOCK_GH_DIR/acme-engine-docs"
    echo '[]' > "$MOCK_GH_DIR/acme-engine-docs/issue-list.json"
    echo '[]' > "$MOCK_GH_DIR/acme-engine-docs/pr-list.json"
    /bin/cat > "$UA_TMP/req/acme-engine-docs.json" <<'JSON'
{"repo": "acme/engine-docs", "status": "ok", "source": "repo", "missing": [], "below_floor": [], "errors": [], "requirements": []}
JSON
    /bin/cat > "$MOCK_GH_DIR/acme-site/contents/agent/FOCUS.md" <<'MD'
## Decisions log
- 2026-09-08 — Three days before the agenda runs.
MD
    out=$("$UA_AGENDA" --json 2>/dev/null)
    assert_contains "$(_ua_more_ids "$out" DIRECTION)" "direction:acme/site" \
        "three drilled repos: a decision three days old is due again" || rc=1
    assert_not_contains "$out" "direction:acme/engine-docs" \
        "a driven repo with no FOCUS.md is covered by its driver's drill" || rc=1
    _ua_teardown
    return $rc
}

test_unstick_agenda_direction_without_a_driver_goes_to_the_most_work() {
    _ua_setup
    local rc=0 out
    /bin/cat > "$REPOS_CONF" <<'CONF'
ACTIVE_REPOS=(
    "acme/game"
    "acme/engine"
    "acme/site"
)
DISPATCH_PER_REPO_MAX=2
CONF
    out=$("$UA_AGENDA" --json 2>/dev/null)
    assert_equal "last Decisions-log entry 2026-09-02; 4 approved or proposed issue(s)" \
        "$(_ua_field "$out" direction:acme/game detail)" \
        "four approved or proposed issues beat three, and only Decisions-log dates count" || rc=1
    assert_equal 9 "$(_ua_field "$out" direction:acme/game age_days)" || rc=1
    assert_equal "direction:acme/engine" "$(_ua_more_ids "$out" DIRECTION)" || rc=1
    _ua_teardown
    return $rc
}

test_unstick_agenda_text_header_and_item_lines() {
    _ua_setup
    local rc=0 out bad
    out=$("$UA_AGENDA" 2>/dev/null)
    assert_equal "AGENDA: 10 items | HOST 1, MERGE 3, BLOCKED 2, REVIEW 2 (+3), APPROVE 1, DIRECTION 1 (+1) | about 65 min | host check: local" \
        "$(printf '%s\n' "$out" | /usr/bin/sed -n 1p)" "header: counts per section, the unlisted rest, the estimate" || rc=1
    bad=$(printf '%s\n' "$out" | /usr/bin/sed 1d | /usr/bin/grep -vE '^(REVIEW|DIRECTION) \+' \
              | /usr/bin/grep -vE '^ *[0-9]+\. [A-Z]+ +[a-z]+/[A-Za-z_.-]+(#[0-9]+)? +unblocks=[0-9]+ +age=([0-9]+d|-) +.*  \[[a-z]+:[a-z]+/[^]]+\]$' || true)
    if [[ -n "$bad" ]]; then
        echo "  FAIL: item lines without repo, unblocks, age and a stable id:"
        printf '%s\n' "$bad" | /usr/bin/sed 's/^/    /'
        rc=1
    fi
    assert_equal "REVIEW +3 other drafts (bootstrap/pipeline PRs): acme/game#52, acme/engine#7, amarcu/agentic-pipeline#40
DIRECTION +1 more repo needs a direction session (one per day): acme/game" \
        "$(printf '%s\n' "$out" | /usr/bin/tail -2)" "the unlisted rest closes the agenda, one line per section" || rc=1
    _ua_teardown
    return $rc
}

test_unstick_agenda_never_calls_a_mutating_gh_subcommand() {
    _ua_setup
    local rc=0 calls bad
    "$UA_AGENDA" --json >/dev/null 2>&1
    "$UA_AGENDA" >/dev/null 2>&1
    calls=$(/bin/cat "$MOCK_GH_LOG" 2>/dev/null)
    if [[ $(printf '%s\n' "$calls" | /usr/bin/grep -c .) -lt 22 ]]; then
        echo "  FAIL: expected every repo's lists and contents reads to be logged, got:"
        printf '%s\n' "$calls" | /usr/bin/sed 's/^/    /'
        rc=1
    fi
    bad=$(printf '%s\n' "$calls" | /usr/bin/grep -vE '^(issue list|pr list|api repos/[^ ]+/contents/[^ ]+) ' || true)
    bad+=$(printf '%s\n' "$calls" | /usr/bin/grep -E '(^| )(-X|--method|-f|-F|--field|--raw-field|--input)( |$)' || true)
    if [[ -n "$bad" ]]; then
        echo "  FAIL: the agenda made a gh call that is not a read:"
        printf '%s\n' "$bad" | /usr/bin/sed 's/^/    /'
        rc=1
    fi
    if [[ -e "$UA_TMP/ssh/argv" ]]; then
        echo "  FAIL: ssh ran without --host"
        rc=1
    fi
    _ua_teardown
    return $rc
}

test_unstick_agenda_checks_the_host_over_ssh_under_the_routine_path() {
    _ua_setup
    local rc=0 out argv
    /bin/cat > "$UA_TMP/ssh/out" <<'JSON'
{"repo": "acme/game", "status": "ok", "missing": [], "errors": [], "requirements": []}
{"repo": "acme/engine", "status": "missing", "source": "repo", "missing": ["../game-engine"], "below_floor": [], "errors": [], "requirements": []}
{"repo": "acme/site", "status": "ok", "missing": [], "errors": [], "requirements": []}
JSON
    out=$("$UA_AGENDA" --host pipeline-host 2>/dev/null)
    argv=$(/bin/cat "$UA_TMP/ssh/argv")
    assert_contains "$(printf '%s\n' "$out" | /usr/bin/sed -n 1p)" "host check: pipeline-host" || rc=1
    assert_contains "$out" "missing: ../game-engine; sitting on 3 approved issue(s)" "the host's answer, not this machine's" || rc=1
    assert_not_contains "$out" "xcodebuild" "the local check did not run" || rc=1
    assert_contains "$argv" "BatchMode=yes" "ssh never prompts" || rc=1
    assert_contains "$argv" "pipeline-host" || rc=1
    assert_contains "$argv" "export PATH=\$HOME/.unity/bin:\$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin;" \
        "check-requirements answers for the routines' PATH" || rc=1
    assert_contains "$argv" "/routines/_run.sh\")\")/../..\" && for r in acme/game acme/engine acme/site; do launchd-runtime/bin/check-requirements \"\$r\" --json; done" || rc=1
    if [[ -e "$UA_TMP/req/calls.log" ]]; then
        echo "  FAIL: the local check-requirements ran although the host answered"
        rc=1
    fi
    _ua_teardown
    return $rc
}

test_unstick_agenda_falls_back_to_local_when_the_host_does_not_answer() {
    _ua_setup
    local rc=0 out
    echo 255 > "$UA_TMP/ssh/rc"
    out=$("$UA_AGENDA" --host pipeline-host 2>/dev/null)
    assert_contains "$(printf '%s\n' "$out" | /usr/bin/sed -n 1p)" "host check: local" || rc=1
    assert_contains "$out" "NOTE: host pipeline-host gave no answer (ssh exit 255" "the fallback says so" || rc=1
    assert_contains "$out" "missing: xcodebuild -version, ../game-engine (template)" "and uses this machine's answer" || rc=1
    assert_contains "$(/bin/cat "$UA_TMP/req/calls.log")" \
        "acme/engine PATH=$HOME/.unity/bin:$HOME/.local/bin:" "under the routines' PATH here too" || rc=1
    _ua_teardown
    return $rc
}

test_unstick_agenda_names_a_failed_repo_and_exits_1() {
    _ua_setup
    local rc=0 out code
    /bin/rm -f "$MOCK_GH_DIR/acme-site/issue-list.json"
    out=$("$UA_AGENDA" 2>/dev/null)
    code=$?
    assert_exit 1 "$code" "a partial agenda is not a complete one" || rc=1
    assert_contains "$out" "ERROR: acme/site: gh issue list exit 1" "the repo it could not read is named" || rc=1
    assert_contains "$out" "[host:acme/engine]" "and the rest of the agenda still prints" || rc=1
    _ua_teardown
    return $rc
}

test_unstick_agenda_minutes_are_the_review_nudges() {
    # The sitting estimate reuses daily-review-nudge's per-item minutes. Two
    # files holding one set of numbers drift unless something holds them equal.
    local rc=0 nudge="$RUNTIME_DIR/prompts/daily-review-nudge.md" agenda="$REPO_ROOT/skills/unstick/scripts/agenda"
    if ! /usr/bin/grep -qF "roughly 2 minutes per item to approve, 5 per draft to mark ready, 5 per PR to merge" "$nudge"; then
        echo "  FAIL: daily-review-nudge.md no longer states 2/5/5 — update MINUTES in the agenda to match"
        rc=1
    fi
    local pair
    for pair in '"APPROVE": 2' '"REVIEW": 5' '"MERGE": 5'; do
        if ! /usr/bin/grep -qF "$pair" "$agenda"; then
            echo "  FAIL: the agenda's MINUTES no longer carries $pair from the nudge"
            rc=1
        fi
    done
    return $rc
}

test_unstick_log_session_appends_one_dated_line_and_never_truncates() {
    _ua_setup
    local rc=0 out code
    export UNSTICK_LOG="$UA_TMP/logs/unstick.log"
    /bin/mkdir -p "$UA_TMP/logs"
    echo "2026-09-10T19:00:00+0000 items=9 unstuck=4 routed=1 skipped=0 remaining=4 host=pipeline-host" > "$UNSTICK_LOG"

    out=$("$UA_LOG_SESSION" "items=13 unstuck=5 routed=2 skipped=1 remaining=5 host=pipeline-host")
    assert_exit 0 $? || rc=1
    assert_contains "$out" "SESSION: " "the appended line is echoed" || rc=1
    "$UA_LOG_SESSION" "items=8 unstuck=8 routed=0 skipped=0 remaining=0 host=local" >/dev/null

    assert_equal 3 "$(/usr/bin/wc -l < "$UNSTICK_LOG" | /usr/bin/tr -d ' ')" "one line per session, earlier lines kept" || rc=1
    assert_equal "2026-09-10T19:00:00+0000 items=9 unstuck=4 routed=1 skipped=0 remaining=4 host=pipeline-host" \
        "$(/usr/bin/sed -n 1p "$UNSTICK_LOG")" "the existing line is untouched" || rc=1
    if ! /usr/bin/sed -n 2p "$UNSTICK_LOG" | /usr/bin/grep -qE '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{4} items=13 '; then
        echo "  FAIL: the appended line is not dated: $(/usr/bin/sed -n 2p "$UNSTICK_LOG")"
        rc=1
    fi

    "$UA_LOG_SESSION" "$(printf 'items=1\nforged=line')" >/dev/null 2>&1
    code=$?
    assert_exit 2 "$code" "a multi-line session is refused" || rc=1
    assert_equal 3 "$(/usr/bin/wc -l < "$UNSTICK_LOG" | /usr/bin/tr -d ' ')" "and nothing was written" || rc=1

    UNSTICK_LOG="$UA_TMP/nowhere/unstick.log" "$UA_LOG_SESSION" "items=1" >/dev/null 2>&1
    code=$?
    assert_exit 3 "$code" "a missing log directory is an error, not created" || rc=1
    if [[ -e "$UA_TMP/nowhere" ]]; then
        echo "  FAIL: log-session created the log directory"
        rc=1
    fi
    _ua_teardown
    return $rc
}
