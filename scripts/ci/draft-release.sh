#!/usr/bin/env bash
#
# Puts every asset of a release on a draft, for the caller to publish in one last step. Once
# release immutability is on, a published release can never gain, replace or lose an asset.
#
# Usage: draft-release.sh [--target <commit>] [--prerelease true|false] <tag> <title> <notes-file> <asset>...
#
# Writes id=<draft id> to $GITHUB_OUTPUT, or id= when <tag> is already published with these exact
# assets. Fails when <tag> is published with anything else. Without --target the tag must exist.

set -euo pipefail

usage() {
    sed -n 's/^# Usage: //p' "$0" >&2
    exit 2
}

TARGET=""
PRERELEASE="false"
while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            [ $# -ge 2 ] || usage
            TARGET="$2"
            shift 2
            ;;
        --prerelease)
            [ $# -ge 2 ] || usage
            PRERELEASE="$2"
            shift 2
            ;;
        -*) usage ;;
        *) break ;;
    esac
done
[ $# -ge 4 ] || usage
case "$PRERELEASE" in
    true | false) ;;
    *) usage ;;
esac

TAG="$1"
TITLE="$2"
NOTES="$3"
shift 3

for file in "$NOTES" "$@"; do
    if [ ! -f "$file" ]; then
        echo "::error::$file does not exist"
        exit 1
    fi
done

export GH_REPO="${GH_REPO:-${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}}"
OUTPUT="${GITHUB_OUTPUT:-/dev/stdout}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sha256() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

# Only asked once no published release holds the tag: gh races its published and draft lookups.
draft_id() {
    if gh release view "$TAG" --json databaseId,isDraft --jq 'select(.isDraft) | .databaseId' 2> "$WORK/view.err"; then
        return 0
    fi
    if grep -q "release not found" "$WORK/view.err"; then
        return 0
    fi
    cat "$WORK/view.err" >&2
    return 1
}

# 0 when release $1 holds every later argument under its own name, byte for byte; 1 when it does
# not; 2 when the release could not be read.
holds_assets() {
    local id="$1" file name row state digest
    shift
    gh api "repos/$GH_REPO/releases/$id" \
        --jq '.assets[] | [.name, .state, (.digest // "")] | @tsv' > "$WORK/assets.tsv" || return 2
    for file in "$@"; do
        name="$(basename "$file")"
        row="$(awk -F'\t' -v name="$name" '$1 == name { print; exit }' "$WORK/assets.tsv")"
        if [ -z "$row" ]; then
            echo "$TAG has no $name"
            return 1
        fi
        IFS=$'\t' read -r _ state digest <<< "$row"
        if [ "$state" != "uploaded" ]; then
            echo "$name on $TAG is $state"
            return 1
        fi
        # Assets uploaded before GitHub recorded digests carry none.
        if [ -z "$digest" ]; then
            rm -rf "$WORK/download"
            gh release download "$TAG" --pattern "$name" --dir "$WORK/download" || return 2
            digest="sha256:$(sha256 "$WORK/download/$name")"
        fi
        if [ "$digest" != "sha256:$(sha256 "$file")" ]; then
            echo "$name on $TAG is not the file built here"
            return 1
        fi
    done
}

if ! PUBLISHED="$(gh api "repos/$GH_REPO/releases/tags/$TAG" --jq .id 2> "$WORK/tag.err")"; then
    if ! grep -q "HTTP 404" "$WORK/tag.err"; then
        cat "$WORK/tag.err" >&2
        exit 1
    fi
    PUBLISHED=""
fi

if [ -n "$PUBLISHED" ]; then
    STATUS=0
    holds_assets "$PUBLISHED" "$@" || STATUS=$?
    case "$STATUS" in
        0)
            echo "$TAG is already published with these assets"
            echo "id=" >> "$OUTPUT"
            exit 0
            ;;
        1)
            echo "::error::$TAG is already published with other assets, and a published release cannot change them. Ship this build under a new tag."
            exit 1
            ;;
        *) exit 1 ;;
    esac
fi

DRAFT="$(draft_id)"
if [ -n "$DRAFT" ]; then
    # Reused, never deleted: if someone publishes it meanwhile, GitHub refuses the asset upload,
    # while a delete would take the published release with it.
    echo "Reusing draft $DRAFT, left for $TAG by an earlier attempt"
    EDIT=(-f "name=$TITLE" -F "body=@$NOTES" -F "prerelease=$PRERELEASE")
    if [ -n "$TARGET" ]; then
        EDIT+=(-f "target_commitish=$TARGET")
    fi
    gh api --method PATCH "repos/$GH_REPO/releases/$DRAFT" "${EDIT[@]}" > /dev/null
    gh release upload "$TAG" "$@" --clobber
else
    FLAGS=(--draft --title "$TITLE" --notes-file "$NOTES")
    if [ -n "$TARGET" ]; then
        FLAGS+=(--target "$TARGET")
    else
        FLAGS+=(--verify-tag)
    fi
    if [ "$PRERELEASE" = "true" ]; then
        FLAGS+=(--prerelease)
    fi
    gh release create "$TAG" "${FLAGS[@]}" "$@"

    for _ in 1 2 3 4 5; do
        DRAFT="$(draft_id)"
        [ -z "$DRAFT" ] || break
        sleep 2
    done
    if [ -z "$DRAFT" ]; then
        echo "::error::the draft for $TAG was created but cannot be found"
        exit 1
    fi
fi

STATUS=0
holds_assets "$DRAFT" "$@" || STATUS=$?
if [ "$STATUS" -ne 0 ]; then
    echo "::error::draft $DRAFT for $TAG does not hold this build; it stays unpublished"
    exit 1
fi

echo "Draft $DRAFT holds every asset for $TAG"
echo "id=$DRAFT" >> "$OUTPUT"
