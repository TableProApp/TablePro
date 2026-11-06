#!/bin/sh
# Runs Cargo, then copies each file it built to the output Meson declared.
# Every path is one argument, so a source or build directory may hold spaces.
# Usage: cargo-build.sh <built file> <output> [<built file> <output>]... -- <cargo> <argument>...
set -eu

skip=0
found=false
for argument in "$@"; do
    skip=$((skip + 1))
    if [ "$argument" = -- ]; then
        found=true
        break
    fi
done
if [ "$found" = false ] || [ $(((skip - 1) % 2)) -ne 0 ]; then
    echo "usage: cargo-build.sh <built file> <output>... -- <cargo> <argument>..." >&2
    exit 2
fi

(shift "$skip" && exec "$@")
while [ "$1" != -- ]; do
    cp "$1" "$2"
    shift 2
done
