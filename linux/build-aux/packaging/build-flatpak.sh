#!/bin/sh
# Builds TablePro as a Flatpak from the two release tarballs, offline, with
# build-aux/flatpak/app.tablepro.TablePro.json, on the branch given (stable
# when none is), and runs every Meson suite in the build sandbox. Writes
# <output dir>/repo, an unsigned OSTree repository with the app and its
# .Debug extension that flatpak-repo.sh signs into the published one, and
# <output dir>/tablepro-<arch>.flatpak, an unsigned bundle to try the build.
# The manifest reads the tarballs as tablepro.tar.xz and
# tablepro-vendor.tar.xz beside it, so they go next to a copy of it. The SDK
# and its extensions come from Flathub into this user's installation: one
# baked into a container image cannot update in place.
#
# The gtk suite needs a display; without one, run this under xvfb-run.
# Usage: build-flatpak.sh [--branch stable|beta] <dist tarball> <vendor tarball> <output dir>
set -eu

usage() {
    echo "usage: build-flatpak.sh [--branch stable|beta] <dist tarball> <vendor tarball> <output dir>" >&2
    exit 2
}

branch=stable
if [ "${1:-}" = --branch ]; then
    [ $# -ge 2 ] || usage
    branch="$2"
    shift 2
fi
case "$branch" in
stable | beta) ;;
*) usage ;;
esac
[ $# -eq 3 ] || usage
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$3"
out="$(cd "$3" && pwd)"

work="$(mktemp -d "${TMPDIR:-/var/tmp}/tablepro-flatpak.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp "$here/../flatpak/app.tablepro.TablePro.json" "$work/"
cp "$1" "$work/tablepro.tar.xz"
cp "$2" "$work/tablepro-vendor.tar.xz"

flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
rm -rf "$out/repo"
flatpak-builder --user --install-deps-from=flathub --disable-rofiles-fuse --force-clean \
    --default-branch="$branch" --state-dir="$work/state" --repo="$out/repo" \
    "$work/build" "$work/app.tablepro.TablePro.json"
arch="$(flatpak --default-arch)"
flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo \
    "$out/repo" "$out/tablepro-$arch.flatpak" app.tablepro.TablePro "$branch"
ls -l "$out"
