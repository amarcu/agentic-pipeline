#!/bin/bash
# Tests for triage-repo.sh — the classifier morning-triage's whole digest is
# built from.
#
# The bug that motivated these: there was no `proposed` bucket at all, so every
# issue the agent had proposed and the human had not yet approved was filed as
# `stale` forever. morning-triage's quiet-day halt asks "is anything blocking,
# awaiting approval, or escalated" — a permanently `stale` proposal answered
# none of those, so the halt fired on mornings that had a full approval queue.
# The assertions below therefore check WHICH BUCKET each item lands in, not
# that a block was printed.
#
# Determinism is the second thing under test. Classification used to be prose
# the model re-derived per run; the same seven issues could come back bucketed
# differently on two consecutive mornings. `repeat_runs_are_byte_identical`
# is what stops that coming back.

_tr_setup() {
    TR_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-triage.XXXXXX)
    export MOCK_GH_DIR="$TR_TMP/gh"
    export PATH="$FIXTURES_DIR/mock-gh:$PATH"
    # The mock runs the caller's --jq in a separate process, so it needs the
    # interpreter the suite resolved rather than whatever `jq` PATH finds.
    export JQ_BIN
    /bin/mkdir -p "$MOCK_GH_DIR"

    TR_SCRIPT="$REPO_ROOT/skills/triage-repo/scripts/triage-repo.sh"

    # One issue per bucket, plus the two the `proposed` rule exists for:
    # #10 is proposed-and-unapproved (must not read as stale however old it is)
    # and #6 is proposed-and-approved (already through the gate, so not
    # `proposed`, and still not stale). #7 is the genuine stale item that
    # proves the bucket is not simply unreachable.
    /bin/cat > "$MOCK_GH_DIR/issue-list.json" <<'JSON'
[
  {"number": 12, "title": "Loader crashes on boot", "labels": [{"name": "bug"}, {"name": "blocker"}],
   "createdAt": "2026-08-20T09:00:00Z", "updatedAt": "2026-08-30T09:00:00Z",
   "url": "https://github.com/acme/testrepo/issues/12"},
  {"number": 11, "title": "Rotate the deploy key", "labels": [{"name": "needs-approval"}],
   "createdAt": "2026-08-25T09:00:00Z", "updatedAt": "2026-08-31T09:00:00Z",
   "url": "https://github.com/acme/testrepo/issues/11"},
  {"number": 10, "title": "Cache the manifest parse", "labels": [{"name": "proposed"}],
   "createdAt": "2026-06-01T09:00:00Z", "updatedAt": "2026-06-02T09:00:00Z",
   "url": "https://github.com/acme/testrepo/issues/10"},
  {"number": 9, "title": "Document the gate", "labels": [{"name": "documentation"}],
   "createdAt": "2026-08-28T09:00:00Z", "updatedAt": "2026-08-29T09:00:00Z",
   "url": "https://github.com/acme/testrepo/issues/9"},
  {"number": 8, "title": "Tighten the retry budget", "labels": [],
   "createdAt": "2026-09-01T09:00:00Z", "updatedAt": "2026-09-02T09:00:00Z",
   "url": "https://github.com/acme/testrepo/issues/8"},
  {"number": 7, "title": "Old idea nobody picked up", "labels": [],
   "createdAt": "2026-01-01T09:00:00Z", "updatedAt": "2026-01-02T09:00:00Z",
   "url": "https://github.com/acme/testrepo/issues/7"},
  {"number": 6, "title": "Approved but not yet dispatched", "labels": [{"name": "proposed"}, {"name": "approved"}],
   "createdAt": "2026-01-05T09:00:00Z", "updatedAt": "2026-01-06T09:00:00Z",
   "url": "https://github.com/acme/testrepo/issues/6"}
]
JSON

    # One PR per bucket. #21 is the pipeline's own WIP (agent head branch),
    # #19 a draft nobody has touched since January, #18 a fresh human draft.
    /bin/cat > "$MOCK_GH_DIR/pr-list.json" <<'JSON'
[
  {"number": 21, "title": "Parse the manifest once", "labels": [], "isDraft": true,
   "headRefName": "task/issue-10", "statusCheckRollup": [{"conclusion": "SUCCESS"}],
   "createdAt": "2026-09-01T09:00:00Z", "updatedAt": "2026-09-02T09:00:00Z",
   "url": "https://github.com/acme/testrepo/pull/21"},
  {"number": 20, "title": "Bump the engine", "labels": [{"name": "chore"}], "isDraft": false,
   "headRefName": "chore/engine", "statusCheckRollup": [{"conclusion": "FAILURE"}, {"conclusion": "SUCCESS"}],
   "createdAt": "2026-08-30T09:00:00Z", "updatedAt": "2026-09-01T09:00:00Z",
   "url": "https://github.com/acme/testrepo/pull/20"},
  {"number": 19, "title": "Half-finished spike", "labels": [], "isDraft": true,
   "headRefName": "spike/lighting", "statusCheckRollup": [],
   "createdAt": "2026-01-02T09:00:00Z", "updatedAt": "2026-01-03T09:00:00Z",
   "url": "https://github.com/acme/testrepo/pull/19"},
  {"number": 18, "title": "Fresh human draft", "labels": [], "isDraft": true,
   "headRefName": "wip/notes", "statusCheckRollup": null,
   "createdAt": "2026-09-02T09:00:00Z", "updatedAt": "2026-09-02T12:00:00Z",
   "url": "https://github.com/acme/testrepo/pull/18"}
]
JSON
    _tr_age_fixtures "$MOCK_GH_DIR/issue-list.json" "$MOCK_GH_DIR/pr-list.json"
}

# The fixtures were written on 2026-09-03, and their ages are the point: #7 is
# stale because it was last touched months before that day, #1 is fresh because
# it was touched the week before. triage-repo.sh measures age against the wall
# clock, so a fixed timestamp drifts one day older every day, and by
# 2026-09-26 the fresh items had crossed the 14-day line and the suite failed
# with nothing changed. Shifting every timestamp forward by the days elapsed
# since then keeps each item exactly as old as it was written to be.
_TR_WRITTEN="2026-09-03"

_tr_age_fixtures() {
    /usr/bin/python3 - "$_TR_WRITTEN" "$@" <<'PY'
import datetime, os, re, sys
written = datetime.date.fromisoformat(sys.argv[1])
shift = datetime.timedelta(days=(datetime.datetime.utcnow().date() - written).days)
stamp = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
def move(match):
    t = datetime.datetime.strptime(match.group(0), "%Y-%m-%dT%H:%M:%SZ")
    return (t + shift).strftime("%Y-%m-%dT%H:%M:%SZ")
for path in sys.argv[2:]:
    if os.path.exists(path):
        text = open(path).read()
        open(path, "w").write(stamp.sub(move, text))
PY
}

_tr_teardown() {
    /bin/rm -rf "$TR_TMP"
}

# The bucket heading an item sits under. Issue and PR numbers in the fixture
# are disjoint, so the first match is the right one.
_tr_bucket_of() {
    printf '%s\n' "$1" | /usr/bin/awk -v want="- #$2 " '
        /^  [a-z-]+:$/  { b = $1; sub(/:$/, "", b); next }
        index($0, want) == 5 { print b; exit }
    '
}

test_triage_repo_buckets_every_item_by_precedence() {
    _tr_setup
    local out rc=0
    out=$("$TR_SCRIPT" acme/testrepo 14 2>/dev/null)

    assert_equal blocking       "$(_tr_bucket_of "$out" 12)" "a blocker label outranks everything" || rc=1
    assert_equal needs-approval "$(_tr_bucket_of "$out" 11)" "needs-approval outranks proposed" || rc=1
    assert_equal proposed       "$(_tr_bucket_of "$out" 10)" "an unapproved proposal is proposed" || rc=1
    assert_equal informational  "$(_tr_bucket_of "$out" 9)"  "documentation is informational" || rc=1
    assert_equal active         "$(_tr_bucket_of "$out" 8)"  "recently touched and unlabelled is active" || rc=1
    assert_equal stale          "$(_tr_bucket_of "$out" 7)"  "untouched and unlabelled is stale" || rc=1

    assert_equal draft-agent "$(_tr_bucket_of "$out" 21)" "a draft on an agent branch is the pipeline's" || rc=1
    assert_equal ready       "$(_tr_bucket_of "$out" 20)" "a non-draft PR is ready" || rc=1
    assert_equal stale       "$(_tr_bucket_of "$out" 19)" "an untouched human draft is stale" || rc=1
    assert_equal draft       "$(_tr_bucket_of "$out" 18)" "a fresh human draft is just a draft" || rc=1

    _tr_teardown
    return $rc
}

test_triage_repo_never_files_a_proposal_as_stale() {
    # TRIAGE-REPO-1. #10 has not been touched in three months and #6 in eight,
    # so both are well past any cutoff — the label is what keeps them out of
    # `stale`, and morning-triage's quiet-day halt depends on it.
    _tr_setup
    local out rc=0
    out=$("$TR_SCRIPT" acme/testrepo 14 2>/dev/null)

    assert_equal proposed "$(_tr_bucket_of "$out" 10)" \
        "an unapproved proposal is never stale, however old" || rc=1
    assert_equal active "$(_tr_bucket_of "$out" 6)" \
        "an approved proposal is never stale either" || rc=1
    assert_contains "$out" "stale=1" "exactly one issue is genuinely stale" || rc=1

    _tr_teardown
    return $rc
}

test_triage_repo_ends_every_item_line_with_its_labels() {
    # TRIAGE-REPO-2. morning-triage's escalation gate is label-driven, and the
    # v1 block carried no labels at all — the digest could name a blocker it
    # could not then evidence.
    _tr_setup
    local out rc=0 bad
    out=$("$TR_SCRIPT" acme/testrepo 14 2>/dev/null)

    bad=$(printf '%s\n' "$out" | /usr/bin/grep -- '    - #' | /usr/bin/grep -v 'labels=\[.*\]$' || true)
    if [[ -n "$bad" ]]; then
        echo "  FAIL: item lines that do not end in labels=[…]:"
        printf '%s\n' "$bad" | /usr/bin/sed 's/^/    /'
        rc=1
    fi
    assert_contains "$out" "labels=[blocker,bug]" "labels are listed, sorted" || rc=1
    assert_contains "$out" "labels=[]" "an unlabelled item says so rather than omitting the field" || rc=1

    _tr_teardown
    return $rc
}

test_triage_repo_declares_its_format_and_precedence() {
    _tr_setup
    local out rc=0
    out=$("$TR_SCRIPT" acme/testrepo 14 2>/dev/null)

    assert_equal "REPO: acme/testrepo" "$(printf '%s\n' "$out" | /usr/bin/sed -n 1p)" \
        "first line names the repo" || rc=1
    assert_equal "FORMAT: triage-repo/2" "$(printf '%s\n' "$out" | /usr/bin/sed -n 2p)" \
        "second line versions the format a consumer parses" || rc=1
    assert_contains "$out" "Scanned: " "the block is timestamped" || rc=1
    assert_contains "$out" "Stale-days: 14" "and states the threshold it used" || rc=1
    assert_contains "$out" \
        "Precedence-issues: blocking > needs-approval > proposed > informational > active > stale (first match wins)" \
        "issue precedence is stated in the block, once" || rc=1
    assert_contains "$out" \
        "Precedence-prs: draft-agent > ready > stale > draft (first match wins)" \
        "so is PR precedence" || rc=1

    _tr_teardown
    return $rc
}

test_triage_repo_repeat_runs_are_byte_identical() {
    # The whole reason the classifier moved out of prose. Only the scan
    # timestamp may differ between two runs over the same data.
    _tr_setup
    local first second rc=0
    first=$("$TR_SCRIPT" acme/testrepo 14 2>/dev/null | /usr/bin/sed 's/^Scanned: .*/Scanned: NORMALISED/')
    second=$("$TR_SCRIPT" acme/testrepo 14 2>/dev/null | /usr/bin/sed 's/^Scanned: .*/Scanned: NORMALISED/')

    if [[ "$first" != "$second" ]]; then
        echo "  FAIL: two runs over identical data disagree:"
        /usr/bin/diff <(printf '%s\n' "$first") <(printf '%s\n' "$second") | /usr/bin/sed 's/^/    /'
        rc=1
    fi

    _tr_teardown
    return $rc
}

test_triage_repo_honours_the_days_stale_argument() {
    _tr_setup
    local out rc=0
    out=$("$TR_SCRIPT" acme/testrepo 400 2>/dev/null)

    assert_contains "$out" "Stale-days: 400" "the threshold is reported back" || rc=1
    assert_equal active "$(_tr_bucket_of "$out" 7)" \
        "a wider window moves the stale issue into active" || rc=1
    assert_equal draft "$(_tr_bucket_of "$out" 19)" \
        "and the stale draft back to draft" || rc=1

    _tr_teardown
    return $rc
}

test_triage_repo_reports_a_gh_failure_as_an_error_block() {
    # A repo that is unreachable at 04:10 costs its own block, never the
    # routine — morning-triage has twelve more repos to scan after it.
    _tr_setup
    /bin/rm -f "$MOCK_GH_DIR/issue-list.json"

    local out rc=0
    out=$("$TR_SCRIPT" acme/testrepo 14 2>/dev/null)
    assert_exit 0 $? "a gh failure still exits 0" || rc=1
    assert_contains "$out" "REPO: acme/testrepo" "the block still names the repo" || rc=1
    assert_contains "$out" "FORMAT: triage-repo/2" "and still versions itself" || rc=1
    assert_contains "$out" "ERROR: gh issue list failed" "the failure is in-band" || rc=1
    assert_not_contains "$out" "ISSUES (" "no counts are invented for a repo that never answered" || rc=1

    _tr_teardown
    return $rc
}

test_triage_repo_reports_a_missing_gh_as_an_error_block() {
    _tr_setup
    local out rc=0
    out=$(PATH=/usr/bin:/bin "$TR_SCRIPT" acme/testrepo 14 2>/dev/null)
    assert_exit 0 $? "no gh on PATH still exits 0" || rc=1
    assert_contains "$out" "ERROR: gh CLI not on PATH" "and says which prerequisite is missing" || rc=1

    _tr_teardown
    return $rc
}

test_triage_repo_stderr_line_counts_what_it_returned() {
    _tr_setup
    local err rc=0
    err=$("$TR_SCRIPT" acme/testrepo 14 2>&1 >/dev/null)

    assert_equal "triage-repo: acme/testrepo issues=7 prs=4 gh_calls=2" "$err" \
        "one stderr line, and it is the audit line" || rc=1

    _tr_teardown
    return $rc
}

test_triage_repo_accepts_both_days_stale_spellings() {
    # SKILL.md documents `--days-stale <N>` to a human; morning-triage passes
    # the number positionally, once per repo. Both have to mean the same thing
    # or one of the two callers is silently triaging at the default window.
    _tr_setup
    local rc=0

    assert_contains "$("$TR_SCRIPT" acme/testrepo 2>/dev/null)" "Stale-days: 14" \
        "no argument uses the default" || rc=1
    assert_contains "$("$TR_SCRIPT" acme/testrepo 400 2>/dev/null)" "Stale-days: 400" \
        "the bare positional morning-triage passes" || rc=1
    assert_contains "$("$TR_SCRIPT" acme/testrepo --days-stale 400 2>/dev/null)" "Stale-days: 400" \
        "the flag SKILL.md documents" || rc=1

    _tr_teardown
    return $rc
}

test_triage_repo_refuses_unusable_arguments() {
    # Exit 2 is the caller's bug, deliberately distinct from the exit 0 a repo
    # that is merely down gets: morning-triage must not paper over a mistake in
    # its own scan loop. An argument this script does not read is refused
    # rather than ignored — silently dropping one is how a caller comes to
    # believe it set a window it never set.
    _tr_setup
    local rc=0

    "$TR_SCRIPT" notarepo > /dev/null 2>&1
    assert_exit 2 $? "a repo without an owner is refused" || rc=1
    "$TR_SCRIPT" acme/testrepo abc > /dev/null 2>&1
    assert_exit 2 $? "a non-numeric days-stale is refused" || rc=1
    "$TR_SCRIPT" acme/testrepo 30 extra > /dev/null 2>&1
    assert_exit 2 $? "a third bare word is refused" || rc=1
    "$TR_SCRIPT" acme/testrepo --days-stale > /dev/null 2>&1
    assert_exit 2 $? "the flag without its value is refused" || rc=1
    "$TR_SCRIPT" acme/testrepo --bogus > /dev/null 2>&1
    assert_exit 2 $? "an unknown flag is refused" || rc=1
    "$TR_SCRIPT" acme/testrepo 30 --days-stale 40 > /dev/null 2>&1
    assert_exit 2 $? "both spellings at once is refused" || rc=1

    _tr_teardown
    return $rc
}

test_triage_repo_strips_a_tab_out_of_a_title() {
    # A tab separates the bucket from the rendered line, so a tab inside a
    # title lands inside that line. Bucketing survives it — the field split
    # ends at the FIRST tab, which is the separator — but the block is a
    # machine-read format, and an item line carrying a stray tab corrupts it
    # for anything downstream that splits on one.
    _tr_setup
    /usr/bin/python3 -c '
import json, sys
json.dump([{"number": 12, "title": "Loader\tcrashes on boot",
            "labels": [{"name": "blocker"}],
            "createdAt": "2026-08-20T09:00:00Z", "updatedAt": "2026-08-30T09:00:00Z",
            "url": "https://github.com/acme/testrepo/issues/12"}],
          open(sys.argv[1], "w"))
' "$MOCK_GH_DIR/issue-list.json"
    _tr_age_fixtures "$MOCK_GH_DIR/issue-list.json"

    local out rc=0
    out=$("$TR_SCRIPT" acme/testrepo 14 2>/dev/null)

    assert_equal blocking "$(_tr_bucket_of "$out" 12)" "the item still buckets" || rc=1
    assert_contains "$out" "ISSUES (1): blocking=1" "and still counts" || rc=1
    assert_contains "$out" "- #12 Loader crashes on boot [age=" "the tab became a space" || rc=1
    if printf '%s\n' "$out" \
        | /usr/bin/awk 'index($0, "\t") { found = 1 } END { exit(found ? 0 : 1) }'; then
        echo "  FAIL: a literal tab reached the block"
        rc=1
    fi

    _tr_teardown
    return $rc
}
