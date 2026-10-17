#!/usr/bin/env bash
set -euo pipefail

# Downloads the libs-<n> release that Libs/release names, then verifies Libs/ against the checksums
# committed at HEAD. The check runs on every run, including one that downloads nothing: these
# libraries are force_loaded into a signed and notarized app.
#
# Usage: scripts/download-libs.sh [--force]

REPO="TableProApp/TablePro"
LIBS_DIR="Libs"
IOS_DIR="$LIBS_DIR/ios"
FORCE="${1:-}"
if [[ -n "$FORCE" && "$FORCE" != "--force" ]]; then
    echo "Usage: scripts/download-libs.sh [--force]" >&2
    exit 2
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The pin and the baselines come from git, read before anything is extracted: a libs-v1 archive
# carries its own checksums file, and checking against that would pass a tampered archive.
tracked() {
    if git rev-parse --is-inside-work-tree &> /dev/null; then
        git show "HEAD:$1"
    else
        cat "$1"
    fi
}

LIBS_TAG="$(tracked "$LIBS_DIR/release")"
if [[ ! "$LIBS_TAG" =~ ^libs-v?[0-9]+$ ]]; then
    echo "ERROR: $LIBS_DIR/release holds '$LIBS_TAG', not a libs-<n> tag." >&2
    exit 1
fi
tracked "$LIBS_DIR/checksums.sha256" > "$WORK/macos-baseline"
tracked "$IOS_DIR/checksums.sha256" > "$WORK/ios-baseline"

fetch() {
    local archive="$1"
    if command -v gh &> /dev/null; then
        gh release download "$LIBS_TAG" --repo "$REPO" --pattern "$archive" --dir "$WORK" --clobber
    else
        curl -fSL -o "$WORK/$archive" "https://github.com/$REPO/releases/download/$LIBS_TAG/$archive"
    fi
}

# Libs/checksums.sha256 holds "Libs/..." paths and is checked from the repo root;
# Libs/ios/checksums.sha256 holds "./..." paths and is checked from inside Libs/ios.
verify() {
    local run_from="$1" dir="$2" baseline="$3" label="$4"
    echo "Verifying $label against the checksums committed in git..."
    if (cd "$run_from" && shasum -a 256 -c "$baseline" --quiet 2> /dev/null); then
        echo "  $label OK"
        return 0
    fi
    echo "ERROR: $dir does not match the checksums committed in git." >&2
    echo "       Run scripts/download-libs.sh --force first. A library rebuilt on purpose" >&2
    echo "       is published with scripts/publish-libs.sh as the next libs-<n> release." >&2
    return 1
}

# The marker names the release Libs/ came from, so a new pin downloads again.
sync_libs() {
    local label="$1" dir="$2" archive="$3" unit="$4" run_from="$5" baseline="$6"
    local marker="$dir/.downloaded"
    if [[ "$FORCE" != "--force" && "$(cat "$marker" 2> /dev/null)" == "$LIBS_TAG" ]]; then
        echo "$label from $LIBS_TAG already present."
        verify "$run_from" "$dir" "$baseline" "$label"
        return
    fi
    echo "Downloading $label from $REPO@$LIBS_TAG..."
    fetch "$archive"
    mkdir -p "$dir"
    rm -rf "$marker" "${dir:?}"/*"$unit"
    tar xzf "$WORK/$archive" -C "$dir"
    verify "$run_from" "$dir" "$baseline" "$label"
    echo "$LIBS_TAG" > "$marker"
}

sync_libs "macOS libraries" "$LIBS_DIR" "tablepro-libs-${LIBS_TAG#libs-}.tar.gz" ".a" \
    "." "$WORK/macos-baseline"
sync_libs "iOS xcframeworks" "$IOS_DIR" "tablepro-libs-ios-${LIBS_TAG#libs-}.tar.gz" ".xcframework" \
    "$IOS_DIR" "$WORK/ios-baseline"

if [[ -f "$LIBS_DIR/libcrypto_arm64.a" || -f "$LIBS_DIR/libcrypto.a" ]]; then
    echo "Creating OpenSSL shared dylibs for local development..."
    scripts/create-openssl-dylibs.sh both
else
    echo "Skipping OpenSSL dylibs (no static libs found yet)."
fi
