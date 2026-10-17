#!/usr/bin/env bash
set -euo pipefail

# Publishes Libs/*.a and Libs/ios/*.xcframework as the next immutable libs-<n> release, then
# writes Libs/release and both checksum files for you to commit together.
#
# Usage: scripts/publish-libs.sh [--dry-run] <lib.a | Name.xcframework>...
#
# Name every library you rebuilt, added or removed. Every other one must match the checksums
# committed at HEAD, so a stale Libs/ cannot revert a library someone else published.

REPO="TableProApp/TablePro"
MAC_DIR="Libs"
IOS_DIR="Libs/ios"
MAC_SUMS="$MAC_DIR/checksums.sha256"
IOS_SUMS="$IOS_DIR/checksums.sha256"
PIN="Libs/release"

cd "$(dirname "$0")/.."

usage() {
    echo "Usage: scripts/publish-libs.sh [--dry-run] <lib.a | Name.xcframework>..." >&2
    echo "Name every library you rebuilt; every other one is verified against HEAD." >&2
    exit 2
}

fail() {
    echo "error: $1" >&2
    shift
    for line in "$@"; do
        echo "       $line" >&2
    done
    exit 1
}

DRY_RUN=0
NAMED=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -*) usage ;;
        *.a | *.xcframework) NAMED+=("$(basename "$arg")") ;;
        *) usage ;;
    esac
done
[ "${#NAMED[@]}" -gt 0 ] || usage

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PINNED="$(git show "HEAD:$PIN")"
git show "HEAD:$MAC_SUMS" > "$WORK/mac.old"
git show "HEAD:$IOS_SUMS" > "$WORK/ios.old"

MAC_MEMBERS=()
for lib in "$MAC_DIR"/*.a; do
    [ -e "$lib" ] || [ -L "$lib" ] || continue
    # A worktree links each library to another checkout, and tar would archive the link.
    if [ -L "$lib" ]; then
        case "$(readlink "$lib")" in
            */*) fail "$lib links outside $MAC_DIR." "Publish from a checkout that holds the files; scripts/download-libs.sh --force replaces the links." ;;
        esac
    fi
    MAC_MEMBERS+=("$(basename "$lib")")
done
IOS_MEMBERS=()
for framework in "$IOS_DIR"/*.xcframework; do
    [ -e "$framework" ] || [ -L "$framework" ] || continue
    IOS_MEMBERS+=("$(basename "$framework")")
done
[ "${#MAC_MEMBERS[@]}" -gt 0 ] || fail "no $MAC_DIR/*.a to publish."
[ "${#IOS_MEMBERS[@]}" -gt 0 ] || fail "no $IOS_DIR/*.xcframework to publish."
if [ -n "$(find "$IOS_DIR" -type l)" ]; then
    fail "$IOS_DIR holds symlinks, which its checksums cannot cover." "Publish from a checkout that holds the files; scripts/download-libs.sh --force replaces the links."
fi

shasum -a 256 "$MAC_DIR"/*.a > "$WORK/mac.new"
(cd "$IOS_DIR" && find ./*.xcframework -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) > "$WORK/ios.new"

# A unit is one .a or one .xcframework: the second path component of a checksum line.
units_of() {
    awk '{ split($2, part, "/"); print part[2] }' "$@" | LC_ALL=C sort -u
}

cat "$WORK/mac.old" "$WORK/ios.old" | LC_ALL=C sort > "$WORK/old"
cat "$WORK/mac.new" "$WORK/ios.new" | LC_ALL=C sort > "$WORK/new"
units_of "$WORK/old" > "$WORK/old.units"
units_of "$WORK/new" > "$WORK/new.units"
LC_ALL=C comm -3 "$WORK/old" "$WORK/new" | tr -d '\t' | units_of > "$WORK/changed"
printf '%s\n' "${NAMED[@]}" | LC_ALL=C sort -u > "$WORK/named"
LC_ALL=C sort -u "$WORK/old.units" "$WORK/new.units" | LC_ALL=C comm -13 - "$WORK/named" > "$WORK/unknown"
LC_ALL=C comm -23 "$WORK/changed" "$WORK/named" > "$WORK/unnamed"

if [ -s "$WORK/unknown" ]; then
    fail "neither Libs/ nor HEAD has $(paste -sd ' ' "$WORK/unknown")."
fi

stale=()
while IFS= read -r unit; do
    if ! grep -qxF "$unit" "$WORK/new.units"; then
        stale+=("$unit (missing locally)")
    elif ! grep -qxF "$unit" "$WORK/old.units"; then
        stale+=("$unit (not at HEAD)")
    else
        stale+=("$unit (differs from HEAD)")
    fi
done < "$WORK/unnamed"
if [ "${#stale[@]}" -gt 0 ]; then
    fail "these differ from the checksums committed at HEAD but were not named:" "${stale[@]}" \
        "Run scripts/download-libs.sh --force, re-apply only what you rebuilt, then retry." \
        "Name a library here if it changed on purpose."
fi

REBUILT="$(LC_ALL=C comm -12 "$WORK/changed" "$WORK/named")"
identical="$(LC_ALL=C comm -23 "$WORK/named" "$WORK/changed" | paste -sd ' ' -)"
[ -z "$identical" ] || echo "note: identical to HEAD: $identical"

[ "$(gh api "repos/$REPO/immutable-releases" --jq .enabled)" = "true" ] \
    || fail "immutable releases are off for $REPO." "Turn them on in the repository settings, then retry."

gh api "repos/$REPO/releases?per_page=100" --paginate \
    --jq '.[] | select(.tag_name | startswith("libs-")) | [.tag_name, .draft, .immutable] | @tsv' > "$WORK/releases"
gh api "repos/$REPO/git/matching-refs/tags/libs-" --paginate --jq '.[].ref | ltrimstr("refs/tags/")' > "$WORK/tags"

draft="$(awk -F'\t' '$2 == "true" { print $1 }' "$WORK/releases" | paste -sd ' ' -)"
[ -z "$draft" ] || fail "a libs release is still a draft: $draft." \
    "Delete each with: gh release delete <tag> --repo $REPO --yes"

number_of() {
    sed -n 's/^libs-v\{0,1\}\([0-9][0-9]*\)$/\1/p' | sort -n | tail -1
}
newest_release="$(awk -F'\t' '$2 == "false" { print $1 }' "$WORK/releases" | number_of)"
[ "$(echo "$PINNED" | number_of)" = "$newest_release" ] \
    || fail "HEAD pins $PINNED, but libs-$newest_release is newer." "Merge origin/main first, so this release builds on it."

if [ -z "$REBUILT" ]; then
    # Moving identical libraries is only worth a release number when it leaves a mutable release.
    pinned_immutable="$(awk -F'\t' -v tag="$PINNED" '$1 == tag { print $3 }' "$WORK/releases")"
    [ "$pinned_immutable" = "false" ] || fail "nothing to publish: every named library matches $PINNED."
fi

last="$( (cut -f1 "$WORK/releases"; cat "$WORK/tags") | number_of)"
TAG="libs-$((${last:-0} + 1))"
MAC_ARCHIVE="tablepro-libs-${TAG#libs-}.tar.gz"
IOS_ARCHIVE="tablepro-libs-ios-${TAG#libs-}.tar.gz"

# Only the files the checksums cover: macOS tar would add AppleDouble entries and xattrs.
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$WORK/$MAC_ARCHIVE" -C "$MAC_DIR" "${MAC_MEMBERS[@]}"
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$WORK/$IOS_ARCHIVE" -C "$IOS_DIR" "${IOS_MEMBERS[@]}"

if [ -z "$REBUILT" ]; then
    NOTES="The libraries of $PINNED, unchanged."
else
    NOTES="Rebuilt since $PINNED: $(echo "$REBUILT" | paste -sd ' ' -)."
fi

echo "$TAG: ${#MAC_MEMBERS[@]} macOS libraries, ${#IOS_MEMBERS[@]} iOS xcframeworks. $NOTES"
for archive in "$MAC_ARCHIVE" "$IOS_ARCHIVE"; do
    echo "  $archive $(du -h "$WORK/$archive" | cut -f1)"
done

if [ "$DRY_RUN" -eq 1 ]; then
    echo "--dry-run: nothing created or written."
    exit 0
fi

# Assets cannot be added once an immutable release is published, so it goes up as a draft first.
gh release create "$TAG" --repo "$REPO" --draft --latest=false --title "$TAG" --notes "$NOTES" \
    "$WORK/$MAC_ARCHIVE" "$WORK/$IOS_ARCHIVE"
gh release edit "$TAG" --repo "$REPO" --draft=false --latest=false

immutable=""
for attempt in 1 2 3; do
    immutable="$(gh api "repos/$REPO/releases/tags/$TAG" --jq .immutable || true)"
    if [ "$immutable" = "true" ] || [ "$attempt" -eq 3 ]; then
        break
    fi
    sleep 3
done
[ "$immutable" = "true" ] \
    || fail "$TAG was published, but GitHub does not report it immutable, so nothing was written." \
        "Check with: gh release view $TAG --repo $REPO --json isImmutable"

cp "$WORK/mac.new" "$MAC_SUMS"
cp "$WORK/ios.new" "$IOS_SUMS"
echo "$TAG" > "$PIN"
echo "$TAG" > "$MAC_DIR/.downloaded"
echo "$TAG" > "$IOS_DIR/.downloaded"

echo "Published $TAG. Commit the pin and the checksums together:"
echo "  git add $PIN $MAC_SUMS $IOS_SUMS && git commit -m 'build(libs): publish $TAG'"
