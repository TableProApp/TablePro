#!/usr/bin/env bash
# Writes the license notices of every Rust crate the app's core library links (scripts/build-core.sh) into the
# third-party licenses the About window shows, with the NOTICE files the Apache License 2.0 asks to ship. The
# clarifications for crates that package no readable license file are shared with the Linux app's notices in
# linux/about.toml. Run it after a change to Cargo.lock and commit what it writes.
#
# Line endings are LF whatever a crate ships, as git checks the file out.
#
# Usage: update-core-licenses.sh [--check]    --check fails when the committed file is out of date
set -euo pipefail

EXPECTED="cargo-about 0.9.2"
APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$APPLE_DIR/.." && pwd)"
OUTPUT="$APPLE_DIR/TablePro/Resources/ThirdPartyLicenses/texts/tablepro-core-crates.txt"

version="$(cargo about --version)"
if [ "$version" != "$EXPECTED" ]; then
    echo "update-core-licenses.sh: needs $EXPECTED, found $version (cargo install --locked cargo-about@0.9.2 --features cli)" >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The libraries build-core.sh makes: no engines, every macOS and iOS slice.
generate() {
    cargo about generate --locked --fail \
        --config "$REPO_ROOT/linux/about.toml" \
        --manifest-path "$REPO_ROOT/core/crates/ffi/Cargo.toml" \
        --no-default-features \
        --target aarch64-apple-darwin --target x86_64-apple-darwin \
        --target aarch64-apple-ios --target aarch64-apple-ios-sim \
        --output-file "$2" \
        "$1"
}

# A crate whose license file cargo-about cannot read gets the SPDX template text. The Apache License 2.0 and the
# MPL 2.0 name no copyright holder, so their template is the license as the crate ships it; any other one needs a
# clarification in linux/about.toml.
generate "$REPO_ROOT/linux/build-aux/about/fallbacks.hbs" "$work/fallbacks"
if grep -vE ': (Apache-2\.0|MPL-2\.0)$' "$work/fallbacks" | grep -q '[^[:space:]]'; then
    echo "update-core-licenses.sh: no license file read for these crates; add a clarification in linux/about.toml:" >&2
    grep -vE ': (Apache-2\.0|MPL-2\.0)$' "$work/fallbacks" >&2
    exit 1
fi

generate "$APPLE_DIR/scripts/about/core-crates.txt.hbs" "$work/notices"
generate "$REPO_ROOT/linux/build-aux/about/third-party.json.hbs" "$work/third-party.json"
cargo metadata --locked --format-version 1 --manifest-path "$REPO_ROOT/Cargo.toml" > "$work/metadata.json"
python3 "$REPO_ROOT/linux/build-aux/packaging/crate_notices.py" \
    --licenses "$work/third-party.json" --metadata "$work/metadata.json" --output "$work/NOTICE"
{
    cat "$work/notices"
    printf '\n================================================================================\nNOTICE files\n\n'
    sed 's/linked into TablePro, as the Apache License/linked into the core, as the Apache License/; s#build-aux/update-third-party-licenses.sh writes this file.#apple/scripts/update-core-licenses.sh writes this section.#' "$work/NOTICE"
} | tr -d '\r' > "$work/output"

if [ "${1:-}" = "--check" ]; then
    if ! cmp -s "$work/output" "$OUTPUT"; then
        echo "update-core-licenses.sh: $OUTPUT is out of date; run apple/scripts/update-core-licenses.sh and commit it" >&2
        diff -u "$OUTPUT" "$work/output" | head -40 >&2 || true
        exit 1
    fi
    echo "$OUTPUT is up to date"
else
    cp "$work/output" "$OUTPUT"
    echo "Wrote $OUTPUT"
fi
