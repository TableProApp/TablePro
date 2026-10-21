#!/bin/sh
# Builds the Ubuntu and Fedora packages from the committed tree the way CI
# does, each step in a fresh container: the source tarballs in
# ubuntu:26.04; the Debian source package for each Ubuntu series and its
# binaries, built offline by build-deb.sh; the .rpm in fedora:44; and each
# package installed and started in another fresh container. The steps
# write to a container volume that is removed at the end, and the packages
# land in <output dir>.
# Usage: build-packages.sh deb|rpm|all <output dir> [series...]
# The series default to resolute. CONTAINER_ENGINE picks docker (the
# default) or podman.
set -eu

usage() {
    echo "usage: build-packages.sh deb|rpm|all <output dir> [series...]" >&2
    exit 2
}

engine="${CONTAINER_ENGINE:-docker}"
[ $# -ge 2 ] || usage
which="$1"
case "$which" in
deb | rpm | all) ;;
*) usage ;;
esac
mkdir -p "$2"
out="$(cd "$2" && pwd)"
shift 2
if [ $# -eq 0 ]; then
    set -- resolute
fi

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
repo="$(git -C "$root" rev-parse --show-toplevel)"
git_dir="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"

volume="tablepro-packages-$$"
"$engine" volume create "$volume" >/dev/null
trap '"$engine" volume rm -f "$volume" >/dev/null' EXIT

# Paths stay the same inside the containers, so a worktree's .git file
# still points at its repository. Not read-only: meson dist refreshes the
# git index before it archives.
run() {
    image="$1"
    shift
    "$engine" run --rm -e TMPDIR=/build -v "$volume:/build" \
        -v "$repo:$repo" -v "$git_dir:$git_dir" -v "$out:$out" \
        -w "$root" "$image" "$@"
}

run ubuntu:26.04 "$here/make-sources.sh" --install-deps "$out/sources"
dist="$(find "$out/sources" -name 'tablepro-*.tar.xz' ! -name '*-vendor.tar.xz')"
vendor="$(find "$out/sources" -name 'tablepro-*-vendor.tar.xz')"

if [ "$which" != rpm ]; then
    run ubuntu:26.04 "$here/build-source.sh" --install-deps "$dist" "$vendor" "$out/source" "$@"
    for changes in "$out"/source/*_source.changes; do
        series="$(sed -n 's/^Distribution: //p' "$changes")"
        "$here/build-deb.sh" "${changes%_source.changes}.dsc" "$out/deb/$series"
        run "ubuntu:$series" "$here/smoke-test.sh" "$(find "$out/deb/$series" -name 'tablepro_*.deb')" "$root/po/LINGUAS"
    done
fi
if [ "$which" != deb ]; then
    run fedora:44 "$here/build-rpm.sh" "$dist" "$vendor" "$out/rpm"
    run fedora:44 "$here/smoke-test.sh" "$(find "$out/rpm" -name 'tablepro-[0-9]*.rpm' ! -name '*.src.rpm')" \
        "$root/po/LINGUAS"
fi
