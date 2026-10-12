#!/usr/bin/env bash
set -euo pipefail

# Writes TablePro/Resources/WhatsNew.md from a version's CHANGELOG lead block, which is the same
# text the Sparkle feed carries. Generated rather than hand-written so the window and the update
# dialog cannot disagree, and so shipping a release does not depend on anyone remembering to edit
# a second file.
#
# Run from the release runbook, after finalizing CHANGELOG.md and before committing.
#
# Usage: scripts/generate-whats-new.sh <version>

VERSION="${1:?Usage: generate-whats-new.sh <version>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$REPO_ROOT/TablePro/Resources/WhatsNew.md"

cd "$REPO_ROOT"

TEMP=$(mktemp)
trap 'rm -f "$TEMP"' EXIT

# --require-lead-block, not the feed's fallback. Without a lead block the fallback is the whole
# section, and 0.74.0's is 270 entries: not something to compile into the app bundle. A release
# with no highlights ships a short pointer instead.
if bash scripts/ci/extract-release-notes.sh "$VERSION" \
     --highlights-only --require-lead-block --out "$TEMP" >/dev/null 2>&1; then
  {
    printf '# TablePro %s\n\n' "$VERSION"
    cat "$TEMP"
  } > "$OUTPUT"
else
  echo "No lead block for $VERSION; writing a pointer to the changelog instead"
  printf '# TablePro %s\n\nThis release is fixes and refinements. Every entry is in the changelog.\n' \
    "$VERSION" > "$OUTPUT"
fi

echo "Wrote $OUTPUT:"
cat "$OUTPUT"
