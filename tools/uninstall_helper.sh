#!/bin/bash
# Removes the privileged helper and returns fans and charging to system control.
#
#   sudo tools/uninstall_helper.sh [--remove-app]
#
# The daemon restores defaults on SIGTERM before it exits. The app stays unless you pass --remove-app.
set -euo pipefail

LABEL=com.jmacostweaker.helper
SUPPORT="/Library/Application Support/jMacosTweaker"

[ "$(id -u)" -eq 0 ] || { echo "error: run this with sudo" >&2; exit 1; }

if launchctl print "system/$LABEL" > /dev/null 2>&1; then
    launchctl bootout "system/$LABEL" || true
fi

if [ -f "$SUPPORT/restore-journal.json" ]; then
    echo "warning: a restore record is still present, so the helper could not confirm every restore." >&2
    echo "Restarting the Mac returns fans to system control. Charging state may need a restart too." >&2
fi

rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/PrivilegedHelperTools/$LABEL"
rm -rf "$SUPPORT"

if [ "${1:-}" = "--remove-app" ]; then
    rm -rf /Applications/jMacosTweaker.app
    echo "Helper and app removed."
else
    echo "Helper removed. The app is still in /Applications."
fi
