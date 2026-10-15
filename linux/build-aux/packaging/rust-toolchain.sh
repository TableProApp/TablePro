#!/bin/sh
# Installs the toolchain rust-toolchain.toml pins through rustup and prints
# its name, for RUSTUP_TOOLCHAIN. Ubuntu 26.04 ships rustc 1.93, below the
# workspace's rust-version, so the Ubuntu builds take Rust from rustup.
# Usage: rust-toolchain.sh <source root>
set -eu

channel="$(sed -n 's/^channel = "\(.*\)"$/\1/p' "$1/rust-toolchain.toml")"
if [ -z "$channel" ]; then
    echo "rust-toolchain.sh: no channel in $1/rust-toolchain.toml" >&2
    exit 1
fi

rustup toolchain install "$channel" --profile minimal >&2
echo "$channel"
