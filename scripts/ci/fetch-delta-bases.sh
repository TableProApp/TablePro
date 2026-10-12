#!/usr/bin/env bash
#
# Downloads the update archives of the newest published releases other than <tag>, into
# <dest>/arm64 and <dest>/x86_64, for sign-and-appcast.sh to build deltas from.
#
# Usage: fetch-delta-bases.sh <tag> <count> <dest>

set -euo pipefail

TAG="${1:?Usage: fetch-delta-bases.sh <tag> <count> <dest>}"
COUNT="${2:?Usage: fetch-delta-bases.sh <tag> <count> <dest>}"
DEST="${3:?Usage: fetch-delta-bases.sh <tag> <count> <dest>}"

case "$COUNT" in
    '' | *[!0-9]*)
        echo "::error::count '$COUNT' is not a number"
        exit 2
        ;;
esac

export GH_REPO="${GH_REPO:-${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}}"

mkdir -p "$DEST/arm64" "$DEST/x86_64"

# Plugin releases share the list, so the limit has to reach past a bulk plugin release.
TAGS="$(gh release list --limit 400 --exclude-drafts --json tagName,isPrerelease,publishedAt \
    -q '[.[] | select(.tagName|startswith("v")) | select(.isPrerelease==false)]
        | sort_by(.publishedAt) | reverse | .[].tagName')"

PICKED=0
while IFS= read -r tag; do
    if [ -z "$tag" ] || [ "$tag" = "$TAG" ]; then
        continue
    fi
    if [ "$PICKED" -ge "$COUNT" ]; then
        break
    fi
    for arch in arm64 x86_64; do
        gh release download "$tag" --pattern "TablePro-${tag#v}-${arch}.zip" --dir "$DEST/$arch"
    done
    PICKED=$((PICKED + 1))
done <<EOF
$TAGS
EOF

echo "Delta bases from $PICKED release(s):"
ls -l "$DEST/arm64" "$DEST/x86_64"
