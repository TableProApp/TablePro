#!/bin/sh
# Writes the two release source tarballs into <output dir>:
# tablepro-X.Y.Z.tar.xz from meson dist, and tablepro-X.Y.Z-vendor.tar.xz,
# which holds vendor/ with every crate in Cargo.lock and
# vendor/cargo-config.toml, so the packages build offline.
#
# --install-deps first installs, as root in a throwaway ubuntu:26.04, git
# and the build dependencies in build-aux/debian/control, the toolchain
# from ppa:rust-toolchain/staging among them.
# Usage: make-sources.sh [--install-deps] <output dir>
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

container=""
if [ "${1:-}" = "--install-deps" ]; then
    shift
    container=1
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates git xz-utils
    # The checkout belongs to another user, which git refuses to read.
    git config --global --add safe.directory '*'
    rust="$(sed -n 's/^rust-version = "\(.*\)"$/\1/p' "$root/Cargo.toml")"
    "$here/add-rust-toolchain-ppa.sh" "$rust"
    apt-get build-dep -y --no-install-recommends -P nocheck "$root/build-aux"
    PATH="/usr/lib/rust-$rust/bin:$PATH"
fi

if [ $# -ne 1 ]; then
    echo "usage: make-sources.sh [--install-deps] <output dir>" >&2
    exit 2
fi
mkdir -p "$1"
out="$(cd "$1" && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# In a container the crates go to the work directory, which build-packages.sh
# puts on the build volume, rather than the container's own layer.
if [ -n "$container" ]; then
    export CARGO_HOME="$work/cargo-home"
fi

meson setup "$work/build" "$root"
meson dist -C "$work/build" --no-tests --formats xztar
version="$(meson introspect --projectinfo "$work/build" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["version"])')"
cp "$work/build/meson-dist/tablepro-$version.tar.xz" "$out/"

# cargo vendor prints the source replacement on stdout, naming the
# directory as it was given, and may prune that directory. Run from its
# parent so the config says "vendor", and move the config in afterwards.
mkdir "$work/vendor-root"
(
    cd "$work/vendor-root"
    cargo vendor --locked --versioned-dirs --manifest-path "$root/Cargo.toml" vendor
) > "$work/cargo-config.toml"
mv "$work/cargo-config.toml" "$work/vendor-root/vendor/cargo-config.toml"

mtime="$(git -C "$root" log -1 --format=%ct)"
XZ_OPT=-T0 tar -C "$work/vendor-root" --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@$mtime" -cJf "$out/tablepro-$version-vendor.tar.xz" vendor

echo "$out/tablepro-$version.tar.xz"
echo "$out/tablepro-$version-vendor.tar.xz"
