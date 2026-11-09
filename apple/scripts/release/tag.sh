#!/usr/bin/env bash
set -euo pipefail

# Usage: tag.sh <tag> <commit>
# apple/RELEASING.md, Tagging: waits for the line's CI push run on <commit>, signs <tag> on it, checks it with
# version.py, pushes it and watches the tag's Release run. A failed check deletes the local tag.

die() {
    echo "tag.sh: $*" >&2
    exit 1
}

if [ $# -ne 2 ]; then
    echo "Usage: tag.sh <tag> <commit>" >&2
    exit 2
fi
TAG="$1"
COMMIT="$2"

cd "$(git rev-parse --show-toplevel)"
LINE="$(python3 apple/scripts/release/version.py parse "$TAG" | sed -n 's/^line=//p')"
git fetch origin --tags
SHA="$(git rev-parse --verify "$COMMIT^{commit}")"

# A push starts its runs a few seconds later.
run_id() {
    local id
    for _ in 1 2 3 4 5 6; do
        id="$(gh run list "$@" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
        if [ -n "$id" ]; then
            echo "$id"
            return 0
        fi
        sleep 10
    done
    return 1
}

CI_RUN="$(run_id --workflow ci.yml --branch "release/$LINE" --event push --commit "$SHA")" \
    || die "no CI push run on release/$LINE at $SHA"
gh run watch "$CI_RUN" --exit-status --interval 30 || die "the CI push run on $SHA did not pass"

git tag -s "$TAG" -m "$TAG" "$SHA"
if ! python3 apple/scripts/release/version.py check "$TAG"; then
    git tag -d "$TAG"
    die "$TAG cannot build; fix the cause and run tag.sh again"
fi
git push origin "$TAG"

RELEASE_RUN="$(run_id --workflow release.yml --branch "$TAG" --event push)" \
    || die "$TAG is pushed, but its Release run has not started: gh run list --workflow release.yml --limit 3"
gh run watch "$RELEASE_RUN" --exit-status --interval 60
