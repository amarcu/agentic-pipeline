#!/bin/bash
# Static checks on cursor-review: the invariants that make it an independent
# reviewer rather than a second Claude with extra steps.
#
# These read the source, not a run, because the two things they guard against
# are edits that would look harmless in review. Adding `--force` to the
# cursor-agent invocation turns a read-only reviewer into one that rewrites the
# bundle; naming a Claude model in DEFAULT_MODEL puts the author back in the
# reviewer's chair. Neither would fail a functional test that only checks the
# verdict came out.

CURSOR_REVIEW="$RUNTIME_DIR/bin/cursor-review"

# The script's executable lines, with full-line comments dropped and every
# backslash continuation joined, so a flag can be attributed to the command it
# actually belongs to.
_cursor_review_code() {
    /usr/bin/awk '
        buf == "" && /^[[:space:]]*#/ { next }
        { sub(/^[[:space:]]+/, "") }
        /\\$/ { sub(/\\$/, " "); buf = buf $0; next }
        { print buf $0; buf = "" }
    ' "$CURSOR_REVIEW"
}

_cursor_agent_invocations() {
    _cursor_review_code \
        | /usr/bin/grep -F '"$CURSOR_AGENT"' \
        | /usr/bin/grep -vF '[[ -x'
}

test_cursor_review_exists_and_is_executable() {
    assert_file_exists "$CURSOR_REVIEW" "cursor-review" || return 1
    if [[ ! -x "$CURSOR_REVIEW" ]]; then
        echo "  FAIL: $CURSOR_REVIEW is not executable"
        return 1
    fi
    return 0
}

test_cursor_review_runs_the_agent_exactly_once_and_read_only() {
    local rc=0 invocations count
    invocations=$(_cursor_agent_invocations)
    count=$(printf '%s\n' "$invocations" | /usr/bin/grep -c . || true)

    if [[ "$count" -ne 1 ]]; then
        echo "  FAIL: expected exactly 1 cursor-agent invocation, found $count"
        printf '%s\n' "$invocations" | /usr/bin/sed 's/^/    /'
        return 1
    fi

    assert_contains "$invocations" "--mode ask" \
        "the reviewer runs in ask mode, which cannot edit" || rc=1
    # --trust is required and safe: cursor-agent will not work in a directory
    # it has not seen before, and every bundle directory is new. It grants the
    # workspace, not permission to change it.
    assert_contains "$invocations" "--trust" "the fresh bundle directory is trusted" || rc=1
    assert_not_contains "$invocations" "--force" "and never --force" || rc=1
    assert_not_contains "$invocations" "--yolo" "and never --yolo" || rc=1
    return $rc
}

test_cursor_review_never_uses_a_mode_other_than_ask() {
    local modes bad
    modes=$(_cursor_review_code | /usr/bin/grep -oE '\-\-mode[[:space:]]+[a-z-]+' | /usr/bin/sort -u)
    bad=$(printf '%s\n' "$modes" | /usr/bin/grep -v '^--mode ask$' || true)
    if [[ -n "$bad" ]]; then
        echo "  FAIL: cursor-review names a mode other than ask:"
        printf '%s\n' "$bad" | /usr/bin/sed 's/^/    /'
        return 1
    fi
    return 0
}

test_cursor_review_default_model_is_not_anthropic() {
    local default re rc=0
    default=$(/usr/bin/grep -E '^DEFAULT_MODEL=' "$CURSOR_REVIEW" | /usr/bin/head -1 \
                  | /usr/bin/cut -d'"' -f2)
    re=$(/usr/bin/grep -E '^CLAUDE_MODEL_RE=' "$CURSOR_REVIEW" | /usr/bin/head -1 \
             | /usr/bin/cut -d"'" -f2)

    if [[ -z "$default" ]]; then
        echo "  FAIL: cursor-review declares no DEFAULT_MODEL"
        return 1
    fi
    if [[ -z "$re" ]]; then
        echo "  FAIL: cursor-review declares no CLAUDE_MODEL_RE"
        return 1
    fi
    if printf '%s' "$default" | /usr/bin/grep -qiE "$re"; then
        echo "  FAIL: DEFAULT_MODEL '$default' is an Anthropic model — the whole lane"
        echo "        exists so the reviewer is not the model that wrote the code"
        rc=1
    fi

    # Every spelling `cursor-agent --list-models` offered on this plan, so a
    # regex narrowed to one of them still catches the rest.
    local id
    for id in claude-opus-5-high claude-sonnet-5-thinking claude-fable-5-thinking-high; do
        if ! printf '%s' "$id" | /usr/bin/grep -qiE "$re"; then
            echo "  FAIL: CLAUDE_MODEL_RE does not catch '$id'"
            rc=1
        fi
    done
    return $rc
}

test_cursor_review_checks_the_model_before_allowing_a_pipeline_bundle() {
    # pr-review-bundle refuses a PR that modifies the pipeline, and
    # --allow-pipeline lifts that refusal. It is only safe because the reviewer
    # is not Claude, so the model check has to come first — a Claude id must
    # exit before this script can ever hand the bundler that flag.
    local check_line allow_line
    check_line=$(/usr/bin/grep -n 'CLAUDE_MODEL_RE"' "$CURSOR_REVIEW" | /usr/bin/head -1 \
                     | /usr/bin/cut -d: -f1)
    allow_line=$(/usr/bin/grep -n '^ALLOW_PIPELINE=' "$CURSOR_REVIEW" | /usr/bin/head -1 \
                     | /usr/bin/cut -d: -f1)

    if [[ -z "$check_line" || -z "$allow_line" ]]; then
        echo "  FAIL: could not find the model check (line '$check_line') or the"
        echo "        --allow-pipeline assignment (line '$allow_line')"
        return 1
    fi
    if [[ "$allow_line" -le "$check_line" ]]; then
        echo "  FAIL: --allow-pipeline is set at line $allow_line, before the model"
        echo "        check at line $check_line — a Claude model could reach the bundler"
        return 1
    fi
    return 0
}

test_cursor_review_never_approves_or_merges() {
    # Everything posts under the human's own GitHub login. A review that
    # approved, marked ready or merged would be indistinguishable from the
    # human doing it — BASELINE, Merging and Marking PRs Ready.
    local rc=0 code
    code=$(_cursor_review_code)

    assert_not_contains "$code" "APPROVE" "the review event is never APPROVE" || rc=1
    assert_not_contains "$code" "REQUEST_CHANGES" "and never REQUEST_CHANGES" || rc=1
    assert_not_contains "$code" "pr ready" "it never marks a PR ready" || rc=1
    assert_not_contains "$code" "pr merge" "and never merges one" || rc=1
    assert_not_contains "$code" "pr review" "and posts through the API, not gh pr review" || rc=1
    assert_contains "$code" '"event": "COMMENT"' "the only event it posts is COMMENT" || rc=1
    return $rc
}

test_cursor_review_finding_tag_matches_the_fixer_that_reads_it() {
    # iterate-on-pr/scripts/pr-feedback keys on this tag to pair a reply with
    # the finding it answers. A tag written differently here is a finding the
    # fixer silently never sees.
    local feedback="$REPO_ROOT/skills/iterate-on-pr/scripts/pr-feedback"
    local rc=0
    assert_file_exists "$feedback" "pr-feedback, the consumer of the tag" || return 1

    if ! /usr/bin/grep -qF 'finding:(\S+)\s+severity:(\S+)\s+round:(\d+)' "$feedback"; then
        echo "  FAIL: pr-feedback's FINDING_RE has changed shape — cursor-review's tag"
        echo "        must be rewritten to match it"
        rc=1
    fi
    if ! /usr/bin/grep -qF 'finding:%s severity:%s round:%s' "$CURSOR_REVIEW"; then
        echo "  FAIL: cursor-review no longer emits the tag pr-feedback matches"
        rc=1
    fi
    return $rc
}
