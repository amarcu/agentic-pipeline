#!/bin/bash
# Record a work-on-task refusal or halt on the issue, once.
#
# Usage: record-refusal.sh <owner/repo> <issue> <reason> [first-error-line]
#
# A Step 1 refusal never started work; a `verify` halt started, committed and
# stopped at the gate. The label, the comment and the reason are the same
# mechanism, so the wording says which of the two happened — a human triaging
# "why is there no PR" reads that line first.
#
# The label is what stops dispatch-tasks re-queueing the issue every night, and
# it is a human's to clear: removing it means the cause is fixed. A refusal that
# repeats nightly must not comment nightly, so an issue already carrying any
# `blocked:*` label is left untouched and the script exits 0.
set -euo pipefail

repo="$1"; issue="$2"; reason="$3"; detail="${4:-}"

case "$reason" in
    verify) verb="halted" ;;
    *)      verb="refused" ;;
esac

existing=$(gh issue view "$issue" --repo "$repo" --json labels \
               -q '.labels[].name' | grep '^blocked:' || true)
if [ -n "$existing" ]; then
    echo "HALT: work-on-task $reason (already recorded as $existing)"
    exit 0
fi

gh label create "blocked:$reason" --repo "$repo" --color b60205 --force \
    --description "work-on-task $verb; a human clears this label"
gh issue edit "$issue" --repo "$repo" --add-label "blocked:$reason"

body="work-on-task $verb: $reason"
[ -n "$detail" ] && body="$body

\`\`\`
$detail
\`\`\`"
gh issue comment "$issue" --repo "$repo" --body "$body"

echo "HALT: work-on-task $reason"
