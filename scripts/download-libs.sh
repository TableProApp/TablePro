#!/usr/bin/env bash
set -euo pipefail

# Download pre-built static libraries from GitHub Releases
# Usage: scripts/download-libs.sh [--force]
#
# Libraries are hosted as a tar.gz on the "libs-v1" release tag
# to avoid Git LFS bandwidth limits.

REPO="TableProApp/TablePro"
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

LIB_COUNT=$(find "$LIBS_DIR" -maxdepth 1 -name '*.a' | wc -l | tr -d ' ')
echo "Downloaded $LIB_COUNT static libraries."

# --- OpenSSL shared dylibs ---
echo "Creating OpenSSL shared dylibs for local development..."
if [[ -f "$LIBS_DIR/libcrypto_arm64.a" || -f "$LIBS_DIR/libcrypto.a" ]]; then
  scripts/create-openssl-dylibs.sh both
else
  echo "Skipping OpenSSL dylibs (no static libs found yet)."
fi

# --- iOS xcframeworks ---
IOS_ARCHIVE="tablepro-libs-ios-v1.tar.gz"
IOS_DIR="$LIBS_DIR/ios"
IOS_MARKER="$IOS_DIR/.downloaded"

if [[ -f "$IOS_MARKER" && "${1:-}" != "--force" ]]; then
  echo "iOS libraries already downloaded."
elif [[ -d "$IOS_DIR" && "$(find "$IOS_DIR" -name '*.xcframework' -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" -gt 0 && "${1:-}" != "--force" ]]; then
  echo "Found xcframeworks in $IOS_DIR — skipping iOS download."
else
  echo "Downloading iOS static libraries..."
  if command -v gh &>/dev/null; then
    gh release download "$LIBS_TAG" \
      --repo "$REPO" \
      --pattern "$IOS_ARCHIVE" \
      --dir /tmp \
      --clobber
  else
    curl -fSL -o "/tmp/$IOS_ARCHIVE" "https://github.com/$REPO/releases/download/$LIBS_TAG/$IOS_ARCHIVE"
  fi
  mkdir -p "$IOS_DIR"
  tar xzf "/tmp/$IOS_ARCHIVE" -C "$IOS_DIR"
  rm -f "/tmp/$IOS_ARCHIVE"
  touch "$IOS_MARKER"
  FW_COUNT=$(find "$IOS_DIR" -name '*.xcframework' -maxdepth 1 | wc -l | tr -d ' ')
  echo "Downloaded $FW_COUNT iOS xcframeworks."
fi
