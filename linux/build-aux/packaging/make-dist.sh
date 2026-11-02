#!/bin/sh
# Writes tablepro-X.Y.Z.tar.xz into <output dir>: the last commit's Linux app
# and the Cargo workspace it builds in, under tablepro-X.Y.Z/, with the
# repository's layout. X.Y.Z is the version in linux/meson.build. A tree
# with uncommitted changes to those paths is refused, since the tarball
# holds the commit and not the tree.
# Usage: make-dist.sh <output dir>
set -eu

if [ $# -ne 1 ]; then
    echo "usage: make-dist.sh <output dir>" >&2
    exit 2
fi

here="$(cd "$(dirname "$0")" && pwd)"
linux="$(cd "$here/../.." && pwd)"
repo="$(git -C "$linux" rev-parse --show-toplevel)"

# Every path a build from the tarball reads, from the top of the repository.
set -- "$1" Cargo.toml Cargo.lock rust-toolchain.toml rustfmt.toml clippy.toml deny.toml .config linux

out="$1"
shift
if [ -n "$(git -C "$repo" status --porcelain --untracked-files=no -- "$@")" ]; then
    echo "make-dist.sh: commit or stash the changes under $*; the tarball holds the last commit" >&2
    git -C "$repo" status --short --untracked-files=no -- "$@" >&2
    exit 1
fi

version="$(meson introspect --projectinfo "$linux/meson.build" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["version"])')"
mkdir -p "$out"
tarball="$(cd "$out" && pwd)/tablepro-$version.tar"
rm -f "$tarball" "$tarball.xz"
git -C "$repo" archive --format=tar --prefix="tablepro-$version/" --output="$tarball" HEAD -- "$@"
xz -T0 "$tarball"
echo "$tarball.xz"
