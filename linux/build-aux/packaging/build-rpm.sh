#!/bin/sh
# Builds the source and binary RPMs from the two release tarballs, as root
# in a fresh fedora:44, with only the BuildRequires the spec declares, and
# checks them with rpmlint. COPR builds the same source RPM in mock.
# Usage: build-rpm.sh <tablepro-X.Y.Z.tar.xz> <tablepro-X.Y.Z-vendor.tar.xz> <output dir>
set -eu

if [ $# -ne 3 ]; then
    echo "usage: build-rpm.sh <dist tarball> <vendor tarball> <output dir>" >&2
    exit 2
fi
mkdir -p "$3"
out="$(cd "$3" && pwd)"

name="$(basename "$1" .tar.xz)"
top="$(mktemp -d)"
trap 'rm -rf "$top"' EXIT
mkdir "$top/SOURCES" "$top/SPECS"
cp "$1" "$2" "$top/SOURCES/"

dnf install -y --setopt=install_weak_deps=False rpm-build rpmlint tar xz

tar -xOf "$1" "$name/build-aux/rpm/tablepro.spec" > "$top/SPECS/tablepro.spec"
rpmbuild --define "_topdir $top" -bs "$top/SPECS/tablepro.spec"
srpm="$(find "$top/SRPMS" -name '*.src.rpm')"

dnf builddep -y --setopt=install_weak_deps=False "$srpm"
rpmbuild --define "_topdir $top" --rebuild "$srpm"

rpmlint \
    "$top/SPECS/tablepro.spec" "$srpm" "$top"/RPMS/*/*.rpm

cp "$srpm" "$top"/RPMS/*/*.rpm "$out/"
ls -l "$out"
