#!/bin/sh
# Builds the .deb and the .rpm from the committed tree the way the release
# does, each step in a fresh container: the source tarballs in ubuntu:26.04,
# each package in a fresh ubuntu:26.04 or fedora:44, and each package
# installed and started in another fresh one.
# Usage: build-packages.sh [deb|rpm|all] <output dir>
# CONTAINER_ENGINE picks docker (the default) or podman.
set -eu

engine="${CONTAINER_ENGINE:-docker}"
which="${1:-}"
case "$which" in
deb | rpm | all) ;;
*)
    echo "usage: build-packages.sh deb|rpm|all <output dir>" >&2
    exit 2
    ;;
esac
if [ $# -ne 2 ]; then
    echo "usage: build-packages.sh deb|rpm|all <output dir>" >&2
    exit 2
fi
mkdir -p "$2"
out="$(cd "$2" && pwd)"

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
repo="$(git -C "$root" rev-parse --show-toplevel)"
git_dir="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"

# Paths stay the same inside the containers, so a worktree's .git file
# still points at its repository. Not read-only: meson dist refreshes the
# git index before it archives.
run() {
    image="$1"
    shift
    "$engine" run --rm \
        -v "$repo:$repo" -v "$git_dir:$git_dir" -v "$out:$out" \
        -w "$root" "$image" "$@"
}

run ubuntu:26.04 "$here/make-sources.sh" --install-deps "$out/sources"
dist="$(find "$out/sources" -name 'tablepro-*.tar.xz' ! -name '*-vendor.tar.xz')"
vendor="$(find "$out/sources" -name 'tablepro-*-vendor.tar.xz')"

if [ "$which" != rpm ]; then
    run ubuntu:26.04 "$here/build-deb.sh" "$dist" "$vendor" "$out/deb"
    run ubuntu:26.04 "$here/smoke-test.sh" "$(find "$out/deb" -name 'tablepro_*.deb')"
fi
if [ "$which" != deb ]; then
    run fedora:44 "$here/build-rpm.sh" "$dist" "$vendor" "$out/rpm"
    run fedora:44 "$here/smoke-test.sh" "$(find "$out/rpm" -name 'tablepro-[0-9]*.rpm' ! -name '*.src.rpm')"
fi
