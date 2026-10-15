#!/bin/sh
# Builds the .deb from the two release tarballs, as root in a fresh
# ubuntu:26.04, with only the build dependencies debian/control declares,
# and checks it with lintian.
# Usage: build-deb.sh <tablepro-X.Y.Z.tar.xz> <tablepro-X.Y.Z-vendor.tar.xz> <output dir>
set -eu

if [ $# -ne 3 ]; then
    echo "usage: build-deb.sh <dist tarball> <vendor tarball> <output dir>" >&2
    exit 2
fi
here="$(cd "$(dirname "$0")" && pwd)"
dist="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
vendor="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
mkdir -p "$3"
out="$(cd "$3" && pwd)"

name="$(basename "$dist" .tar.xz)"
version="${name#tablepro-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates devscripts dpkg-dev lintian xz-utils

tar -xf "$dist" -C "$work"
src="$work/$name"
tar -xf "$vendor" -C "$src"
cp -R "$src/build-aux/debian" "$src/debian"

apt-get build-dep -y --no-install-recommends "$src"

# debhelper points HOME at a scratch directory during the build, so the
# rustup proxies need RUSTUP_HOME spelled out to find the toolchain.
if command -v rustup >/dev/null; then
    RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
    export RUSTUP_HOME
    RUSTUP_TOOLCHAIN="$("$here/rust-toolchain.sh" "$src")"
    export RUSTUP_TOOLCHAIN
fi

maintainer="$(sed -n 's/^Maintainer: //p' "$src/debian/control")"
(
    cd "$src"
    DEBEMAIL="$maintainer" dch --create --package tablepro --newversion "$version-1" \
        --distribution resolute --force-distribution --urgency medium \
        "New upstream release $version."
)
# Meson prints only the end of a failed suite's log, so the whole log is
# kept beside the packages.
if ! (cd "$src" && dpkg-buildpackage -b -us -uc); then
    find "$src" -path '*/meson-logs/testlog.txt' -exec cp {} "$out/" \;
    exit 1
fi

lintian --fail-on error,warning --display-info "$work"/tablepro_"$version"-1_*.changes

for file in "$work"/*.deb "$work"/*.ddeb "$work"/*.buildinfo "$work"/*.changes; do
    if [ -e "$file" ]; then
        cp "$file" "$out/"
    fi
done
ls -l "$out"
