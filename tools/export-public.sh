#!/bin/bash
# export-public.sh — build the tree that is safe to publish, and check it.
#
# Usage: tools/export-public.sh <empty-or-new-directory>
#
# The tree is `git archive HEAD` and nothing else, so:
#   - an untracked file (a .env, a local roster, a worktree) cannot reach it;
#   - a path marked `export-ignore` in .gitattributes is left out;
#   - it has no history. A published repository starts from one commit of
#     this tree, because the working repository's history holds the values
#     this tree no longer does.
#
# It then runs the checks on the exported copy, not on the checkout: the
# personal-value scan (with this machine's private-names.local, if any),
# gitleaks when it is installed, and the test suite.
#
# It creates nothing on GitHub. Publishing is a separate, deliberate step.
set -euo pipefail

DEST="${1:-}"
if [[ -z "$DEST" ]]; then
    echo "usage: tools/export-public.sh <empty-or-new-directory>" >&2
    exit 2
fi
ROOT="$(cd "$(/usr/bin/dirname "$0")/.." && pwd -P)"
cd "$ROOT"

if [[ -n "$(/usr/bin/git status --porcelain --untracked-files=no)" ]]; then
    echo "export-public: there are uncommitted changes; the export is HEAD, so commit first" >&2
    exit 1
fi
/bin/mkdir -p "$DEST"
if [[ -n "$(/bin/ls -A "$DEST")" ]]; then
    echo "export-public: $DEST is not empty" >&2
    exit 1
fi
DEST="$(cd "$DEST" && pwd -P)"

echo "[1/4] exporting $(/usr/bin/git rev-parse --short HEAD) to $DEST"
/usr/bin/git archive --format=tar HEAD | /usr/bin/tar -x -C "$DEST"

echo "[2/4] scanning the export for personal values"
NAMES="$ROOT/launchd-runtime/tests/private-names.local"
[[ -f "$NAMES" ]] || echo "      (no private-names.local on this machine: names are not checked)"
/usr/bin/python3 "$DEST/launchd-runtime/tests/static/scan-personal-values.py" "$DEST" "$NAMES"

echo "[3/4] scanning the export for secrets"
if command -v gitleaks >/dev/null 2>&1; then
    gitleaks dir "$DEST" --redact --no-banner
else
    echo "      (gitleaks is not installed: skipped)"
fi

echo "[4/4] running the test suite in the export"
( cd "$DEST" && /usr/bin/make test )

echo ""
echo "export-public: $DEST passed every check. Files: $(/usr/bin/find "$DEST" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
