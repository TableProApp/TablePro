#!/bin/sh
# Builds the binary packages from a source package the way Launchpad does,
# and checks the source and binary packages with lintian. Each step runs
# in a fresh container of the source's Ubuntu series:
#
# 1. with network, it downloads the build dependencies the .dsc declares
#    from the archive and, where the archive lacks the toolchain,
#    ppa:rust-toolchain/staging;
# 2. with no network, it installs only those, unpacks the source and runs
#    every Meson suite inside dpkg-buildpackage, as a user that is not root;
# 3. it runs lintian, which fails on a warning.
#
# The steps share a container volume that is removed at the end, so the
# build never writes into a container's own layer.
# Usage: build-deb.sh <tablepro_V.dsc> <output dir>
# CONTAINER_ENGINE picks docker (the default) or podman.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"

download() {
    rust="$(grep -o 'rustc-[0-9][0-9.]*' "$1" | head -n 1)"
    "$here/add-rust-toolchain-ppa.sh" "${rust#rustc-}"
    mkdir -p /build/debs/partial
    apt-get build-dep -y --download-only -o Dir::Cache::Archives=/build/debs "$1"
}

build() {
    apt-get install -y --no-install-recommends /build/debs/*.deb
    useradd --create-home builder
    mkdir /build/work
    chown builder /build/work
    # runuser opens a PAM session, which gives the build the limits of a
    # login that is not root, 1024 open files among them. Launchpad passes
    # the builder's CPU count the same way as here.
    status=0
    runuser -u builder -- env HOME=/home/builder DEB_BUILD_OPTIONS="parallel=$(nproc)" \
        sh -euc 'cd /build/work && dpkg-source -x "$1" src && cd src && dpkg-buildpackage -b -us -uc' sh "$1" ||
        status=$?
    # Meson prints only the end of a failed suite's log, so the whole log
    # is kept beside the packages.
    if [ "$status" -ne 0 ]; then
        find /build/work/src -path '*/meson-logs/testlog.txt' -exec cp {} /out/ \;
        exit "$status"
    fi
    for file in /build/work/*.deb /build/work/*.ddeb /build/work/*.buildinfo /build/work/*.changes; do
        if [ -e "$file" ]; then
            cp "$file" /out/
        fi
    done
}

check() {
    apt-get update
    apt-get install -y --no-install-recommends lintian
    version="$(basename "$1" _source.changes)"
    lintian --fail-on error,warning --display-info "$1" /out/"$version"_*.changes
}

if [ "${1:-}" = "--step" ]; then
    export DEBIAN_FRONTEND=noninteractive TMPDIR=/build/tmp
    mkdir -p "$TMPDIR"
    chmod 1777 "$TMPDIR"
    case "$2" in
    download) download "$3" ;;
    build) build "$3" ;;
    check) check "$3" ;;
    esac
    exit 0
fi

if [ $# -ne 2 ]; then
    echo "usage: build-deb.sh <tablepro_V.dsc> <output dir>" >&2
    exit 2
fi
engine="${CONTAINER_ENGINE:-docker}"
source_dir="$(cd "$(dirname "$1")" && pwd)"
dsc="$(basename "$1")"
changes="${dsc%.dsc}_source.changes"
series="$(sed -n 's/^Distribution: //p' "$source_dir/$changes")"
mkdir -p "$2"
out="$(cd "$2" && pwd)"

volume="tablepro-deb-$$"
"$engine" volume create "$volume" >/dev/null
trap '"$engine" volume rm -f "$volume" >/dev/null' EXIT

step() {
    if [ "$1" = offline ]; then
        shift
        set -- --network none "ubuntu:$series" /packaging/build-deb.sh --step "$@"
    else
        set -- "ubuntu:$series" /packaging/build-deb.sh --step "$@"
    fi
    "$engine" run --rm -v "$volume:/build" -v "$here:/packaging:ro" -v "$source_dir:/source:ro" \
        -v "$out:/out" "$@"
}

step download "/source/$dsc"
step offline build "/source/$dsc"
step check "/source/$changes"
ls -l "$out"
