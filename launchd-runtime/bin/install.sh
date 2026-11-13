#!/bin/bash
# Installs the launchd-runtime files into their runtime locations.
#
# What it does:
#   1. Creates ${AGENTIC_SKILLS_HOME:-$HOME/.agentic-skills}/routines/{logs,}
#   2. Symlinks bin/* and prompts/*.md into ${AGENTIC_SKILLS_HOME:-$HOME/.agentic-skills}/
#   3. Copies agents/*.plist into ~/Library/LaunchAgents/  (copy, not symlink:
#      launchctl bootstrap is sometimes finicky with symlinked plists)
#   4. Bootstraps each LaunchAgent into the user's gui domain
#   5. Symlinks every skill directory into ~/.claude/skills/
#
# Re-running this script is safe and idempotent — it bootouts existing
# agents and re-bootstraps them. Use it after editing a plist.
#
# Usage: install.sh               (install + bootstrap all)
#        install.sh --skills-only (only step 5 — for hosts that run no routines)
#        install.sh --dry-run     (print actions without executing)

set -euo pipefail

DRY_RUN=false
SKILLS_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --dry-run)     DRY_RUN=true ;;
        --skills-only) SKILLS_ONLY=true ;;
        *) echo "Unknown option: $arg (expected --dry-run and/or --skills-only)" >&2; exit 2 ;;
    esac
done

REPO_ROOT="$(cd "$(/usr/bin/dirname "$0")/.." && pwd)"
SKILLS_ROOT="$(cd "$REPO_ROOT/.." && pwd -P)"
SCRIPTS_DIR="${AGENTIC_SKILLS_HOME:-$HOME/.agentic-skills}"
ROUTINES_DIR="$SCRIPTS_DIR/routines"
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
CLAUDE_COMMANDS_DIR="$HOME/.claude/commands"
UID_NUM=$(/usr/bin/id -u)

run() {
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        eval "$@"
    fi
}

# A skill is linked as a DIRECTORY, never as its SKILL.md alone: the legacy
# single-file link at ~/.claude/commands/<name>.md leaves META.md, reference.md
# and scripts/ next to it unreachable.
install_skills() {
    local step="$1"
    local linked=0 removed=0 skill_md dir name legacy

    echo "$step Symlinking skills into ${CLAUDE_SKILLS_DIR}…"
    run "/bin/mkdir -p '$CLAUDE_SKILLS_DIR'"

    for skill_md in "$SKILLS_ROOT"/skills/*/SKILL.md; do
        [[ -f "$skill_md" ]] || continue
        dir=$(/usr/bin/dirname "$skill_md")
        name=$(/usr/bin/basename "$dir")

        # A directory whose name starts with `_` is scaffolding, not a skill:
        # _templates/SKILL.md is the skeleton new skills are copied from, and
        # linking it would put a placeholder /_templates in every session's
        # skill menu with a placeholder description in context.
        [[ "$name" == _* ]] && continue

        run "/bin/ln -sfn '$dir' '$CLAUDE_SKILLS_DIR/$name'"
        echo "  ✓ $name"
        linked=$((linked + 1))

        legacy="$CLAUDE_COMMANDS_DIR/$name.md"
        if [[ -L "$legacy" ]] && links_into_repo "$legacy"; then
            run "/bin/rm -f '$legacy'"
            echo "  - removed legacy commands/$name.md"
            removed=$((removed + 1))
        fi
    done

    echo "  $linked skill(s) linked, $removed legacy command link(s) removed"
}

# Only a link that resolves back into this repo is ours to remove — commands/
# also holds unrelated links (Cursor) that must survive.
links_into_repo() {
    local target dir
    target=$(/usr/bin/readlink "$1")
    [[ "$target" == /* ]] || target="$(/usr/bin/dirname "$1")/$target"
    dir=$(cd "$(/usr/bin/dirname "$target")" 2>/dev/null && pwd -P) || return 1
    [[ "$dir" == "$SKILLS_ROOT" || "$dir" == "$SKILLS_ROOT"/* ]]
}

echo "=== launchd-runtime install ==="
echo "Repo:    $REPO_ROOT"
if ! $SKILLS_ONLY; then
    echo "Scripts: $SCRIPTS_DIR"
    echo "Agents:  $LAUNCH_AGENTS_DIR"
    echo "UID:     $UID_NUM"
fi
echo "Skills:  $CLAUDE_SKILLS_DIR"
$DRY_RUN && echo "Mode:    DRY RUN (no changes will be made)"
echo ""

if $SKILLS_ONLY; then
    install_skills "[1/1]"
    echo ""
    echo "=== Skills install complete ==="
    exit 0
fi

# 1. Ensure target directories exist
echo "[1/5] Ensuring target directories exist…"
run "/bin/mkdir -p '$ROUTINES_DIR/logs'"
run "/bin/mkdir -p '$ROUTINES_DIR/metrics'"
run "/bin/mkdir -p '$LAUNCH_AGENTS_DIR'"

# 2. Symlink scripts
echo "[2/5] Symlinking scripts…"
run "/bin/ln -sfn '$REPO_ROOT/bin/claude-cli' '$SCRIPTS_DIR/claude-cli'"
run "/bin/ln -sfn '$REPO_ROOT/bin/_run.sh' '$ROUTINES_DIR/_run.sh'"
run "/bin/ln -sfn '$REPO_ROOT/bin/routines-status' '$SCRIPTS_DIR/routines-status'"
run "/bin/ln -sfn '$REPO_ROOT/bin/issues-status' '$SCRIPTS_DIR/issues-status'"
run "/bin/ln -sfn '$REPO_ROOT/bin/wake-schedule' '$SCRIPTS_DIR/wake-schedule'"
run "/bin/ln -sfn '$REPO_ROOT/bin/routine-cost' '$SCRIPTS_DIR/routine-cost'"
run "/bin/ln -sfn '$REPO_ROOT/bin/check-requirements' '$SCRIPTS_DIR/check-requirements'"
run "/bin/ln -sfn '$REPO_ROOT/bin/install-requirements' '$SCRIPTS_DIR/install-requirements'"

# Make repo scripts executable (in case fresh clone hasn't preserved bits)
run "/bin/chmod +x '$REPO_ROOT/bin/claude-cli' '$REPO_ROOT/bin/_run.sh' '$REPO_ROOT/bin/routines-status' '$REPO_ROOT/bin/issues-status' '$REPO_ROOT/bin/wake-schedule' '$REPO_ROOT/bin/routine-cost' '$REPO_ROOT/bin/check-requirements' '$REPO_ROOT/bin/install-requirements' '$REPO_ROOT/bin/install.sh'"

# 3. Symlink prompts
echo "[3/5] Symlinking prompts…"
for prompt in "$REPO_ROOT/prompts/"*.md; do
    [[ -f "$prompt" ]] || continue
    name=$(/usr/bin/basename "$prompt" .md)
    run "/bin/ln -sfn '$prompt' '$ROUTINES_DIR/${name}.prompt.md'"
done

# 4. Bootstrap LaunchAgents
echo "[4/5] Installing LaunchAgents…"
for plist in "$REPO_ROOT/agents/"*.plist; do
    [[ -f "$plist" ]] || continue
    pname=$(/usr/bin/basename "$plist" .plist)
    target="$LAUNCH_AGENTS_DIR/$(/usr/bin/basename "$plist")"

    # Bootout existing instance (best-effort, ignore missing)
    run "/bin/launchctl bootout 'gui/$UID_NUM/$pname' 2>/dev/null || true"

    # A host installed under an earlier label still has that agent loaded, and
    # it would fire beside this one: every routine twice, on the same repos.
    # Any other agent for the same routine is booted out and its plist set
    # aside (kept, not deleted) before this one is loaded.
    routine="${pname##*.routines.}"
    for stale in "$LAUNCH_AGENTS_DIR"/*.routines."$routine".plist; do
        [[ -f "$stale" && "$stale" != "$target" ]] || continue
        stale_label=$(/usr/bin/basename "$stale" .plist)
        run "/bin/launchctl bootout 'gui/$UID_NUM/$stale_label' 2>/dev/null || true"
        run "/bin/mkdir -p '$ROUTINES_DIR/retired-agents'"
        run "/bin/mv -f '$stale' '$ROUTINES_DIR/retired-agents/'"
        echo "  ↺ retired $stale_label"
    done

    # Render the template into the runtime location. launchd takes absolute
    # paths only, so the home and state directories are filled in here and no
    # tracked plist carries one machine's.
    run "/usr/bin/sed -e 's|__AGENTIC_HOME__|$SCRIPTS_DIR|g' -e 's|__HOME__|$HOME|g' '$plist' > '$target'"

    # Bootstrap fresh
    run "/bin/launchctl bootstrap 'gui/$UID_NUM' '$target'"
    echo "  ✓ $pname"
done

install_skills "[5/5]"

echo ""
echo "=== Install complete ==="
$DRY_RUN || {
    echo "Verify with: routines-status"
    echo "List loaded agents: launchctl list | grep com.agentic-skills.routines"
}
