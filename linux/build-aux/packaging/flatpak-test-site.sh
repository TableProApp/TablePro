#!/bin/sh
# Makes the repositories smoke-test-flatpak.sh serves, from the build
# repositories of build-flatpak.sh, with flatpak-repo.sh and a throwaway key,
# for http://127.0.0.1:8080/: repo/ on the branch stable and beta-repo/ on
# the branch beta, as flatpak.tablepro.app lays them out. <output dir>/one
# holds them after one commit per architecture, <output dir>/two after a
# second, so an installed app has an update to take, and
# <output dir>/bundles/<branch> the bundles of the first commit. It also
# validates the desktop entry, the metainfo and the schema each app commit
# installs, and checks that its catalogue lists every screenshot.
#
# --install-deps first installs, as root in a throwaway Ubuntu, the tools
# this needs.
# Usage: flatpak-test-site.sh [--install-deps] <output dir> <build repo>...
set -eu

if [ "${1:-}" = --install-deps ]; then
    shift
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates flatpak ostree gnupg \
        desktop-file-utils appstream libglib2.0-bin
fi
if [ $# -lt 2 ]; then
    echo "usage: flatpak-test-site.sh [--install-deps] <output dir> <build repo>..." >&2
    exit 2
fi
here="$(cd "$(dirname "$0")" && pwd)"
app=app.tablepro.TablePro
mkdir -p "$1"
out="$(cd "$1" && pwd)"
shift

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
work="$(mktemp -d "${TMPDIR:-/var/tmp}/tablepro-site.XXXXXX")"
trap 'gpgconf --kill all; rm -rf "$GNUPGHOME" "$work"' EXIT
gpg --batch --passphrase '' --quick-generate-key 'TablePro CI <ci@tablepro.invalid>' rsa4096 sign never
key="$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')"

commit() {
    for pair in stable:repo beta:beta-repo; do
        branch="${pair%%:*}"
        dir="${pair#*:}"
        for build in "$@"; do
            "$here/flatpak-repo.sh" import "$build" "$work/$dir" "$key" "$branch"
        done
        "$here/flatpak-repo.sh" update "$work/$dir" "$branch" "$key" "http://127.0.0.1:8080/$dir/"
    done
}

rm -rf "$out/one" "$out/two" "$out/bundles"
mkdir -p "$out/one" "$out/two"
commit "$@"
cp -a "$work/repo" "$work/beta-repo" "$out/one/"
for pair in stable:repo beta:beta-repo; do
    "$here/flatpak-repo.sh" bundle "$work/${pair#*:}" "${pair%%:*}" "$key" \
        "http://127.0.0.1:8080/${pair#*:}/" "$out/bundles/${pair%%:*}"
done

# What each architecture installs, checked with this Ubuntu's validators.
for ref in $(ostree refs --repo="$work/repo" | grep "^app/$app/"); do
    tree="$work/tree-$(echo "$ref" | cut -d/ -f3)"
    ostree checkout --repo="$work/repo" -U "$ref" "$tree"
    desktop-file-validate "$tree/files/share/applications/$app.desktop"
    appstreamcli validate --no-net "$tree/files/share/metainfo/$app.metainfo.xml"
    glib-compile-schemas --strict --dry-run "$tree/files/share/glib-2.0/schemas"
    # appstreamcli compose drops a screenshot it cannot download.
    named="$(grep -c '<screenshot[ >]' "$tree/files/share/metainfo/$app.metainfo.xml")"
    listed="$(gzip -dc "$tree/files/share/app-info/xmls/$app.xml.gz" | grep -c '<screenshot[ >]' || true)"
    if [ "$listed" -ne "$named" ]; then
        echo "flatpak-test-site.sh: the catalogue of $ref lists $listed of the metainfo's $named screenshots" >&2
        exit 1
    fi
done

commit "$@"
cp -a "$work/repo" "$work/beta-repo" "$out/two/"
ls -l "$out" "$out/bundles"/*
