#!/bin/bash
# Repeatable idle measurement. Builds Release, runs it with CPU, Memory and Temperature modules, and reports averages.
# Usage: tools/perf.sh [seconds]. Your own settings are saved first and put back afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
SECONDS_TO_RUN="${1:-120}"
DOMAIN=com.jmacostweaker.app
KEY=settings.v1
xcodegen generate -q
xcodebuild -project jMacosTweaker.xcodeproj -scheme jMacosTweaker -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd build > /dev/null
APP=build/dd/Build/Products/Release/jMacosTweaker.app
# The run swaps the settings file and quits the app, so it must not overlap with real use.
if pgrep -x jMacosTweaker > /dev/null; then echo "error: quit jMacosTweaker first" >&2; exit 1; fi
SAVED="$(defaults export "$DOMAIN" - 2> /dev/null || true)"
restore() {
    pkill -x jMacosTweaker 2> /dev/null || true
    defaults delete "$DOMAIN" 2> /dev/null || true
    [ -n "$SAVED" ] && printf '%s' "$SAVED" | defaults import "$DOMAIN" -
}
trap restore EXIT
JSON='{"schema":1,"hasCompletedOnboarding":true,"widgets":[{"module":"cpu","enabled":true,"style":"text","interval":5,"visibility":{"always":{}},"showsLabel":true},{"module":"memory","enabled":true,"style":"text","interval":5,"visibility":{"always":{}},"showsLabel":true},{"module":"temperature","enabled":true,"style":"text","interval":5,"visibility":{"always":{}},"showsLabel":true,"warningAt":85,"criticalAt":95}]}'
defaults write "$DOMAIN" "$KEY" -data "$(printf '%s' "$JSON" | xxd -p | tr -d '\n')"
pkill -x jMacosTweaker 2> /dev/null || true
open "$APP"
sleep 10
PID="$(pgrep -x jMacosTweaker)"
cputime() { ps -o cputime= -p "$PID" | awk -F'[:.]' '{ print ($1 * 60) + $2 + ($3 / 100) }'; }
START="$(cputime)"
top -l 2 -s "$SECONDS_TO_RUN" -pid "$PID" -stats cpu,idlew,mem > build/perf-top.txt
END="$(cputime)"
[ -n "${PERF_SAMPLE:-}" ] && sample "$PID" 20 -file build/perf-sample.txt > /dev/null 2>&1
echo "Release, 3 modules, popover closed, $SECONDS_TO_RUN s"
awk -v a="$START" -v b="$END" -v s="$SECONDS_TO_RUN" 'BEGIN { printf "Average CPU: %.3f%% of one core\n", (b - a) / s * 100 }'
echo "RSS: $(($(ps -o rss= -p "$PID") / 1024)) MB"
echo "top, second sample (CPU IDLEW MEM): $(tail -1 build/perf-top.txt)"
