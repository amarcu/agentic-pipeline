#!/bin/bash
# Installs the system-level wake-schedule daemon (LaunchDaemon).
#
# Unlike bin/install.sh (which handles user-level LaunchAgents and is
# idempotent without sudo), this script DOES require sudo because it
# writes to /Library/LaunchDaemons/ and bootstraps a system-domain agent.
#
# Run this on a fresh Mac after bin/install.sh, AND again after any edit to
# refresh-wake-schedule.sh. The script is COPIED into SCRIPTS_DIR, not
# symlinked (root executes it, so it does not track the repo), which means a
# repo edit does not reach a running host until this is re-run. The header
# previously claimed the opposite and cost a debugging session on 2026-08-30,
# when a rewritten refresh script appeared to have no effect on either Mac.
#
# Usage:
#   sudo bash launchd-runtime/system/install.sh
#   sudo bash launchd-runtime/system/install.sh --dry-run

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

REPO_ROOT="$(cd "$(/usr/bin/dirname "$0")/.." && pwd)"
SYSTEM_DIR="$REPO_ROOT/system"
# Root runs the daemon, so "$HOME" here is root's. The schedule belongs to the
# user who ran sudo: their state directory holds the script, and their
# LaunchAgents are what it reads.
OWNER="${SUDO_USER:-$(/usr/bin/id -un)}"
OWNER_HOME=$(/usr/bin/dscl . -read "/Users/$OWNER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')
[[ -n "$OWNER_HOME" ]] || OWNER_HOME=$(eval echo "~$OWNER")
SCRIPTS_DIR="${AGENTIC_SKILLS_HOME:-$OWNER_HOME/.agentic-skills}"
DAEMON_DIR="/Library/LaunchDaemons"
DAEMON_LABEL="com.agentic-skills.wakeschedule"

run() {
    if $DRY_RUN; then
        echo "  [dry-run] $*"
    else
        eval "$@"
    fi
}

echo "=== launchd-runtime system install (wake-schedule daemon) ==="
echo "Repo:         $REPO_ROOT"
echo "Owner:        $OWNER ($OWNER_HOME)"
echo "Scripts dir:  $SCRIPTS_DIR"
echo "Daemon dir:   $DAEMON_DIR"
$DRY_RUN && echo "Mode:         DRY RUN"
echo ""

if [[ "${EUID:-$(/usr/bin/id -u)}" != "0" ]] && ! $DRY_RUN; then
    echo "ERROR: This script must be run with sudo (it writes to $DAEMON_DIR)." >&2
    echo "Try: sudo bash $0" >&2
    exit 1
fi

# 1. Deploy the refresh script (user-readable, executable).
echo "[1/3] Deploying refresh-wake-schedule.sh to ${SCRIPTS_DIR}…"
run "/bin/mkdir -p '$SCRIPTS_DIR'"
run "/usr/bin/sed -e 's|__OWNER_HOME__|$OWNER_HOME|g' '$SYSTEM_DIR/refresh-wake-schedule.sh' > '$SCRIPTS_DIR/refresh-wake-schedule.sh'"
run "/bin/chmod 755 '$SCRIPTS_DIR/refresh-wake-schedule.sh'"
run "/usr/sbin/chown '$OWNER':staff '$SCRIPTS_DIR/refresh-wake-schedule.sh'"

# A host installed under an earlier label still has that daemon loaded. Boot
# it out and set its plist aside before loading this one.
for stale in "$DAEMON_DIR"/*.wakeschedule.plist; do
    [[ -f "$stale" && "$stale" != "$DAEMON_DIR/$DAEMON_LABEL.plist" ]] || continue
    stale_label=$(/usr/bin/basename "$stale" .plist)
    run "/bin/launchctl bootout 'system/$stale_label' 2>/dev/null || true"
    run "/bin/mv -f '$stale' '$SCRIPTS_DIR/retired-$stale_label.plist'"
    echo "  retired $stale_label"
done

# 2. Deploy the LaunchDaemon plist (root-owned, system-readable).
echo "[2/3] Deploying ${DAEMON_LABEL}.plist to ${DAEMON_DIR}…"
run "/usr/bin/sed -e 's|__AGENTIC_HOME__|$SCRIPTS_DIR|g' '$SYSTEM_DIR/$DAEMON_LABEL.plist' > '$DAEMON_DIR/$DAEMON_LABEL.plist'"
run "/bin/chmod 644 '$DAEMON_DIR/$DAEMON_LABEL.plist'"
run "/usr/sbin/chown root:wheel '$DAEMON_DIR/$DAEMON_LABEL.plist'"

# 3. Bootstrap (or re-bootstrap) the daemon.
echo "[3/3] Bootstrapping daemon into system domain…"
run "/bin/launchctl bootout system/$DAEMON_LABEL 2>/dev/null || true"
run "/bin/launchctl bootstrap system '$DAEMON_DIR/$DAEMON_LABEL.plist'"

# Touch the log file so it exists with right perms (avoids first-run noise).
run "/usr/bin/touch /var/log/wake-schedule.log"
run "/bin/chmod 644 /var/log/wake-schedule.log"

echo ""
echo "=== System install complete ==="
$DRY_RUN || {
    echo ""
    echo "Verify with:"
    echo "  sudo launchctl print system/$DAEMON_LABEL | head -20"
    echo "  sudo launchctl kickstart -k system/$DAEMON_LABEL    # force a fire-now"
    echo "  sudo cat /var/log/wake-schedule.log                  # confirm log entries"
    echo "  pmset -g sched                                       # verify queue populated"
    echo ""
    echo "User CLI (no sudo for status/pause/resume):"
    echo "  wake-schedule status"
}
