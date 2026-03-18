#!/usr/bin/env bash
set -euo pipefail

# Download pre-built static libraries from GitHub Releases
# Usage: scripts/download-libs.sh [--force]
#
# Libraries are hosted as a tar.gz on the "libs-v1" release tag
# to avoid Git LFS bandwidth limits.

REPO="datlechin/TablePro"
LIBS_TAG="libs-v1"
LIBS_ARCHIVE="tablepro-libs-v1.tar.gz"
LIBS_DIR="Libs"
MARKER="$LIBS_DIR/.downloaded"

# Skip if already downloaded (unless --force)
if [[ -f "$MARKER" && "${1:-}" != "--force" ]]; then
  echo "Libraries already downloaded. Use --force to re-download."
  exit 0
fi

# Check if libs already exist (local development)
LIB_COUNT=$(find "$LIBS_DIR" -name '*.a' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$LIB_COUNT" -gt 0 && "${1:-}" != "--force" ]]; then
  echo "Found $LIB_COUNT .a files in $LIBS_DIR — skipping download."
  echo "Use --force to re-download."
  exit 0
fi

echo "Downloading static libraries from $REPO@$LIBS_TAG..."

# Download using gh CLI if available, otherwise curl
if command -v gh &>/dev/null; then
  gh release download "$LIBS_TAG" \
    --repo "$REPO" \
    --pattern "$LIBS_ARCHIVE" \
    --dir /tmp \
    --clobber
else
  DOWNLOAD_URL="https://github.com/$REPO/releases/download/$LIBS_TAG/$LIBS_ARCHIVE"
  echo "Downloading from $DOWNLOAD_URL"
  curl -fSL -o "/tmp/$LIBS_ARCHIVE" "$DOWNLOAD_URL"
fi

echo "Extracting to $LIBS_DIR/..."
mkdir -p "$LIBS_DIR"
tar xzf "/tmp/$LIBS_ARCHIVE" -C "$LIBS_DIR"
rm -f "/tmp/$LIBS_ARCHIVE"

# Verify checksums if file exists
if [[ -f "$LIBS_DIR/checksums.sha256" ]]; then
  echo "Verifying checksums..."
  if shasum -a 256 -c "$LIBS_DIR/checksums.sha256" --quiet 2>/dev/null; then
    echo "Checksums OK"
  else
    echo "WARNING: Checksum verification failed!"
    exit 1
  fi
fi

# Mark as downloaded
touch "$MARKER"

LIB_COUNT=$(find "$LIBS_DIR" -name '*.a' | wc -l | tr -d ' ')
echo "Downloaded $LIB_COUNT static libraries."
