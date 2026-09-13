#!/usr/bin/env bash
set -euo pipefail

# Signs release archives and publishes them into appcast.xml using Sparkle's generate_appcast,
# the official tool for building Sparkle update feeds.
#
# generate_appcast only ever sees the release being published. It is never handed the existing
# feed, and it never rewrites an item it did not create. Everything already published is merged
# in afterwards by scripts/ci/merge-appcast.py, which splices text rather than re-serializing.
# The reason is in that script's docstring: two writes in Sparkle's FeedXML.swift run outside its
# `if createNewItem` guard, so a previously published item that a staged archive happens to match
# has its download URL rewritten and its release notes dropped.
#
# Sparkle 2.9+ rejects two archives sharing a bundle version in one directory, so each
# architecture gets its own staging directory and its own generate_appcast run.
#
# Usage: sign-and-appcast.sh <version>
# Requires: SPARKLE_PRIVATE_KEY env var, artifacts/ directory with both architectures' ZIPs.

BASE_APPCAST="${BASE_APPCAST:-appcast.xml}"
VERSION="${1:?Usage: sign-and-appcast.sh <version>}"

if [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
  echo "::error::SPARKLE_PRIVATE_KEY environment variable is not set"
  exit 1
fi

if [ ! -f "$BASE_APPCAST" ]; then
  echo "::error::base appcast $BASE_APPCAST does not exist"
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Extract the same version-specific notes used by the GitHub release
# ---------------------------------------------------------------------------
bash "$(dirname "$0")/extract-release-notes.sh" "$VERSION"

# ---------------------------------------------------------------------------
# 2. Locate Sparkle tools
# ---------------------------------------------------------------------------
# Pinned and checksum-verified rather than installed from a cask that tracks latest. This step
# holds the EdDSA private key that signs every update every user receives, so it should not run a
# binary whose contents can change between releases. The version matches the Sparkle framework
# pinned in Package.resolved, so both move together.
SPARKLE_VERSION="2.9.5"
SPARKLE_SHA256="015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc"
SPARKLE_DIR="$(mktemp -d)"
curl -sSLo "$SPARKLE_DIR/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
echo "$SPARKLE_SHA256  $SPARKLE_DIR/sparkle.tar.xz" | shasum -a 256 -c -
tar xf "$SPARKLE_DIR/sparkle.tar.xz" -C "$SPARKLE_DIR"
SPARKLE_BIN="$SPARKLE_DIR/bin"

DOWNLOAD_PREFIX="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-TableProApp/TablePro}/releases/download/v${VERSION}/"

KEY_FILE=$(mktemp)
trap 'rm -rf "$KEY_FILE"' EXIT

echo "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"

# ---------------------------------------------------------------------------
# 3. Generate one item per architecture, each from an otherwise empty directory
# ---------------------------------------------------------------------------
# Two plain variables rather than an associative array: the macOS runners still ship bash 3.2,
# where `declare -A` is a syntax error.
ARM64_APPCAST=""
X86_64_APPCAST=""

for arch in arm64 x86_64; do
  ZIP="artifacts/TablePro-${VERSION}-${arch}.zip"
  if [ ! -f "$ZIP" ]; then
    echo "::error::$ZIP is missing, so the $arch build produced no update archive"
    exit 1
  fi

  STAGING=$(mktemp -d)
  cp "$ZIP" "$STAGING/"

  # Sparkle 2.9 renders Markdown natively, including code and links. Feeding hand-built HTML
  # left Markdown visible and interpreted literal SQL/XML angle brackets as HTML tags.
  #
  # The name matches the archive's, which is how generate_appcast pairs notes to an archive.
  # Without the pairing the item ships with no description at all.
  {
    printf "# What's New in TablePro %s\n\n" "$VERSION"
    cat release_notes.md
    printf '\n[View full changelog](https://docs.tablepro.app/changelog)\n'
  } > "${STAGING}/TablePro-${VERSION}-${arch}.md"

  "$SPARKLE_BIN/generate_appcast" \
    --ed-key-file "$KEY_FILE" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --embed-release-notes \
    --full-release-notes-url "https://docs.tablepro.app/changelog" \
    --maximum-versions 0 \
    "$STAGING"

  if [ ! -f "$STAGING/appcast.xml" ]; then
    echo "::error::generate_appcast produced no feed for $arch"
    exit 1
  fi
  if [ "$arch" = "arm64" ]; then
    ARM64_APPCAST="$STAGING/appcast.xml"
  else
    X86_64_APPCAST="$STAGING/appcast.xml"
  fi
done

# ---------------------------------------------------------------------------
# 4. Splice both items into the published feed
# ---------------------------------------------------------------------------
# Every invariant worth checking lives in merge-appcast.py, which is covered by
# scripts/ci/test_merge_appcast.py on the Linux runner. This script is only ever exercised by a
# real release, so the checks belong somewhere a pull request can run them.
mkdir -p appcast
python3 "$(dirname "$0")/merge-appcast.py" \
  --base "$BASE_APPCAST" \
  --version "$VERSION" \
  --arm64 "$ARM64_APPCAST" \
  --x86-64 "$X86_64_APPCAST" \
  --download-prefix "$DOWNLOAD_PREFIX" \
  --out appcast/appcast.xml

echo "✅ Appcast published for $VERSION:"
head -c 4000 appcast/appcast.xml
