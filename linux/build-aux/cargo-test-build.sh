#!/bin/sh
# Runs Cargo, then writes the stamp file Meson declared as the output, which
# a test build has no single file of its own to give.
# Usage: cargo-test-build.sh <stamp> -- <cargo> <argument>...
set -eu

if [ "$#" -lt 3 ] || [ "$2" != -- ]; then
    echo "usage: cargo-test-build.sh <stamp> -- <cargo> <argument>..." >&2
    exit 2
fi

stamp=$1
shift 2
"$@"
: > "$stamp"
