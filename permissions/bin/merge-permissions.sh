#!/usr/bin/env bash
# Merge permissions/interactive-baseline.json into a Claude Code settings file.
#
# Idempotent: rules already present are left alone, and the baseline's
# _removeFromDeny entries are stripped so a blanket rule cannot keep shadowing
# the narrow allows (deny always beats allow), and _removeFromAllow entries are
# stripped from the existing allow list so a rule withdrawn from the baseline
# actually leaves machines that already merged it.
#
# Usage:
#   permissions/bin/merge-permissions.sh [--dry-run] [SETTINGS_FILE]
#
# SETTINGS_FILE defaults to ~/.claude/settings.json. A timestamped backup is
# written next to it before anything changes.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASELINE="$REPO_DIR/permissions/interactive-baseline.json"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=1; shift; fi
SETTINGS="${1:-$HOME/.claude/settings.json}"

[[ -f "$BASELINE" ]] || { echo "missing baseline: $BASELINE" >&2; exit 1; }
[[ -f "$SETTINGS" ]] || { echo "missing settings file: $SETTINGS" >&2; exit 1; }

if [[ $DRY_RUN -eq 0 ]]; then
    cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
fi

DRY_RUN=$DRY_RUN BASELINE="$BASELINE" SETTINGS="$SETTINGS" REPO_DIR="$REPO_DIR" python3 - <<'PY'
import collections, json, os, sys

baseline = json.load(open(os.environ['BASELINE']))
path = os.environ['SETTINGS']
dry = os.environ['DRY_RUN'] == '1'

settings = json.load(open(path), object_pairs_hook=collections.OrderedDict)
perm = settings.setdefault('permissions', collections.OrderedDict())
allow = list(perm.get('allow', []))
deny = list(perm.get('deny', []))
before = (len(allow), len(deny))

# A blanket deny shadows every narrow allow, so it has to go first.
drop = set(baseline.get('_removeFromDeny', []))
removed = [r for r in deny if r in drop]
deny = [r for r in deny if r not in drop]

# Allows are merged by union below, so deleting a rule from the baseline has no
# effect on a machine that already merged it. _removeFromAllow is the only way a
# rule that turned out to be unsafe actually leaves those machines.
drop_allow = set(baseline.get('_removeFromAllow', []))
removed_allow = [r for r in allow if r in drop_allow]
allow = [r for r in allow if r not in drop_allow]

added_allow = [r for r in baseline['permissions']['allow'] if r not in set(allow)]
added_deny = [r for r in baseline['permissions']['deny'] if r not in set(deny)]

perm['allow'] = sorted((set(allow) | set(baseline['permissions']['allow'])) - drop_allow)
perm['deny'] = sorted(set(deny) | set(baseline['permissions']['deny']))

print(f"allow {before[0]} -> {len(perm['allow'])} (+{len(added_allow)}, -{len(removed_allow)})")
print(f"deny  {before[1]} -> {len(perm['deny'])} (+{len(added_deny)}, -{len(removed)})")
for r in removed:
    print(f"  removed blanket deny: {r}")
for r in removed_allow:
    print(f"  removed unsafe allow: {r}")

# Install the path-resolving PreToolUse hook. Static rules match the command
# string, so `cd /protected && rm -rf x` matches nothing; the hook resolves what
# a command actually targets. It is inert until it appears here.
hook_cmd = os.path.join(os.environ['REPO_DIR'], 'permissions', 'bin', 'protected-paths-hook')
hooks = settings.setdefault('hooks', collections.OrderedDict())
pre = hooks.setdefault('PreToolUse', [])
existing = [h for entry in pre for h in entry.get('hooks', [])
            if str(h.get('command', '')).endswith('protected-paths-hook')]
if existing:
    # Repo moved, or the path changed: point at the current copy rather than
    # leaving a stale command that silently fails open.
    for h in existing:
        h['command'] = hook_cmd
    print(f"hook  already installed (path refreshed)")
else:
    pre.append(collections.OrderedDict([
        ('matcher', 'Bash'),
        ('hooks', [collections.OrderedDict([
            ('type', 'command'),
            ('command', hook_cmd),
            ('timeout', 10),
        ])]),
    ]))
    print(f"hook  installed PreToolUse/Bash -> {hook_cmd}")

if dry:
    print("\n--dry-run: nothing written")
    sys.exit(0)

with open(path, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
print(f"\nwrote {path}")
PY
