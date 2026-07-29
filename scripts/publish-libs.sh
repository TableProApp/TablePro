#!/usr/bin/env bash
set -euo pipefail

# Publish updated static libraries to the libs-v1 GitHub Release.
#
# Guards against publishing from a stale checkout: every library you did
# NOT name must still match the checksums committed at HEAD. Regenerating
# checksums.sha256 from a stale Libs/ has silently reverted previously
# published libraries before (#1401 reverted the OpenSSL libmongoc from
# #1251 and the DuckDB 1.5.2 bump from #1106).
#
# Usage:
#   scripts/publish-libs.sh <lib.a> [<lib.a> ...]
#
# Example (after rebuilding libmongoc/libbson):
#   scripts/publish-libs.sh libmongoc_arm64.a libmongoc_x86_64.a \
#     libmongoc_universal.a libmongoc.a libbson_arm64.a libbson_x86_64.a \
#     libbson_universal.a libbson.a
#
# Steps:
#   1. Verify all unnamed libs against git HEAD checksums
#   2. Regenerate Libs/checksums.sha256
#   3. Create and upload tablepro-libs-v1.tar.gz (--clobber)
#   4. Remind you to commit checksums.sha256

REPO="TableProApp/TablePro"
LIBS_TAG="libs-v1"
LIBS_ARCHIVE="tablepro-libs-v1.tar.gz"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECKSUMS_FILE="Libs/checksums.sha256"

cd "$PROJECT_DIR"

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <lib.a> [<lib.a> ...]"
    echo "Name every library you rebuilt; all others are verified against HEAD."
    exit 1
fi

declare -a UPDATED=()
for arg in "$@"; do
    UPDATED+=("$(basename "$arg")")
done

is_updated() {
    local name=$1
    for u in "${UPDATED[@]}"; do
        [ "$u" = "$name" ] && return 0
    done
    return 1
}

for name in "${UPDATED[@]}"; do
    if [ ! -f "Libs/$name" ]; then
        echo "❌ Updated library Libs/$name does not exist."
        exit 1
    fi
done

committed_checksums=$(git show "HEAD:$CHECKSUMS_FILE")

echo "🔍 Verifying unchanged libraries against HEAD checksums..."
stale=()
while read -r expected path; do
    [ -n "$path" ] || continue
    name=$(basename "$path")
    is_updated "$name" && continue
    if [ ! -f "$path" ]; then
        stale+=("$path (missing locally)")
        continue
    fi
    actual=$(shasum -a 256 "$path" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        stale+=("$path")
    fi
done <<< "$committed_checksums"

if [ "${#stale[@]}" -gt 0 ]; then
    echo "❌ These libraries differ from the checksums committed at HEAD,"
    echo "   but were not named as updated:"
    for s in "${stale[@]}"; do
        echo "   - $s"
    done
    echo ""
    echo "Your Libs/ checkout is stale or carries unintended changes."
    echo "Run scripts/download-libs.sh --force, re-apply only the libraries"
    echo "you rebuilt, then retry. If a listed library was rebuilt on"
    echo "purpose, pass it as an argument."
    exit 1
fi

new_libs=()
for lib in Libs/*.a; do
    name=$(basename "$lib")
    known=$(awk -v p="Libs/$name" '$2 == p {print $1}' <<< "$committed_checksums")
    if [ -z "$known" ] && ! is_updated "$name"; then
        new_libs+=("$lib")
    fi
done
if [ "${#new_libs[@]}" -gt 0 ]; then
    echo "❌ These libraries are not in the committed checksums and were not"
    echo "   named as updated:"
    for n in "${new_libs[@]}"; do
        echo "   - $n"
    done
    echo "Name them explicitly if they are meant to be published."
    exit 1
fi

unchanged=0
for name in "${UPDATED[@]}"; do
    expected=$(awk -v p="Libs/$name" '$2 == p {print $1}' <<< "$committed_checksums")
    [ -n "$expected" ] || continue
    actual=$(shasum -a 256 "Libs/$name" | awk '{print $1}')
    if [ "$actual" = "$expected" ]; then
        echo "   ℹ️  Libs/$name is identical to the version at HEAD"
        unchanged=$((unchanged + 1))
    fi
done
if [ "$unchanged" -eq "${#UPDATED[@]}" ]; then
    echo "❌ Nothing to publish: every named library matches HEAD."
    exit 1
fi

echo "✅ All unchanged libraries match HEAD"

echo "📝 Regenerating $CHECKSUMS_FILE..."
shasum -a 256 Libs/*.a > "$CHECKSUMS_FILE"

echo "📦 Creating $LIBS_ARCHIVE..."
tar czf "/tmp/$LIBS_ARCHIVE" -C Libs .

echo "☁️  Uploading to $REPO@$LIBS_TAG..."
gh release upload "$LIBS_TAG" "/tmp/$LIBS_ARCHIVE" --clobber --repo "$REPO"
rm -f "/tmp/$LIBS_ARCHIVE"

echo ""
echo "🎉 Published. Now commit the checksum update:"
echo "   git add $CHECKSUMS_FILE && git commit -m \"build: update static library checksums\""
