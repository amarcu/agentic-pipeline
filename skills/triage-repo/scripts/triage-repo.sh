#!/bin/bash
# triage-repo — classify one repo's open issues and pull requests.
#
# Usage: triage-repo.sh <owner/repo> [days-stale]
#        triage-repo.sh <owner/repo> [--days-stale <N>]
#
# Both spellings mean the same thing and only one may be given. The flag is
# what triage-repo/SKILL.md documents to a human; the bare positional is what
# morning-triage passes, one call per repo. Anything else is a usage error.
#
# Prints the `triage-repo/2` block on stdout, one summary line on stderr, and
# exits 0 whenever it reached a verdict — "gh failed" included. morning-triage
# walks the whole active roster in one pass, so a repo that is unreachable at
# 04:10 must cost that repo's block and not the routine; the failure is
# reported in-band as an ERROR block instead. Exit 2 is reserved for a caller
# that passed something unusable, which is a bug rather than a repo that is
# down.
#
# The classification lives here rather than in SKILL.md prose because the prose
# version was re-derived by the model on every run: six precedence rules
# applied by hand put the same issue in different buckets on different
# mornings, and a digest nobody can diff is a digest nobody trusts. The two
# `--jq` expressions below are executed by gh's own embedded jq, so this script
# needs no jq on PATH.
set -u

ISSUE_LIMIT=50
PR_LIMIT=30

# gh's stderr, kept so the ERROR block can quote the reason. A fixed literal
# path overwritten in place, never removed — the same discipline as the
# Telegram recipe in notify/SKILL.md. The two calls below are sequential, so
# the second never races the first.
GH_STDERR=/tmp/triage-repo-gh-stderr.txt

usage() {
    echo "usage: triage-repo.sh <owner/repo> [days-stale]" >&2
    echo "       triage-repo.sh <owner/repo> [--days-stale <N>]" >&2
    exit 2
}

repo=""
days=14
days_given=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --days-stale)
            [ "$#" -ge 2 ] || usage
            [ "$days_given" -eq 0 ] || usage
            days="$2"
            days_given=1
            shift ;;
        -*)
            usage ;;
        *)
            if [ -z "$repo" ]; then
                repo="$1"
            elif [ "$days_given" -eq 0 ]; then
                days="$1"
                days_given=1
            else
                # A third bare word is a caller that thinks it is passing
                # something this script reads. Refusing beats ignoring it.
                usage
            fi ;;
    esac
    shift
done

case "$repo" in
    */*) ;;
    *)   usage ;;
esac
case "$days" in
    ''|*[!0-9]*)
        echo "triage-repo: days-stale must be a whole number, got '$days'" >&2
        exit 2 ;;
esac

scanned=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')
now_epoch=$(/bin/date -u '+%s')
cutoff=$(/bin/date -u -v-"${days}"d '+%Y-%m-%dT%H:%M:%SZ')

header() {
    printf 'REPO: %s\n' "$repo"
    printf 'FORMAT: triage-repo/2\n'
    printf 'Scanned: %s\n' "$scanned"
}

# One ERROR block, one stderr line, exit 0: the caller keeps going.
fail() {
    header
    printf 'ERROR: %s\n' "$1"
    printf 'triage-repo: %s issues=0 prs=0 gh_calls=%s\n' "$repo" "$2" >&2
    exit 0
}

command -v gh > /dev/null 2>&1 \
    || fail "gh CLI not on PATH (brew install gh && gh auth login)" 0

# ── Classification ────────────────────────────────────────────────────────
#
# Both programs emit one record per item: `<bucket><TAB><rendered line>`. The
# label list is sorted so the rendered line does not depend on the order the
# API happened to return labels in — identical data, identical bytes.
#
# `@CUTOFF@` and `@NOW@` are substituted below rather than interpolated by the
# heredoc: a jq program is full of `$name` bindings that an unquoted heredoc
# would eat.

issue_jq=$(/bin/cat <<'JQ'
def flat: split("\n") | join(" ") | split("\r") | join(" ") | split("\t") | join(" ");
def hasl($n): index($n) != null;
def days($t): ((@NOW@ - ($t | fromdate)) / 86400 | floor);
.[]
| ([.labels[].name] | sort) as $l
| (if   ($l | hasl("blocker")) or ($l | hasl("critical")) or ($l | hasl("security")) then "blocking"
   elif ($l | hasl("needs-approval")) then "needs-approval"
   elif ($l | hasl("proposed")) and (($l | hasl("approved")) | not) then "proposed"
   elif ($l | hasl("documentation")) or ($l | hasl("question")) or ($l | hasl("discussion")) or ($l | hasl("enhancement")) then "informational"
   elif (.updatedAt >= "@CUTOFF@") or ($l | hasl("proposed")) or ($l | hasl("approved")) then "active"
   else "stale"
   end) as $bucket
| "\($bucket)\t    - #\(.number) \(.title | flat) [age=\(days(.createdAt))d updated=\(days(.updatedAt))d] \(.url) labels=[\($l | join(","))]"
JQ
)

pr_jq=$(/bin/cat <<'JQ'
def flat: split("\n") | join(" ") | split("\r") | join(" ") | split("\t") | join(" ");
def hasl($n): index($n) != null;
def days($t): ((@NOW@ - ($t | fromdate)) / 86400 | floor);
.[]
| ([.labels[].name] | sort) as $l
| ([.statusCheckRollup[]? | (.conclusion // .state // "")] | map(select(. != ""))) as $c
| (if   ($c | length) == 0 then "none"
   elif ($c | any(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED" or . == "STARTUP_FAILURE")) then "fail"
   elif ($c | all(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED")) then "pass"
   else "pending"
   end) as $ci
| (if   (.isDraft and ((.headRefName | startswith("task/issue-")) or (.headRefName | startswith("worktree-issue-")))) then "draft-agent"
   elif (.isDraft | not) then "ready"
   elif (.updatedAt < "@CUTOFF@") then "stale"
   else "draft"
   end) as $bucket
| "\($bucket)\t    - #\(.number) \(.title | flat) [branch=\(.headRefName) age=\(days(.createdAt))d updated=\(days(.updatedAt))d ci=\($ci)] \(.url) labels=[\($l | join(","))]"
JQ
)

issue_jq=${issue_jq//@CUTOFF@/$cutoff}
issue_jq=${issue_jq//@NOW@/$now_epoch}
pr_jq=${pr_jq//@CUTOFF@/$cutoff}
pr_jq=${pr_jq//@NOW@/$now_epoch}

# ── Fetch ─────────────────────────────────────────────────────────────────

if ! issues=$(gh issue list --repo "$repo" --state open --limit "$ISSUE_LIMIT" \
        --json number,title,labels,createdAt,updatedAt,url \
        --jq "$issue_jq" 2>"$GH_STDERR"); then
    detail=$(/usr/bin/head -1 "$GH_STDERR" 2>/dev/null)
    fail "gh issue list failed: ${detail:-exited nonzero with no stderr}" 1
fi

if ! prs=$(gh pr list --repo "$repo" --state open --limit "$PR_LIMIT" \
        --json number,title,labels,isDraft,headRefName,statusCheckRollup,createdAt,updatedAt,url \
        --jq "$pr_jq" 2>"$GH_STDERR"); then
    detail=$(/usr/bin/head -1 "$GH_STDERR" 2>/dev/null)
    fail "gh pr list failed: ${detail:-exited nonzero with no stderr}" 2
fi

# ── Report ────────────────────────────────────────────────────────────────

total_of() {
    printf '%s\n' "$1" | /usr/bin/awk 'NF { n++ } END { print n + 0 }'
}

count_of() {
    printf '%s\n' "$1" | /usr/bin/awk -F'\t' -v b="$2" '$1 == b { n++ } END { print n + 0 }'
}

# Every bucket is counted on the section line; only the non-empty ones list
# their items. A digest that prints six `(0)` headings per repo across thirteen
# repos is context spent saying nothing.
section() {
    local label="$1" total="$2" records="$3" b lines
    shift 3
    printf '\n%s (%s):' "$label" "$total"
    for b in "$@"; do
        printf ' %s=%s' "$b" "$(count_of "$records" "$b")"
    done
    printf '\n'
    for b in "$@"; do
        lines=$(printf '%s\n' "$records" \
            | /usr/bin/awk -F'\t' -v b="$b" '$1 == b { sub(/^[^\t]*\t/, ""); print }')
        [ -n "$lines" ] || continue
        printf '  %s:\n' "$b"
        printf '%s\n' "$lines"
    done
}

issue_total=$(total_of "$issues")
pr_total=$(total_of "$prs")

header
printf 'Stale-days: %s\n' "$days"
printf 'Precedence-issues: blocking > needs-approval > proposed > informational > active > stale (first match wins)\n'
printf 'Precedence-prs: draft-agent > ready > stale > draft (first match wins)\n'
section ISSUES "$issue_total" "$issues" blocking needs-approval proposed informational active stale
section PRS "$pr_total" "$prs" draft-agent ready stale draft

printf 'triage-repo: %s issues=%s prs=%s gh_calls=2\n' "$repo" "$issue_total" "$pr_total" >&2
