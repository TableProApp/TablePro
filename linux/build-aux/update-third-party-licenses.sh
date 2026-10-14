#!/bin/sh
# Writes data/licenses from Cargo.lock with cargo-about. CI runs it and
# fails when the committed files differ, so run it after every change to
# Cargo.lock and commit what it writes.
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
# is one of the app's own dependencies.
for output in third-party.json THIRD-PARTY-NOTICE.md; do
    cargo about generate --locked --offline --fail \
        --config "$root/about.toml" \
        --manifest-path "$root/crates/app/Cargo.toml" \
        --output-file "$root/data/licenses/$output" \
        "$root/build-aux/about/$output.hbs"
done
