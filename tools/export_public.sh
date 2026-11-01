#!/bin/bash
# Copies the allowlisted files to the public folder. Anything not in tools/export_manifest.txt is never copied.
#
#   tools/export_public.sh --dry-run            lists what would be copied and checks it for private strings
#   tools/export_public.sh --execute <folder>   copies it. The folder is always named explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"
case "$MODE" in
    --dry-run) ;;
    --execute) [ $# -eq 2 ] || { echo "usage: $0 --execute <folder>" >&2; exit 2; } ;;
    *) echo "usage: $0 --dry-run | --execute <folder>" >&2; exit 2 ;;
esac

FILES="$(mktemp)"
trap 'rm -f "$FILES"' EXIT
while IFS= read -r entry; do
    case "$entry" in ''|'#'*) continue ;; esac
    [ -e "$entry" ] || { echo "error: allowlisted path missing: $entry" >&2; exit 1; }
    find "$entry" -type f ! -name '.DS_Store' >> "$FILES"
done < tools/export_manifest.txt
sort -o "$FILES" "$FILES"

# Nothing internal may slip through, even if the allowlist is edited carelessly.
if grep -E '(^|/)(dev-notes|build|DerivedData|\.git)(/|$)|\.log$|\.xcodeproj' "$FILES"; then
    echo "error: excluded material is on the list" >&2
    exit 1
fi
# Personal details and references to internal notes. Machine-specific patterns stay in an unexported file.
PRIVATE='/Users/|dev-notes|@gmail\.com'
if [ -f dev-notes/private_patterns.txt ]; then
    while IFS= read -r pattern; do
        case "$pattern" in ''|'#'*) continue ;; esac
        PRIVATE="$PRIVATE|$pattern"
    done < dev-notes/private_patterns.txt
fi
FOUND="$(xargs -I{} grep -IlE "$PRIVATE" {} < "$FILES" | grep -v '^tools/export_public.sh$' || true)"
if [ -n "$FOUND" ]; then
    echo "error: private strings found in:" >&2
    echo "$FOUND" >&2
    exit 1
fi
if grep -IE "$PRIVATE" tools/export_public.sh | grep -vE "^PRIVATE=|dev-notes" > /dev/null; then
    echo "error: private strings found in tools/export_public.sh" >&2
    exit 1
fi

if [ "$MODE" = "--dry-run" ]; then
    cat "$FILES"
    echo "Dry run: $(wc -l < "$FILES" | tr -d ' ') files, private string check passed. Nothing was copied."
    exit 0
fi

DEST="$2"
mkdir -p "$DEST"
rsync -a --files-from="$FILES" ./ "$DEST"/
echo "Copied $(wc -l < "$FILES" | tr -d ' ') files to $DEST"
