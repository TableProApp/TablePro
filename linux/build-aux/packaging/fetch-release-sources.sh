#!/bin/sh
# Downloads the source and vendor tarballs of a published Linux release into
# <output dir>, checked against the release's SHA256SUMS. A packaging fix
# builds from these rather than from a new meson dist: Launchpad refuses an
# orig tarball whose bytes differ from the one it already has.
#
# --install-deps first installs curl, as root in a throwaway ubuntu:26.04.
# Usage: fetch-release-sources.sh [--install-deps] <owner/repo> <linux-vX.Y.Z> <output dir>
set -eu

usage() {
    echo "usage: fetch-release-sources.sh [--install-deps] <owner/repo> <linux-vX.Y.Z> <output dir>" >&2
    exit 2
}

if [ "${1:-}" = "--install-deps" ]; then
    shift
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl
fi
[ $# -eq 3 ] || usage
repository="$1"
tag="$2"
case "$repository" in
    */*/* | *[!0-9A-Za-z._/-]* | /* | */) usage ;;
    */*) ;;
    *) usage ;;
esac
version="${tag#linux-v}"
case "$version" in
    "$tag" | "" | *[!0-9.]*)
        echo "fetch-release-sources.sh: not the tag of a Linux release: $tag" >&2
        exit 2
        ;;
esac
mkdir -p "$3"
cd "$3"

url="https://github.com/$repository/releases/download/$tag"
for file in "tablepro-$version.tar.xz" "tablepro-$version-vendor.tar.xz" SHA256SUMS; do
    curl --fail --silent --show-error --location --proto '=https' --output "$file" "$url/$file"
done
# Both tarballs were just downloaded, so --ignore-missing skips only the
# release's other files.
sha256sum --check --strict --ignore-missing SHA256SUMS
rm SHA256SUMS
ls -l
