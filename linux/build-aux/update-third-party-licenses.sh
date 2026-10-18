#!/bin/sh
# Writes data/licenses from Cargo.lock with cargo-about, then the Debian
# copyright file and the RPM spec's License tag from data/licenses. CI runs
# it and fails when the committed files differ, so run it after every
# change to Cargo.lock and commit what it writes.
set -eu

expected_version="cargo-about 0.9.2"
root="$(cd "$(dirname "$0")/.." && pwd)"

# Another version can render the same lock file differently, which CI
# would report as drift.
version="$(cargo about --version)"
if [ "$version" != "$expected_version" ]; then
    echo "update-third-party-licenses.sh: needs $expected_version, found $version" >&2
    exit 1
fi

cargo fetch --locked --manifest-path "$root/Cargo.toml"

# The app manifest, not the workspace, so the test-only crates and their
# dependencies stay out: tablepro-ssh, which builds the askpass helper,
# is one of the app's own dependencies. Not --offline: the git entries
# in about.toml fetch a license file from the crate's repository.
generate() {
    cargo about generate --locked --fail \
        --config "$root/about.toml" \
        --manifest-path "$root/crates/app/Cargo.toml" \
        --output-file "$2" \
        "$1"
}

# A crate with no license file cargo-about can read gets the SPDX template
# text, which names no copyright holder, and --fail lets that through.
fallbacks="$(mktemp)"
trap 'rm -f "$fallbacks"' EXIT
generate "$root/build-aux/about/fallbacks.hbs" "$fallbacks"
if grep -q '[^[:space:]]' "$fallbacks"; then
    echo "update-third-party-licenses.sh: no license file read for these crates; add or fix their [<crate>.clarify] entry in about.toml:" >&2
    cat "$fallbacks" >&2
    exit 1
fi

for output in third-party.json THIRD-PARTY-NOTICE.md; do
    generate "$root/build-aux/about/$output.hbs" "$root/data/licenses/$output"
done

python3 "$root/build-aux/packaging/license_metadata.py" write \
    --licenses "$root/data/licenses/third-party.json" \
    --license-file "$root/LICENSE" \
    --copyright "$root/build-aux/debian/copyright" \
    --spec "$root/build-aux/rpm/tablepro.spec"
