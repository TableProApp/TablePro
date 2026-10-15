#!/bin/sh
# Builds the source and binary RPMs from the two release tarballs, as root
# in a fresh fedora:44, with only the BuildRequires the spec declares, and
# checks them with rpmlint. COPR builds the same spec in mock from the
# release (build-aux/rpm/copr-sources.sh).
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

# rpmlint reads the spec under en_US.UTF-8 and reports a missing locale as
# an error.
dnf install -y --setopt=install_weak_deps=False rpm-build rpmlint glibc-langpack-en tar xz

# Outside SPECS, where rpmbuild --rebuild removes the spec it unpacks, so
# rpmlint still has this one to read.
spec="$top/tablepro.spec"
tar -xOf "$1" "$name/build-aux/rpm/tablepro.spec" > "$spec"
rpmbuild --define "_topdir $top" -bs "$spec"
srpm="$(find "$top/SRPMS" -name '*.src.rpm')"

dnf builddep -y --setopt=install_weak_deps=False "$srpm"
# COPR builds with no network. Offline, Cargo fails here too unless it
# reads the vendored crates from the config %cargo_prep writes.
# Meson prints only the end of a failed suite's log, so the whole log is
# kept beside the packages.
if ! CARGO_NET_OFFLINE=true rpmbuild --define "_topdir $top" --rebuild "$srpm"; then
    find "$top/BUILD" -path '*/meson-logs/testlog.txt' -exec cp {} "$out/" \;
    exit 1
fi

cp "$srpm" "$top"/RPMS/*/*.rpm "$out/"
ls -l "$out"
# After the copy, so a lint failure keeps the packages to look at.
rpmlint --strict "$spec" "$srpm" "$top"/RPMS/*/*.rpm
