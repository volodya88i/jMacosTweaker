#!/bin/bash
# Builds and tests from the command line. Warnings are errors. Prints only problems and the summary.
set -u
cd "$(dirname "$0")/.."
xcodegen generate -q || exit 1
xcodebuild -project jMacosTweaker.xcodeproj -scheme jMacosTweaker -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/dd "${1:-test}" 2>&1 \
  | grep -E 'error:|warning:|Test Case.*failed|Executed [0-9]+|\*\* ' \
  | sed "s#$PWD/##" | sort -u
