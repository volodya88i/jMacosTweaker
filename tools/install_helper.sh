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
#
# Everything that decides trust is checked on a root-owned copy, never on the source. The source is usually in a folder
# the user can write to, so another process could swap it between a check and the copy.
set -euo pipefail
umask 022

LABEL=com.jmacostweaker.helper
APP_ID=com.jmacostweaker.app
APP_DEST=/Applications/jMacosTweaker.app
HELPER_DEST=/Library/PrivilegedHelperTools/$LABEL
PLIST_DEST=/Library/LaunchDaemons/$LABEL.plist
SUPPORT="/Library/Application Support/jMacosTweaker"

die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this with sudo"
[ $# -ge 1 ] || die "usage: sudo $0 <path to jMacosTweaker.app> [--allow-unverified-control]"
APP_SOURCE="${1%/}"
ALLOW_UNVERIFIED=0
[ "${2:-}" = "--allow-unverified-control" ] && ALLOW_UNVERIFIED=1
[ -d "$APP_SOURCE" ] || die "app not found: $APP_SOURCE"

# A private, root-only staging folder. Nothing in it can change after the copy.
STAGE="$(mktemp -d /private/tmp/jmacostweaker-install.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
chmod 700 "$STAGE"
STAGED="$STAGE/jMacosTweaker.app"
ditto --norsrc "$APP_SOURCE" "$STAGED"
chown -R root:wheel "$STAGED"
chmod -R go-w "$STAGED"
xattr -dr com.apple.quarantine "$STAGED" 2>/dev/null || true

STAGED_HELPER="$STAGED/Contents/MacOS/jmacostweaker-helper"
[ -f "$STAGED_HELPER" ] || die "helper binary not found inside the app. Build the Release configuration."

# The signature must be intact: a modified bundle could still carry the pinned binary.
codesign --verify --strict --deep "$STAGED" 2>/dev/null || die "the app's signature does not verify. Rebuild it."
codesign --verify --strict "$STAGED_HELPER" 2>/dev/null || die "the helper's signature does not verify. Rebuild the app."
# Output is captured first: with pipefail, grep -q closing the pipe early can fail the whole pipeline.
SIGNATURE="$(codesign -dv "$STAGED" 2>&1 || true)"
HELPER_SIGNATURE="$(codesign -dv "$STAGED_HELPER" 2>&1 || true)"
ENTITLEMENTS="$(codesign -d --entitlements - "$STAGED" 2>&1 || true)"
grep -q "^Identifier=$APP_ID\$" <<< "$SIGNATURE" || die "this is not jMacosTweaker ($APP_ID)."
grep -q "runtime" <<< "$SIGNATURE" || die "the app is not signed with the hardened runtime."
grep -q "runtime" <<< "$HELPER_SIGNATURE" || die "the helper is not signed with the hardened runtime."
# A debuggable client could be taken over by any process of the same user, so it cannot be trusted.
if grep -q "get-task-allow" <<< "$ENTITLEMENTS"; then
    die "this is a debuggable build. Install a Release build."
fi
CDHASH="$(sed -n 's/^CDHash=//p' <<< "$(codesign -dvvv "$STAGED" 2>&1)" | sed -n 1p)"
[[ "$CDHASH" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || die "could not read the app's code hash"

if launchctl print "system/$LABEL" > /dev/null 2>&1; then
    # The daemon hands everything back to the system on SIGTERM.
    launchctl bootout "system/$LABEL" || true
    # bootout can return before the service is gone, and bootstrap then fails with an I/O error.
    for _ in $(seq 1 20); do
        launchctl print "system/$LABEL" > /dev/null 2>&1 || break
        sleep 0.5
    done
fi

rm -rf "$APP_DEST"
ditto "$STAGED" "$APP_DEST"
chown -R root:wheel "$APP_DEST"
chmod -R go-w "$APP_DEST"

mkdir -p /Library/PrivilegedHelperTools "$SUPPORT"
chown root:wheel "$SUPPORT"
chmod 755 "$SUPPORT"
install -o root -g wheel -m 755 "$STAGED_HELPER" "$HELPER_DEST"
xattr -c "$HELPER_DEST" 2>/dev/null || true

# Written here rather than copied, so a file in a user-writable folder can never become a root LaunchDaemon.
cat > "$PLIST_DEST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HELPER_DEST</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>$LABEL</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST
chown root:wheel "$PLIST_DEST"
chmod 644 "$PLIST_DEST"
plutil -lint "$PLIST_DEST" > /dev/null || die "the LaunchDaemon file is not valid"

EXECUTABLE="$APP_DEST/Contents/MacOS/jMacosTweaker"
printf '{"cdhash":"%s","path":"%s"}\n' "$CDHASH" "$EXECUTABLE" > "$SUPPORT/pinned-client.json"
chown root:wheel "$SUPPORT/pinned-client.json"
chmod 644 "$SUPPORT/pinned-client.json"

if [ "$ALLOW_UNVERIFIED" -eq 1 ]; then
    touch "$SUPPORT/allow-unverified-control"
    chown root:wheel "$SUPPORT/allow-unverified-control"
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
# The installed copy, not this script's folder: that may be a disk image that is about to be ejected.
echo "Undo with: sudo \"$APP_DEST/Contents/Resources/uninstall_helper.sh\""
