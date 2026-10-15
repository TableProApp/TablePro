#!/bin/sh
# Builds the Debian source package for each Ubuntu series named, unsigned,
# from the two release tarballs: the meson dist tarball is the orig tarball
# and the vendor tarball its vendor component. release-linux.yml signs the
# packages with debsign before it uploads them to the PPA.
#
# --install-deps first installs, as root in a throwaway ubuntu:26.04, the
# tools this needs. --revision counts uploads of one upstream version to
# the PPA, 1 when not given.
# Usage: build-source.sh [--install-deps] [--revision N] <dist tarball> <vendor tarball> <output dir> <series>...
set -eu

usage() {
    echo "usage: build-source.sh [--install-deps] [--revision N] <dist tarball> <vendor tarball> <output dir> <series>..." >&2
    exit 2
}

revision=1
while [ $# -gt 0 ]; do
    case "$1" in
    --install-deps)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends devscripts distro-info dpkg-dev xz-utils
        shift
        ;;
    --revision)
        [ $# -ge 2 ] || usage
        revision="$2"
        shift 2
        ;;
    *) break ;;
    esac
done
[ $# -ge 4 ] || usage
dist="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
vendor="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
mkdir -p "$3"
out="$(cd "$3" && pwd)"
shift 3

upstream="$(basename "$dist" .tar.xz)"
upstream="${upstream#tablepro-}"
# Debian sorts a pre-release below its release through a tilde, so
# 0.2.0-rc.1 becomes 0.2.0~rc.1.
debian_upstream="$(printf '%s\n' "$upstream" | sed 's/-/~/')"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$dist" "$work/tablepro_$debian_upstream.orig.tar.xz"
cp "$vendor" "$work/tablepro_$debian_upstream.orig-vendor.tar.xz"

# The tree dpkg-source would unpack from the two tarballs, so it finds no
# upstream change to record.
src="$work/tablepro-$debian_upstream"
mkdir "$src"
tar -xf "$dist" -C "$src" --strip-components=1
tar -xf "$vendor" -C "$src"
cp -R "$src/build-aux/debian" "$src/debian"
maintainer="$(sed -n 's/^Maintainer: //p' "$src/debian/control")"

for series in "$@"; do
    release="$(ubuntu-distro-info --series "$series" --release | cut -d ' ' -f 1)"
    rm -f "$src/debian/changelog"
    (
        cd "$src"
        DEBEMAIL="$maintainer" dch --create --package tablepro \
            --newversion "$debian_upstream-0ppa$revision~$release" \
            --distribution "$series" --force-distribution --urgency medium \
            "New upstream release. Notes: https://github.com/TableProApp/TablePro/blob/linux-v$upstream/linux/CHANGELOG.md"
        # -sa ships the orig tarballs with every upload; Launchpad accepts
        # the same files again for each series.
        dpkg-buildpackage -S -sa -d -nc -us -uc -I -i
    )
done

for file in "$work"/*; do
    if [ -f "$file" ]; then
        cp "$file" "$out/"
    fi
done
ls -l "$out"
