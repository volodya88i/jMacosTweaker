#!/bin/bash
# Installs the app and its privileged helper. Run it yourself with sudo; the app never asks for your password.
#
#   sudo tools/install_helper.sh <path to jMacosTweaker.app> [--allow-unverified-control]
#
# Installs:
#   /Applications/jMacosTweaker.app                              owned by root, so its identity can be trusted
#   /Library/PrivilegedHelperTools/com.jmacostweaker.helper      the root daemon
#   /Library/LaunchDaemons/com.jmacostweaker.helper.plist        starts it at boot
#   /Library/Application Support/jMacosTweaker/pinned-client.json  the app's code hash and path
#
# Run it again after every rebuild or update, because the pinned hash changes.
# Undo everything with: sudo tools/uninstall_helper.sh
#
# --allow-unverified-control lets the helper write fan and charge keys on a Mac and macOS version where that has not
# been verified. Only use it for a deliberate on-device test.
set -euo pipefail

LABEL=com.jmacostweaker.helper
APP_DEST=/Applications/jMacosTweaker.app
HELPER_DEST=/Library/PrivilegedHelperTools/$LABEL
PLIST_DEST=/Library/LaunchDaemons/$LABEL.plist
SUPPORT="/Library/Application Support/jMacosTweaker"
HERE="$(cd "$(dirname "$0")" && pwd)"

die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this with sudo"
[ $# -ge 1 ] || die "usage: sudo $0 <path to jMacosTweaker.app> [--allow-unverified-control]"
APP_SOURCE="${1%/}"
ALLOW_UNVERIFIED=0
[ "${2:-}" = "--allow-unverified-control" ] && ALLOW_UNVERIFIED=1
[ -d "$APP_SOURCE" ] || die "app not found: $APP_SOURCE"
HELPER_SOURCE="$APP_SOURCE/Contents/MacOS/jmacostweaker-helper"
[ -f "$HELPER_SOURCE" ] || die "helper binary not found inside the app. Build the Release configuration."

# A debuggable client could be taken over by any process of the same user, so it cannot be trusted.
# Output is captured first: with pipefail, grep -q closing the pipe early can fail the whole pipeline.
ENTITLEMENTS="$(codesign -d --entitlements - "$APP_SOURCE" 2>&1 || true)"
SIGNATURE="$(codesign -dv "$APP_SOURCE" 2>&1 || true)"
if grep -q "get-task-allow" <<< "$ENTITLEMENTS"; then
    die "this is a debuggable build. Install a Release build."
fi
grep -q "runtime" <<< "$SIGNATURE" || die "the app is not signed with the hardened runtime."

if launchctl print "system/$LABEL" > /dev/null 2>&1; then
    # The daemon hands everything back to the system on SIGTERM.
    launchctl bootout "system/$LABEL" || true
    # bootout can return before the service is gone, and bootstrap then fails with an I/O error.
    for _ in $(seq 1 20); do
        launchctl print "system/$LABEL" > /dev/null 2>&1 || break
        sleep 0.5
    done
fi

if [ "$(cd "$APP_SOURCE" && pwd -P)" != "$APP_DEST" ]; then
    rm -rf "$APP_DEST"
    ditto "$APP_SOURCE" "$APP_DEST"
fi
chown -R root:wheel "$APP_DEST"
chmod -R go-w "$APP_DEST"

mkdir -p /Library/PrivilegedHelperTools "$SUPPORT"
chown root:wheel "$SUPPORT"
chmod 755 "$SUPPORT"
install -o root -g wheel -m 755 "$APP_DEST/Contents/MacOS/jmacostweaker-helper" "$HELPER_DEST"
install -o root -g wheel -m 644 "$HERE/$LABEL.plist" "$PLIST_DEST"

CDHASH="$(codesign -dvvv "$APP_DEST" 2>&1 | sed -n 's/^CDHash=//p' | sed -n 1p)"
[ -n "$CDHASH" ] || die "could not read the app's code hash"
EXECUTABLE="$APP_DEST/Contents/MacOS/jMacosTweaker"
printf '{"cdhash":"%s","path":"%s"}\n' "$CDHASH" "$EXECUTABLE" > "$SUPPORT/pinned-client.json"
chown root:wheel "$SUPPORT/pinned-client.json"
chmod 644 "$SUPPORT/pinned-client.json"

if [ "$ALLOW_UNVERIFIED" -eq 1 ]; then
    touch "$SUPPORT/allow-unverified-control"
    chmod 644 "$SUPPORT/allow-unverified-control"
    echo "note: unverified control is ON. Remove it by running this script again without the flag."
else
    rm -f "$SUPPORT/allow-unverified-control"
fi

for attempt in 1 2 3 4 5; do
    launchctl bootstrap system "$PLIST_DEST" && break
    [ "$attempt" -lt 5 ] || die "launchd would not load the helper. Restart the Mac, or try again in a minute."
    sleep 2
done
echo "Installed. Pinned code hash: $CDHASH"
echo "Undo with: sudo $HERE/uninstall_helper.sh"
