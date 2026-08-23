#!/usr/bin/env bash
set -euo pipefail

# Download the pre-built static libraries from GitHub Releases.
# Usage: scripts/download-libs.sh [--force]
#
# Libraries are hosted as tarballs on the "libs-v1" release tag rather than in git, to avoid
# Git LFS bandwidth limits. Two archives: the macOS .a files, and the iOS xcframeworks.
#
# Whatever ends up in Libs/ is verified against the baseline committed in git, on every run,
# including runs that download nothing. These libraries are force_loaded into a signed and
# notarized app, so "we already have some files, skip the check" is not a safe shortcut.

REPO="TableProApp/TablePro"
LIBS_TAG="libs-v1"
LIBS_ARCHIVE="tablepro-libs-v1.tar.gz"
IOS_ARCHIVE="tablepro-libs-ios-v1.tar.gz"
LIBS_DIR="Libs"
IOS_DIR="$LIBS_DIR/ios"
MARKER="$LIBS_DIR/.downloaded"
IOS_MARKER="$IOS_DIR/.downloaded"
FORCE="${1:-}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The baseline comes from git, never from the extracted copy. Each archive bundles its own
# checksums file and extraction overwrites the working one, so verifying against that is
# self-referential: a tampered release ships matching checksums and passes. Captured up front,
# before anything is extracted, for the same reason.
capture_baseline() {
    local tracked="$1" out="$2"
    git rev-parse --is-inside-work-tree &> /dev/null || return 0
    git cat-file -e "HEAD:$tracked" 2> /dev/null || return 0
    git show "HEAD:$tracked" > "$out"
}

capture_baseline "$LIBS_DIR/checksums.sha256" "$WORK/macos-baseline"
capture_baseline "$IOS_DIR/checksums.sha256" "$WORK/ios-baseline"

fetch() {
    local archive="$1" dest="$2"
    if command -v gh &> /dev/null; then
        gh release download "$LIBS_TAG" --repo "$REPO" --pattern "$archive" --dir "$dest" --clobber
    else
        curl -fSL -o "$dest/$archive" "https://github.com/$REPO/releases/download/$LIBS_TAG/$archive"
    fi
}

# The two baselines use different path conventions, so each names the directory to run from:
# Libs/checksums.sha256 holds "Libs/..." paths and is checked from the repo root, while
# Libs/ios/checksums.sha256 holds "./..." paths and is checked from inside Libs/ios.
verify() {
    local run_from="$1" dir="$2" baseline="$3" label="$4"
    if [[ ! -s "$baseline" ]]; then
        echo "WARNING: no trusted $label baseline at HEAD; skipping integrity verification." >&2
        return 0
    fi
    echo "Verifying $label against the baseline committed in git..."
    if (cd "$run_from" && shasum -a 256 -c "$baseline" --quiet 2> /dev/null); then
        echo "  $label OK"
        return 0
    fi
    echo "ERROR: $dir does not match the checksums committed in git." >&2
    echo "       The archive may be corrupt or tampered with." >&2
    echo "       If you rebuilt a library on purpose, publish it so the baseline moves with it:" >&2
    echo "         scripts/publish-libs.sh <lib>.a     for the macOS libraries" >&2
    echo "         scripts/publish-ios-libs.sh         for the iOS xcframeworks" >&2
    return 1
}

# --- macOS static libraries ---

if [[ -f "$MARKER" && "$FORCE" != "--force" ]]; then
    echo "macOS libraries already present."
elif [[ "$(find "$LIBS_DIR" -maxdepth 1 -name '*.a' 2> /dev/null | wc -l | tr -d ' ')" -gt 0 && "$FORCE" != "--force" ]]; then
    echo "Found existing .a files in $LIBS_DIR."
else
    echo "Downloading macOS static libraries from $REPO@$LIBS_TAG..."
    fetch "$LIBS_ARCHIVE" "$WORK"
    mkdir -p "$LIBS_DIR"
    tar xzf "$WORK/$LIBS_ARCHIVE" -C "$LIBS_DIR"
    touch "$MARKER"
    echo "Downloaded $(find "$LIBS_DIR" -maxdepth 1 -name '*.a' | wc -l | tr -d ' ') static libraries."
fi

verify "." "$LIBS_DIR" "$WORK/macos-baseline" "macOS libraries"

# --- iOS xcframeworks ---

if [[ -f "$IOS_MARKER" && "$FORCE" != "--force" ]]; then
    echo "iOS xcframeworks already present."
elif [[ "$(find "$IOS_DIR" -maxdepth 1 -name '*.xcframework' 2> /dev/null | wc -l | tr -d ' ')" -gt 0 && "$FORCE" != "--force" ]]; then
    echo "Found existing xcframeworks in $IOS_DIR."
else
    echo "Downloading iOS xcframeworks..."
    fetch "$IOS_ARCHIVE" "$WORK"
    mkdir -p "$IOS_DIR"
    tar xzf "$WORK/$IOS_ARCHIVE" -C "$IOS_DIR"
    touch "$IOS_MARKER"
    echo "Downloaded $(find "$IOS_DIR" -maxdepth 1 -name '*.xcframework' | wc -l | tr -d ' ') iOS xcframeworks."
fi

verify "$IOS_DIR" "$IOS_DIR" "$WORK/ios-baseline" "iOS xcframeworks"

# --- OpenSSL shared dylibs, built from the verified static libraries ---

if [[ -f "$LIBS_DIR/libcrypto_arm64.a" || -f "$LIBS_DIR/libcrypto.a" ]]; then
    echo "Creating OpenSSL shared dylibs for local development..."
    scripts/create-openssl-dylibs.sh both
else
    echo "Skipping OpenSSL dylibs (no static libs found yet)."
fi
