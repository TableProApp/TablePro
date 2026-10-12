#!/usr/bin/env bash
set -euo pipefail

# Signs release archives and publishes them into appcast.xml using Sparkle's generate_appcast,
# the official tool for building Sparkle update feeds.
#
# generate_appcast sees the release being published plus the archives of earlier releases it builds
# deltas from, and writes one item. It is never handed the existing feed, and it never rewrites an
# item it did not create. Everything already published is merged in afterwards by
# scripts/ci/merge-appcast.py, which splices text rather than re-serializing. The reason is in that
# script's docstring: two writes in Sparkle's FeedXML.swift run outside its `if createNewItem`
# guard, so a previously published item that a staged archive happens to match has its download URL
# rewritten and its release notes dropped.
#
# generate_appcast rejects two archives sharing a bundle version in one directory
# (Unarchive.swift:96, SUSparkleErrorDomain 1002, reproduced against 2.9.5 and 2.10.0), so each
# architecture gets its own staging directory and its own generate_appcast run.
#
# Usage: sign-and-appcast.sh <version>
# Requires: SPARKLE_PRIVATE_KEY env var, artifacts/ directory with both architectures' ZIPs,
# and $DELTA_BASES/<arch>/ holding the earlier archives (fetch-delta-bases.sh), which may be empty.
# Optional: CRITICAL_UPDATE=1 to mark the release critical.

BASE_APPCAST="${BASE_APPCAST:-appcast.xml}"
CRITICAL_UPDATE="${CRITICAL_UPDATE:-0}"
DELTA_BASES="${DELTA_BASES:-delta-bases}"
VERSION="${1:?Usage: sign-and-appcast.sh <version>}"

if [ -z "${SPARKLE_PRIVATE_KEY:-}" ]; then
  echo "::error::SPARKLE_PRIVATE_KEY environment variable is not set"
  exit 1
fi

if [ ! -f "$BASE_APPCAST" ]; then
  echo "::error::base appcast $BASE_APPCAST does not exist"
  exit 1
fi

for arch in arm64 x86_64; do
  if [ ! -d "$DELTA_BASES/$arch" ]; then
    echo "::error::$DELTA_BASES/$arch does not exist; run scripts/ci/fetch-delta-bases.sh first"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 1. Extract the notes
# ---------------------------------------------------------------------------
# Two files, for two audiences. release_notes.md is the whole section and becomes the GitHub
# release body, where a reader has scrolled to it on purpose. release_highlights.md is the lead
# block and is what goes in the feed, because an appcast item is downloaded by every install on
# every check and read inside a dialog. 0.73.0's ran 22,443 bytes and 231 list items.
#
# A version with no lead block falls back to the full notes, so this changes nothing until the
# convention is used.
bash "$(dirname "$0")/extract-release-notes.sh" "$VERSION"
bash "$(dirname "$0")/extract-release-notes.sh" "$VERSION" --highlights-only --out release_highlights.md

# ---------------------------------------------------------------------------
# 2. Locate Sparkle tools
# ---------------------------------------------------------------------------
# Pinned and checksum-verified rather than installed from a cask that tracks latest. This step
# holds the EdDSA private key that signs every update every user receives, so it should not run a
# binary whose contents can change between releases. The version matches the Sparkle framework
# pinned in Package.resolved, and check-sparkle-version.py fails Repo Hygiene when they drift.
SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SPARKLE_DIR="$(mktemp -d)"
curl -sSLo "$SPARKLE_DIR/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
echo "$SPARKLE_SHA256  $SPARKLE_DIR/sparkle.tar.xz" | shasum -a 256 -c -
tar xf "$SPARKLE_DIR/sparkle.tar.xz" -C "$SPARKLE_DIR"
SPARKLE_BIN="$SPARKLE_DIR/bin"

DOWNLOAD_PREFIX="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-TableProApp/TablePro}/releases/download/v${VERSION}/"

KEY_FILE=$(mktemp)
STAGING_ROOT=$(mktemp -d)
trap 'rm -rf "$KEY_FILE" "$STAGING_ROOT"' EXIT

echo "$SPARKLE_PRIVATE_KEY" > "$KEY_FILE"

# ---------------------------------------------------------------------------
# 3. Generate one item per architecture, each in its own directory
# ---------------------------------------------------------------------------
generate_item() {
  local arch="$1"
  local zip="artifacts/TablePro-${VERSION}-${arch}.zip"
  local staging="$STAGING_ROOT/$arch"
  local bases=0
  local base

  if [ ! -f "$zip" ]; then
    echo "::error::$zip is missing, so the $arch build produced no update archive"
    return 1
  fi

  mkdir -p "$staging"
  cp "$zip" "$staging/"
  for base in "$DELTA_BASES/$arch"/*; do
    if [ -f "$base" ]; then
      cp "$base" "$staging/"
      bases=$((bases + 1))
    fi
  done

  # Sparkle 2.9 renders Markdown natively, including code and links. Feeding hand-built HTML
  # left Markdown visible and interpreted literal SQL/XML angle brackets as HTML tags.
  #
  # The name matches the archive's, which is how generate_appcast pairs notes to an archive.
  # Without the pairing the item ships with no description at all.
  {
    printf "# What's New in TablePro %s\n\n" "$VERSION"
    cat release_highlights.md
    printf '\n[View full changelog](https://docs.tablepro.app/changelog)\n'
  } > "${staging}/TablePro-${VERSION}-${arch}.md"

  # Sparkle bypasses phasing for a critical item anyway, but passing both would be a contradiction
  # in the feed rather than a belt and braces.
  local flags=()
  if [ "$CRITICAL_UPDATE" = "1" ]; then
    # An empty --critical-update-version writes <sparkle:criticalUpdate/> with no version
    # attribute, which SPUAppcastItemStateResolver treats as critical for every host.
    flags+=(--critical-update-version "")
  else
    # Seven cohorts, so the interval times six is the tail: 21600 puts the last one 36 hours
    # behind, which fits inside the median gap between releases. A user-initiated check is never
    # phased, so Check for Updates always offers the newest build.
    flags+=(--phased-rollout-interval 21600)
  fi

  # --maximum-versions 1 states the invariant merge-appcast.py checks rather than leaving it as a
  # consequence of the directory holding one new archive. The earlier archives only feed deltas.
  "$SPARKLE_BIN/generate_appcast" \
    --ed-key-file "$KEY_FILE" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --embed-release-notes \
    --full-release-notes-url "https://docs.tablepro.app/changelog" \
    --maximum-versions 1 \
    --maximum-deltas "$bases" \
    "${flags[@]}" \
    "$staging"

  if [ ! -f "$staging/appcast.xml" ]; then
    echo "::error::generate_appcast produced no feed for $arch"
    return 1
  fi

  python3 "$(dirname "$0")/name-deltas.py" \
    --staging "$staging" \
    --version "$VERSION" \
    --arch "$arch" \
    --download-prefix "$DOWNLOAD_PREFIX" \
    --expect "$bases" \
    --out-dir artifacts
}

# Building a delta takes about a minute and generate_appcast builds them one at a time, so the two
# architectures run side by side. bash 3.2 on the runners has no associative arrays.
generate_item arm64 > "$STAGING_ROOT/arm64.log" 2>&1 &
ARM64_PID=$!
generate_item x86_64 > "$STAGING_ROOT/x86_64.log" 2>&1 &
X86_64_PID=$!

FAILED=0
for arch in arm64 x86_64; do
  if [ "$arch" = "arm64" ]; then
    pid="$ARM64_PID"
  else
    pid="$X86_64_PID"
  fi
  status=0
  wait "$pid" || status=$?
  echo "::group::generate_appcast $arch"
  cat "$STAGING_ROOT/$arch.log"
  echo "::endgroup::"
  if [ "$status" -ne 0 ]; then
    echo "::error::the $arch item could not be generated (exit $status)"
    FAILED=1
  fi
done
if [ "$FAILED" -ne 0 ]; then
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. Keep both signed items, and merge once here as a gate
# ---------------------------------------------------------------------------
# The items are kept because the merge that actually ships runs later, in the commit step, against
# whatever appcast.xml main holds at that moment. Merging only here meant merging into a snapshot
# taken minutes earlier and then copying the result over main, so a withdrawal pushed in between
# was silently reverted and the pulled build was offered again.
#
# This merge still runs, against the snapshot, because it is the cheapest place to refuse a release:
# it happens before the GitHub Release publishes any artifact. Every invariant worth checking lives
# in merge-appcast.py, which scripts/ci/test_merge_appcast.py covers on the Linux runner, because a
# real release is the only thing that runs this script.
mkdir -p appcast/items
cp "$STAGING_ROOT/arm64/appcast.xml" appcast/items/arm64.xml
cp "$STAGING_ROOT/x86_64/appcast.xml" appcast/items/x86_64.xml

python3 "$(dirname "$0")/merge-appcast.py" \
  --base "$BASE_APPCAST" \
  --version "$VERSION" \
  --arm64 appcast/items/arm64.xml \
  --x86-64 appcast/items/x86_64.xml \
  --download-prefix "$DOWNLOAD_PREFIX" \
  --out appcast/appcast.xml

echo "✅ Appcast validated for $VERSION:"
head -c 4000 appcast/appcast.xml
