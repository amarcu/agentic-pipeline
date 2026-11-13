#!/bin/bash
# Tests for pr-review-bundle — the isolated context review-pr reads.
#
# The bug that motivated these: acceptance-criteria.md was built from the
# `body` of closingIssuesReferences, a field gh 2.92 does not return, so every
# bundle ever built carried the "(issue body empty)" placeholder and no review
# ever saw a criterion. Nothing failed loudly, which is exactly why the
# assertions below check the CONTENT of the file rather than its existence.

# Isolated environment: a temp dir, a mock gh on PATH, and a repos.conf whose
# map points at a throwaway git repo the src/ export can archive from.
#
# These exports need no matching restore in _prb_teardown, and adding one would
# be misleading about where the isolation comes from: run_test invokes every
# test as `( "$test_fn" )`, so each gets its own subshell and nothing it exports
# outlives the call. setup_run_env exports CLAUDE_CLI and TELEGRAM_API_URL on
# the same guarantee. test_mock_gh_path_cannot_leak_between_tests pins it.
_prb_setup() {
    PRB_TMP=$(/usr/bin/mktemp -d /tmp/agentic-test-prb.XXXXXX)
    export MOCK_GH_DIR="$PRB_TMP/gh"
    export PATH="$FIXTURES_DIR/mock-gh:$PATH"
    export REPOS_CONF="$PRB_TMP/repos.conf"
    PRB_OUT="$PRB_TMP/bundle"
    /bin/mkdir -p "$MOCK_GH_DIR"

    PRB_REPO="$PRB_TMP/checkout"
    /bin/mkdir -p "$PRB_REPO/game"
    printf 'class Player {}\n' > "$PRB_REPO/game/Player.cs"
    printf 'class Enemy {}\n' > "$PRB_REPO/game/Enemy.cs"
    printf '# design\n' > "$PRB_REPO/docs-design.md"
    /usr/bin/git -C "$PRB_REPO" init -q -b main
    /usr/bin/git -C "$PRB_REPO" config user.email "test@example.com"
    /usr/bin/git -C "$PRB_REPO" config user.name "test"
    /usr/bin/git -C "$PRB_REPO" add game/Player.cs game/Enemy.cs docs-design.md
    /usr/bin/git -C "$PRB_REPO" -c commit.gpgsign=false commit -qm "fixture head"
    PRB_SHA=$(/usr/bin/git -C "$PRB_REPO" rev-parse HEAD)

    /bin/cat > "$REPOS_CONF" <<EOF
get_repo_path() {
    case "\$1" in
        acme/testrepo) echo "$PRB_REPO" ;;
        *)               echo "" ;;
    esac
}
EOF

    # The PR: open, one changed file, closing issue #12 unless a test rewrites it.
    /bin/cat > "$MOCK_GH_DIR/pr-view.json" <<EOF
{"number": 7, "state": "OPEN", "isDraft": true, "headRefName": "task/issue-12",
 "headRefOid": "$PRB_SHA", "baseRefName": "main", "changedFiles": 1,
 "closingIssuesReferences": [{"number": 12}]}
EOF
    /bin/cat > "$MOCK_GH_DIR/diff.patch" <<'EOF'
diff --git a/game/Player.cs b/game/Player.cs
--- a/game/Player.cs
+++ b/game/Player.cs
@@ -1 +1,2 @@
 class Player {}
+// changed
EOF
    echo '[{"filename": "game/Player.cs", "status": "modified"}]' > "$MOCK_GH_DIR/files.json"
    printf '%s\n' game/Player.cs game/Enemy.cs docs-design.md > "$MOCK_GH_DIR/tree-paths.txt"
}

_prb_teardown() {
    /bin/rm -rf "$PRB_TMP"
}

# An issue body with the criteria section wrapped in the two sections that must
# never reach the reviewer: context above, and the implementation plan that
# propose-tasks is about to start writing below.
_prb_issue_with_plan() {
    /usr/bin/python3 -c '
import json, sys
body = """## Context
The loader reads DECOY_CONTEXT_MARKER from disk on every frame.

## Acceptance criteria
- [ ] The manifest is parsed once at startup
- [ ] A malformed manifest fails loudly

## Implementation plan
1. Cache the parse in DECOY_PLAN_MARKER
2. Add a regression test
"""
json.dump({"title": "Parse the manifest once", "body": body}, open(sys.argv[1], "w"))
' "$MOCK_GH_DIR/issue-12.json"
}

test_pr_review_bundle_writes_only_the_criteria_section() {
    _prb_setup
    _prb_issue_with_plan

    local out rc=0
    out=$("$RUNTIME_DIR/bin/pr-review-bundle" acme/testrepo 7 "$PRB_OUT" 2>&1)
    assert_exit 0 $? "clean bundle exits 0" || rc=1

    local criteria
    criteria=$(/bin/cat "$PRB_OUT/acceptance-criteria.md")
    assert_contains "$criteria" "# Acceptance criteria — issue #12: Parse the manifest once" \
        "criteria file is titled with the issue number and title" || rc=1
    assert_contains "$criteria" "The manifest is parsed once at startup" \
        "the criteria themselves are present" || rc=1
    assert_not_contains "$criteria" "DECOY_PLAN_MARKER" \
        "the implementation plan must never reach the reviewer" || rc=1
    assert_not_contains "$criteria" "Implementation plan" \
        "not even the plan heading" || rc=1
    assert_not_contains "$criteria" "DECOY_CONTEXT_MARKER" \
        "no section above the criteria either" || rc=1
    assert_contains "$out" "criteria:" "summary reports the criteria size" || rc=1

    _prb_teardown
    return $rc
}

test_pr_review_bundle_flags_an_issue_with_no_criteria_section() {
    _prb_setup
    /usr/bin/python3 -c '
import json, sys
json.dump({"title": "Tidy the loader", "body": "Just a paragraph, no headings."},
          open(sys.argv[1], "w"))
' "$MOCK_GH_DIR/issue-12.json"

    local rc=0
    "$RUNTIME_DIR/bin/pr-review-bundle" acme/testrepo 7 "$PRB_OUT" > /dev/null 2>&1
    assert_exit 6 $? "issue without a criteria section exits 6" || rc=1

    local criteria
    criteria=$(/bin/cat "$PRB_OUT/acceptance-criteria.md")
    assert_contains "$criteria" 'Issue #12 "Tidy the loader" has no "## Acceptance criteria" section' \
        "sentinel names the case" || rc=1
    assert_not_contains "$criteria" "Just a paragraph" \
        "the body is never written, not even when there is no section" || rc=1
    assert_equal 1 "$(/usr/bin/wc -l < "$PRB_OUT/acceptance-criteria.md" | tr -d ' ')" \
        "sentinel is one line" || rc=1
    assert_file_exists "$PRB_OUT/diff.patch" "the rest of the bundle is still written" || rc=1

    _prb_teardown
    return $rc
}

test_pr_review_bundle_flags_a_pr_that_closes_no_issue() {
    _prb_setup
    /bin/cat > "$MOCK_GH_DIR/pr-view.json" <<EOF
{"number": 7, "state": "OPEN", "isDraft": true, "headRefName": "task/issue-12",
 "headRefOid": "$PRB_SHA", "baseRefName": "main", "changedFiles": 1,
 "closingIssuesReferences": []}
EOF

    local rc=0
    "$RUNTIME_DIR/bin/pr-review-bundle" acme/testrepo 7 "$PRB_OUT" > /dev/null 2>&1
    assert_exit 5 $? "a PR closing no issue exits 5" || rc=1
    assert_contains "$(/bin/cat "$PRB_OUT/acceptance-criteria.md")" \
        "This PR closes no issue" "sentinel names the case" || rc=1
    assert_file_exists "$PRB_OUT/src/game/Player.cs" "the bundle is complete regardless" || rc=1

    _prb_teardown
    return $rc
}

test_pr_review_bundle_exports_the_source_tree_at_the_head_sha() {
    _prb_setup
    _prb_issue_with_plan

    local rc=0
    "$RUNTIME_DIR/bin/pr-review-bundle" acme/testrepo 7 "$PRB_OUT" > /dev/null 2>&1 || rc=1

    assert_file_exists "$PRB_OUT/src/game/Player.cs" "src/ carries the archived tree" || rc=1
    assert_equal "class Player {}" "$(/bin/cat "$PRB_OUT/src/game/Player.cs")" \
        "with the content at the recorded SHA" || rc=1
    if [[ -e "$PRB_OUT/src/.git" ]]; then
        echo "  FAIL: src/ must be a plain tree with no .git"
        rc=1
    fi
    assert_equal "$(cd "$PRB_REPO" && pwd)" "$(cd "$(/bin/cat "$PRB_OUT/source-repo")" && pwd)" \
        "source-repo names the checkout, so a gate can find its warm cache" || rc=1
    assert_equal "$PRB_SHA" "$("$JQ_BIN" -r '.bundle.head_sha' "$PRB_OUT/meta.json")" \
        "manifest records head_sha" || rc=1
    assert_equal "$PRB_OUT/src" "$("$JQ_BIN" -r '.bundle.src' "$PRB_OUT/meta.json")" \
        "manifest records the src path" || rc=1

    _prb_teardown
    return $rc
}

test_pr_review_bundle_links_the_sibling_checkouts_the_manifest_names() {
    # GameTwo's gate includes game-engine through ../game-engine; from a bare src/ it
    # failed every review on 'game-engine/Platform.h' file not found (#162).
    _prb_setup
    _prb_issue_with_plan
    /bin/mkdir -p "$PRB_TMP/engine" "$PRB_REPO/agent"
    printf 'engine\n' > "$PRB_TMP/engine/Platform.h"
    printf 'path ../engine   # hint: clone it alongside\npath ../absent\ncmd git\n' > "$PRB_REPO/agent/requirements.conf"

    local rc=0 out
    out=$("$RUNTIME_DIR/bin/pr-review-bundle" acme/testrepo 7 "$PRB_OUT" 2>&1)
    assert_equal "engine" "$(/bin/cat "$PRB_OUT/src/../engine/Platform.h" 2>/dev/null)" \
        "../engine resolves from src/ as it does in the checkout" || rc=1
    if [[ -e "$PRB_OUT/absent" ]]; then
        echo "  FAIL: a sibling missing on this host must not be linked"
        rc=1
    fi
    assert_contains "$out" "siblings:  engine (linked beside src/)" "the summary names what was linked" || rc=1

    "$RUNTIME_DIR/bin/pr-review-bundle" acme/testrepo 7 "$PRB_OUT" > /dev/null 2>&1 || rc=1
    assert_equal "engine" "$(/bin/cat "$PRB_OUT/engine/Platform.h" 2>/dev/null)" "a round-2 rebuild keeps the link" || rc=1

    _prb_teardown
    return $rc
}

test_pr_review_bundle_skips_src_for_a_repo_with_no_path_mapping() {
    _prb_setup
    _prb_issue_with_plan

    local rc=0
    # Same fixture repos.conf, a repo name it does not map.
    "$RUNTIME_DIR/bin/pr-review-bundle" acme/unmapped 7 "$PRB_OUT" > /dev/null 2>&1
    assert_exit 0 $? "an unmapped repo is not a failure" || rc=1
    assert_equal "null" "$("$JQ_BIN" -r '.bundle.src' "$PRB_OUT/meta.json")" \
        "manifest records no src" || rc=1
    assert_contains "$("$JQ_BIN" -r '.bundle.src_note' "$PRB_OUT/meta.json")" \
        "not in repos.conf's get_repo_path map" "manifest says why" || rc=1
    if [[ -e "$PRB_OUT/src" || -e "$PRB_OUT/source-repo" ]]; then
        echo "  FAIL: no src/ or source-repo should exist when the repo cannot be resolved"
        rc=1
    fi

    _prb_teardown
    return $rc
}

test_pr_review_bundle_tree_is_bounded_to_the_touched_directories() {
    _prb_setup
    _prb_issue_with_plan

    local rc=0
    "$RUNTIME_DIR/bin/pr-review-bundle" acme/testrepo 7 "$PRB_OUT" > /dev/null 2>&1 || rc=1

    local tree
    tree=$(/bin/cat "$PRB_OUT/tree.txt")
    assert_contains "$tree" "game/" "the touched directory is listed" || rc=1
    assert_contains "$tree" "* Player.cs" "the changed file is marked" || rc=1
    assert_contains "$tree" "Enemy.cs" "so are its immediate neighbours" || rc=1
    assert_not_contains "$tree" "docs-design.md" \
        "paths outside the touched directories are not" || rc=1

    _prb_teardown
    return $rc
}

test_pr_review_bundle_tree_is_capped_and_marked_truncated() {
    _prb_setup
    _prb_issue_with_plan
    # A directory far larger than the cap: the recursive listing this replaced
    # was 427 KB (5,649 paths, ~107k tokens) on StarBonk for any diff at all.
    /usr/bin/python3 -c '
import sys
open(sys.argv[1], "w").write("".join("game/File%d.cs\n" % i for i in range(500)))
' "$MOCK_GH_DIR/tree-paths.txt"

    local rc=0
    "$RUNTIME_DIR/bin/pr-review-bundle" acme/testrepo 7 "$PRB_OUT" > /dev/null 2>&1 || rc=1

    local lines
    lines=$(/usr/bin/wc -l < "$PRB_OUT/tree.txt" | tr -d ' ')
    # 3 header lines + 400 capped body lines + the marker
    assert_equal 404 "$lines" "tree.txt is capped" || rc=1
    assert_contains "$(/usr/bin/tail -1 "$PRB_OUT/tree.txt")" "(truncated)" \
        "and says so on the last line" || rc=1

    _prb_teardown
    return $rc
}

test_mock_gh_path_cannot_leak_between_tests() {
    # Copilot read _prb_setup's `export PATH` as making the suite order-
    # dependent (PR #13). It is not, because run_test subshells every test —
    # but that guarantee lives in helpers.sh, one file away from the exports
    # that rely on it, so assert it here rather than trusting it silently.
    _prb_leak_probe() { export PRB_LEAK_SENTINEL=leaked; }
    run_test _prb_leak_probe > /dev/null 2>&1

    if [[ -n "${PRB_LEAK_SENTINEL:-}" ]]; then
        echo "  FAIL: run_test no longer isolates tests — an export outlived one,"
        echo "        so this file's mock gh would shadow gh for every test after it"
        return 1
    fi
    return 0
}

# A diff that touches the pipeline itself. Everything else about the fixture
# stays as _prb_setup left it.
_prb_pipeline_diff() {
    /bin/cat > "$MOCK_GH_DIR/diff.patch" <<'PATCH'
diff --git a/launchd-runtime/bin/pr-review-bundle b/launchd-runtime/bin/pr-review-bundle
--- a/launchd-runtime/bin/pr-review-bundle
+++ b/launchd-runtime/bin/pr-review-bundle
@@ -1 +1,2 @@
 #!/bin/bash
+# changed
PATCH
}

test_pr_review_bundle_still_refuses_a_pipeline_diff_by_default() {
    _prb_setup
    _prb_issue_with_plan
    _prb_pipeline_diff

    local rc=0 out
    out=$("$RUNTIME_DIR/bin/pr-review-bundle" acme/testrepo 7 "$PRB_OUT" 2>&1)
    assert_exit 4 $? "a pipeline diff is still exit 4 without the flag" || rc=1
    assert_contains "$out" "modifies the pipeline itself — escalate, do not review" \
        "with the wording review-pr Step 2 keys on" || rc=1
    if [[ -e "$PRB_OUT/src" || -e "$PRB_OUT/pipeline-notice.md" ]]; then
        echo "  FAIL: the refusal must stop before the rest of the bundle is built"
        rc=1
    fi

    _prb_teardown
    return $rc
}

test_pr_review_bundle_allows_a_pipeline_diff_on_request_and_says_so() {
    # The opt-in exists for cursor-review, whose reviewer is not the model that
    # wrote the pipeline. The bundle records that fact rather than hiding it,
    # so a Claude reviewer handed this directory can still tell it must stop.
    _prb_setup
    _prb_issue_with_plan
    _prb_pipeline_diff

    local rc=0 out
    out=$("$RUNTIME_DIR/bin/pr-review-bundle" acme/testrepo 7 "$PRB_OUT" --allow-pipeline 2>&1)
    assert_exit 0 $? "with the flag it builds a complete bundle" || rc=1
    assert_file_exists "$PRB_OUT/src/game/Player.cs" "including the source tree" || rc=1
    assert_contains "$out" "bundled under --allow-pipeline" "the summary says what happened" || rc=1

    assert_equal "true" "$("$JQ_BIN" -r '.bundle.pipeline_diff' "$PRB_OUT/meta.json")" \
        "the manifest records that this PR modifies the pipeline" || rc=1
    assert_contains "$("$JQ_BIN" -r '.bundle.pipeline_note' "$PRB_OUT/meta.json")" \
        "a Claude reviewer escalates" "and what a Claude reviewer must do about it" || rc=1

    local notice
    notice=$(/bin/cat "$PRB_OUT/pipeline-notice.md")
    assert_contains "$notice" "modifies the pipeline itself" "the notice names the situation" || rc=1
    assert_contains "$notice" "non-Claude reviewer is permitted" "who may review it" || rc=1
    assert_contains "$notice" "A Claude reviewer must not" "and who may not" || rc=1

    _prb_teardown
    return $rc
}

test_pr_review_bundle_treats_a_claude_md_diff_as_a_pipeline_change() {
    # CLAUDE.md declares the verify gate, and cursor-review executes that
    # gate's command. A PR editing it changes what the reviewer runs, so it is
    # a pipeline change however product-shaped the rest of the diff looks —
    # before this, such a diff needed no opt-in and recorded no notice.
    _prb_setup
    _prb_issue_with_plan
    /bin/cat > "$MOCK_GH_DIR/diff.patch" <<'PATCH'
diff --git a/CLAUDE.md b/CLAUDE.md
--- a/CLAUDE.md
+++ b/CLAUDE.md
@@ -1 +1,2 @@
 # Context
+Anything at all.
PATCH

    local rc=0 out
    out=$("$RUNTIME_DIR/bin/pr-review-bundle" acme/testrepo 7 "$PRB_OUT" 2>&1)
    assert_exit 4 $? "a CLAUDE.md-only diff is refused like any pipeline diff" || rc=1
    assert_contains "$out" "modifies the pipeline itself" "with the same wording" || rc=1

    out=$("$RUNTIME_DIR/bin/pr-review-bundle" acme/testrepo 7 "$PRB_OUT" --allow-pipeline 2>&1)
    assert_exit 0 $? "and bundles under the opt-in" || rc=1
    assert_equal "true" "$("$JQ_BIN" -r '.bundle.pipeline_diff' "$PRB_OUT/meta.json")" \
        "recording that it is one" || rc=1
    assert_file_exists "$PRB_OUT/pipeline-notice.md" "with the notice written" || rc=1

    _prb_teardown
    return $rc
}

test_pr_review_bundle_does_not_flag_a_file_merely_named_like_claude_md() {
    # The CLAUDE.md branch is the only anchored one in that alternation, so it
    # must not swallow a neighbour with a longer name.
    _prb_setup
    _prb_issue_with_plan
    /bin/cat > "$MOCK_GH_DIR/diff.patch" <<'PATCH'
diff --git a/docs/MYCLAUDE.md.bak b/docs/MYCLAUDE.md.bak
--- a/docs/MYCLAUDE.md.bak
+++ b/docs/MYCLAUDE.md.bak
@@ -1 +1,2 @@
 notes
+more notes
PATCH
    echo '[{"filename": "docs/MYCLAUDE.md.bak", "status": "modified"}]' > "$MOCK_GH_DIR/files.json"

    local rc=0
    "$RUNTIME_DIR/bin/pr-review-bundle" acme/testrepo 7 "$PRB_OUT" > /dev/null 2>&1
    assert_exit 0 $? "a file merely named like CLAUDE.md is an ordinary diff" || rc=1
    if [[ -e "$PRB_OUT/pipeline-notice.md" ]]; then
        echo "  FAIL: an ordinary diff was flagged as a pipeline change"
        rc=1
    fi

    _prb_teardown
    return $rc
}
