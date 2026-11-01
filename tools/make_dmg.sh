#!/bin/bash
# Packs a built app into a disk image with an Applications link and install notes.
#
#   tools/make_dmg.sh <path to jMacosTweaker.app> <output.dmg>
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
cat > "$STAGE/Install.txt" <<'NOTES'
1. Drag jMacosTweaker to Applications.

2. This build is not notarized, so macOS blocks it at first. If you trust this download, run this in Terminal:

   xattr -dr com.apple.quarantine /Applications/jMacosTweaker.app

   If it says Permission denied, the helper was installed before. Put sudo in front of the command.

3. Open jMacosTweaker. It lives in the menu bar and has no Dock icon.

Fan control needs a small helper. Settings shows the command to install it.
NOTES

rm -f "$OUT"
hdiutil create -quiet -volname "jMacosTweaker $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$OUT"
hdiutil verify -quiet "$OUT"
echo "Created $OUT"
