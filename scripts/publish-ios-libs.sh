#!/usr/bin/env bash
set -euo pipefail

# Publishes Libs/ios to the libs-v1 release and regenerates the integrity baseline.
#
# Usage: scripts/publish-ios-libs.sh [--dry-run]
#
# CLAUDE.md used to document this as a bare `tar czf ... && gh release upload`, which published
# 299 MB of xcframeworks that nothing verified and left no baseline behind. download-libs.sh now
# checks Libs/ios against Libs/ios/checksums.sha256 on every run, so the archive and the baseline
# have to move together or every developer and every CI job fails on the next pull.
#
# Run this after rebuilding with scripts/ios/build-*.sh, then commit the refreshed baseline.

REPO="TableProApp/TablePro"
LIBS_TAG="libs-v1"
IOS_ARCHIVE="tablepro-libs-ios-v1.tar.gz"
IOS_DIR="Libs/ios"
CHECKSUMS="$IOS_DIR/checksums.sha256"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

[ -d "$IOS_DIR" ] || { echo "❌ $IOS_DIR does not exist." >&2; exit 1; }

frameworks=()
while IFS= read -r fw; do
    frameworks+=("$(basename "$fw")")
done < <(find "$IOS_DIR" -maxdepth 1 -name '*.xcframework' | LC_ALL=C sort)

if [ "${#frameworks[@]}" -eq 0 ]; then
    echo "❌ No xcframeworks in $IOS_DIR. Build them first with scripts/ios/build-*.sh." >&2
    exit 1
fi

echo "📦 ${#frameworks[@]} xcframeworks: ${frameworks[*]}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# LC_ALL=C so the committed file is byte-stable across machines and locales.
generate_baseline() {
    (cd "$IOS_DIR" && find . -type f ! -name '.downloaded' ! -name 'checksums.sha256' -print0 |
        LC_ALL=C sort -z | xargs -0 shasum -a 256)
}

generate_baseline > "$WORK/new-baseline"
echo "🔢 $(wc -l < "$WORK/new-baseline" | tr -d ' ') files hashed"

# Report what moved, so an accidental rebuild of everything is visible before it is published.
if git cat-file -e "HEAD:$CHECKSUMS" 2> /dev/null; then
    git show "HEAD:$CHECKSUMS" > "$WORK/old-baseline"
    added=$(comm -13 <(awk '{print $2}' "$WORK/old-baseline" | LC_ALL=C sort) \
        <(awk '{print $2}' "$WORK/new-baseline" | LC_ALL=C sort) | wc -l | tr -d ' ')
    removed=$(comm -23 <(awk '{print $2}' "$WORK/old-baseline" | LC_ALL=C sort) \
        <(awk '{print $2}' "$WORK/new-baseline" | LC_ALL=C sort) | wc -l | tr -d ' ')
    changed=$(comm -13 <(LC_ALL=C sort "$WORK/old-baseline") <(LC_ALL=C sort "$WORK/new-baseline") | wc -l | tr -d ' ')
    changed=$((changed - added))
    echo "   vs HEAD: $changed changed, $added added, $removed removed"
    if [ "$changed" -eq 0 ] && [ "$added" -eq 0 ] && [ "$removed" -eq 0 ]; then
        echo "❌ Nothing to publish: $IOS_DIR is identical to the baseline at HEAD." >&2
        exit 1
    fi
else
    echo "   no baseline at HEAD yet; this publish establishes it"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo "🧪 --dry-run: not writing $CHECKSUMS and not uploading."
    exit 0
fi

cp "$WORK/new-baseline" "$CHECKSUMS"
echo "📝 Wrote $CHECKSUMS"

# An allowlist, so the archive holds exactly what the baseline covers and no stray markers.
tar czf "$WORK/$IOS_ARCHIVE" -C "$IOS_DIR" "${frameworks[@]}" "$(basename "$CHECKSUMS")"
echo "📦 $IOS_ARCHIVE is $(du -h "$WORK/$IOS_ARCHIVE" | cut -f1)"

echo "☁️  Uploading to $REPO@$LIBS_TAG..."
gh release upload "$LIBS_TAG" "$WORK/$IOS_ARCHIVE" --clobber --repo "$REPO"

echo ""
echo "🎉 Published. Now commit the baseline so download-libs.sh accepts it:"
echo "   git add $CHECKSUMS && git commit -m 'build: update iOS xcframework checksums'"
