#!/bin/bash
# Clean universal Release build, then checks what the helper's client verification and the done criteria depend on.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate -q
rm -rf build/clean
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
xcodebuild -project jMacosTweaker.xcodeproj -scheme jMacosTweaker -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/clean clean build > "$LOG" 2>&1 || { grep -E 'error:' "$LOG"; exit 1; }
# appintentsmetadataprocessor reports that this app has no App Intents, which is a tool note about nothing in this code.
WARNINGS="$(grep -E 'warning:' "$LOG" | grep -v appintentsmetadataprocessor | sort -u || true)"
if [ -n "$WARNINGS" ]; then echo "$WARNINGS"; echo "FAIL: warnings"; exit 1; fi
APP=build/clean/Build/Products/Release/jMacosTweaker.app
fail() { echo "FAIL: $*"; exit 1; }
for binary in jMacosTweaker jmacostweaker-helper; do
    archs="$(lipo -archs "$APP/Contents/MacOS/$binary")"
    case "$archs" in *arm64*x86_64*|*x86_64*arm64*) ;; *) fail "$binary is not universal: $archs" ;; esac
done
codesign --verify --deep --strict "$APP" || fail "signature does not verify"
# Output is captured first: with pipefail, grep -q closing the pipe early can fail the whole pipeline.
APP_SIGNATURE="$(codesign -dv "$APP" 2>&1)"
HELPER_SIGNATURE="$(codesign -dv "$APP/Contents/MacOS/jmacostweaker-helper" 2>&1)"
ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>&1)"
grep -q "runtime" <<< "$APP_SIGNATURE" || fail "no hardened runtime on the app"
grep -q "runtime" <<< "$HELPER_SIGNATURE" || fail "no hardened runtime on the helper"
if grep -q get-task-allow <<< "$ENTITLEMENTS"; then fail "the app is debuggable"; fi
APP_STRINGS="$(strings "$APP/Contents/MacOS/jMacosTweaker")"
if grep -q RawSMCPort <<< "$APP_STRINGS"; then fail "the write port is linked into the app"; fi
for file in install_helper.sh uninstall_helper.sh com.jmacostweaker.helper.plist; do
    [ -f "$APP/Contents/Resources/$file" ] || fail "$file is missing from the app"
done
echo "PASS: clean universal Release, zero warnings, hardened, not debuggable, helper embedded."
