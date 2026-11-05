#!/bin/sh
# Makes the repository smoke-test-flatpak.sh serves, from the build
# repositories of build-flatpak.sh, with flatpak-repo.sh and a throwaway key,
# for http://127.0.0.1:8080/. <output dir>/one is the repository after one
# commit per architecture, <output dir>/two after a second, so an installed
# app has an update to take, and <output dir>/bundles holds the bundles of
# the first commit.
#
# --install-deps first installs, as root in a throwaway Ubuntu, the tools
# this needs.
# Usage: flatpak-test-site.sh [--install-deps] <stable|beta> <output dir> <build repo>...
set -eu

if [ "${1:-}" = --install-deps ]; then
    shift
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates flatpak ostree gnupg
fi
if [ $# -lt 3 ]; then
    echo "usage: flatpak-test-site.sh [--install-deps] <stable|beta> <output dir> <build repo>..." >&2
    exit 2
fi
here="$(cd "$(dirname "$0")" && pwd)"
branch="$1"
case "$branch" in
stable) dir=repo ;;
beta) dir=beta-repo ;;
*)
    echo "flatpak-test-site.sh: the branch is stable or beta, not $branch" >&2
    exit 2
    ;;
esac
mkdir -p "$2"
out="$(cd "$2" && pwd)"
shift 2
url="http://127.0.0.1:8080/$dir/"

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
work="$(mktemp -d "${TMPDIR:-/var/tmp}/tablepro-site.XXXXXX")"
trap 'gpgconf --kill all; rm -rf "$GNUPGHOME" "$work"' EXIT
gpg --batch --passphrase '' --quick-generate-key 'TablePro CI <ci@tablepro.invalid>' rsa4096 sign never
key="$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')"

commit() {
    for build in "$@"; do
        "$here/flatpak-repo.sh" import "$build" "$work/$dir" "$key"
    done
    "$here/flatpak-repo.sh" update "$work/$dir" "$branch" "$key" "$url"
}

rm -rf "$out/one" "$out/two" "$out/bundles"
commit "$@"
mkdir -p "$out/one" "$out/two"
cp -a "$work/$dir" "$out/one/"
"$here/flatpak-repo.sh" bundle "$work/$dir" "$branch" "$key" "$url" "$out/bundles"
commit "$@"
cp -a "$work/$dir" "$out/two/"
ls -l "$out" "$out/bundles"
