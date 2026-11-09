#!/bin/bash
# Packs a built app into a disk image with an Applications link, a one-step installer and install notes.
#
#   tools/make_dmg.sh <path to jMacosTweaker.app> <output.dmg>
#
# "Install jMacosTweaker.command" runs the app's own install_helper.sh on the copy inside the image. That script copies the
# app to /Applications as root, verifies its signature on the root-owned copy, clears the quarantine flag, installs the
# helper and pins this build. The password prompt comes from sudo in Terminal; the app never asks for it.
set -euo pipefail

[ $# -eq 2 ] || { echo "usage: $0 <path to jMacosTweaker.app> <output.dmg>" >&2; exit 2; }
APP="$1"
OUT="$2"
[ -d "$APP" ] || { echo "error: app not found: $APP" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto --norsrc --noextattr "$APP" "$STAGE/jMacosTweaker.app"
ln -s /Applications "$STAGE/Applications"

INSTALLER="$STAGE/Install jMacosTweaker.command"
cat > "$INSTALLER" <<'INSTALL'
#!/bin/bash
# Installs jMacosTweaker from this disk image: the app into /Applications, and the fan control helper.
# The same steps as tools/install_helper.sh in the source, which this runs from the app inside the image.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/jMacosTweaker.app"
SCRIPT="$APP/Contents/Resources/install_helper.sh"
[ -f "$SCRIPT" ] || { echo "The app was not found next to this installer. Open the disk image again."; exit 1; }

echo "This installs jMacosTweaker into /Applications, with the helper that fan control needs."
echo "macOS asks for your password once, for sudo. jMacosTweaker itself never asks for it."
echo

# A running copy would keep the old build, which the helper no longer accepts after this. Fans go back to macOS when it quits.
if pgrep -x jMacosTweaker > /dev/null; then
    killall jMacosTweaker 2> /dev/null || true
    sleep 1
fi

sudo /bin/bash "$SCRIPT" "$APP"
open /Applications/jMacosTweaker.app
echo
echo "Done. jMacosTweaker is in the menu bar. You can close this window and eject the disk image."
INSTALL
chmod 755 "$INSTALLER"

cat > "$STAGE/Install.txt" <<'NOTES'
Recommended: double-click "Install jMacosTweaker.command".
It copies the app to Applications, installs the helper that fan control needs, and opens the app. Terminal asks for your
password once, for sudo. jMacosTweaker itself never asks for it.

This build is not notarized. If macOS will not open the installer, right-click it and choose Open, or allow it under
System Settings > Privacy & Security. Or run this in Terminal, which does the same:

   sudo /bin/bash "/Volumes/jMacosTweaker VERSION/jMacosTweaker.app/Contents/Resources/install_helper.sh" "/Volumes/jMacosTweaker VERSION/jMacosTweaker.app"

Monitoring only, without the helper:
1. Drag jMacosTweaker to Applications.
2. Run this in Terminal, because macOS blocks unnotarized apps at first:

   xattr -dr com.apple.quarantine /Applications/jMacosTweaker.app

3. Open jMacosTweaker. It lives in the menu bar and has no Dock icon. Settings shows how to add the helper later.

Updating: run the installer again. The helper accepts only the build it pinned, so every update needs it.
NOTES
sed -i '' "s/jMacosTweaker VERSION/jMacosTweaker $VERSION/g" "$STAGE/Install.txt"

rm -f "$OUT"
hdiutil create -quiet -volname "jMacosTweaker $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$OUT"
hdiutil verify -quiet "$OUT"
echo "Created $OUT"
