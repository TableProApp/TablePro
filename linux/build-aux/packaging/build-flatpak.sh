#!/bin/sh
# Builds the Flatpak bundle a release carries from the two release tarballs,
# offline, with build-aux/flatpak/app.tablepro.TablePro.json. The manifest
# reads the tarballs as tablepro.tar.xz and tablepro-vendor.tar.xz beside it,
# so they go next to a copy of it. The SDK and its extensions come from
# Flathub into this user's installation: one baked into a container image
# cannot update in place. The bundle names Flathub as the repository of its
# runtime.
#
# The build runs no Meson suite. Under the real app ID, glycin decodes a
# picture through flatpak-spawn, which needs the app installed, so the gtk
# suite cannot pass in a build sandbox. The Devel Flatpak runs every suite on
# the same runtime, and the .deb and .rpm in the release profile.
# Usage: build-flatpak.sh <dist tarball> <vendor tarball> <output dir>
set -eu

if [ $# -ne 3 ]; then
    echo "usage: build-flatpak.sh <dist tarball> <vendor tarball> <output dir>" >&2
    exit 2
fi
here="$(cd "$(dirname "$0")" && pwd)"
flathub=https://dl.flathub.org/repo/flathub.flatpakrepo
mkdir -p "$3"
out="$(cd "$3" && pwd)"

work="$(mktemp -d "${TMPDIR:-/var/tmp}/tablepro-flatpak.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp "$here/../flatpak/app.tablepro.TablePro.json" "$work/"
cp "$1" "$work/tablepro.tar.xz"
cp "$2" "$work/tablepro-vendor.tar.xz"

flatpak remote-add --user --if-not-exists flathub "$flathub"
flatpak-builder --user --install-deps-from=flathub --disable-rofiles-fuse --force-clean \
    --default-branch=stable --state-dir="$work/state" --repo="$work/repo" \
    "$work/build" "$work/app.tablepro.TablePro.json"
arch="$(flatpak --default-arch)"
flatpak build-bundle --runtime-repo="$flathub" "$work/repo" "$out/tablepro-$arch.flatpak" \
    app.tablepro.TablePro stable
ls -l "$out"
