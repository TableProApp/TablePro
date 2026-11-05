#!/bin/sh
# Builds the source and binary RPMs from the two release tarballs, as root
# in a fresh Fedora container, with only the BuildRequires the spec
# declares, and checks them with rpmlint. COPR builds the same spec in mock
# from the release (build-aux/rpm/copr-sources.sh).
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
disk_samples="$out/disk-usage.tsv"
disk_summary="$out/disk-usage.txt"
disk_monitor=""

sample_disk() {
    df -Pk "$top" | awk -v timestamp="$(date +%s)" '
        NR == 2 { printf "%s\t%s\t%s\t%s\n", timestamp, $2, $3, $4 }
        END { if (NR != 2) exit 1 }
    ' >> "$disk_samples"
}

cleanup() {
    build_status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$disk_monitor" ]; then
        kill "$disk_monitor" 2>/dev/null || true
        wait "$disk_monitor" 2>/dev/null || echo "RPM disk sampler stopped early; measurements may be incomplete." >&2
    fi
    # The archive and debug packages can peak before the build tree is removed.
    sample_disk || true
    if awk '
        NR == 2 { start = $4; used = $3; peak = $3; minimum = $4 }
        NR > 1 { if ($3 > peak) peak = $3; if ($4 < minimum) minimum = $4 }
        END {
            if (NR < 2) exit 1
            print "RPM filesystem disk usage (sampled every 1 second, KiB):"
            printf "start_available\t%.0f\nminimum_available\t%.0f\n", start, minimum
            printf "peak_used\t%.0f\npeak_increase\t%.0f\n", peak, peak - used
        }
    ' "$disk_samples" > "$disk_summary"; then
        cat "$disk_summary" || true
    fi
    rm -rf "$top" || true
    exit "$build_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'unix_seconds\tsize_kib\tused_kib\tavailable_kib\n' > "$disk_samples"
sample_disk
(
    trap - EXIT
    trap 'exit 0' HUP INT TERM
    while sleep 1; do
        sample_disk
    done
) &
disk_monitor=$!
mkdir "$top/SOURCES" "$top/SPECS"
cp "$1" "$2" "$top/SOURCES/"

# rpmlint reads the spec under en_US.UTF-8 and reports a missing locale as
# an error.
dnf install -y --setopt=install_weak_deps=False rpm-build rpmlint glibc-langpack-en tar xz

# Outside SPECS, where rpmbuild --rebuild removes the spec it unpacks, so
# rpmlint still has this one to read.
spec="$top/tablepro.spec"
tar -xOf "$1" "$name/linux/build-aux/rpm/tablepro.spec" > "$spec"
rpmbuild --define "_topdir $top" -bs "$spec"
srpm="$(find "$top/SRPMS" -name '*.src.rpm')"

dnf builddep -y --setopt=install_weak_deps=False "$srpm"
# COPR builds with no network. Offline, Cargo fails here too unless it
# reads the vendored crates from the config %cargo_prep writes.
# Meson prints only the end of a failed suite's log, so the whole log is
# kept beside the packages.
if CARGO_NET_OFFLINE=true rpmbuild --define "_topdir $top" --rebuild "$srpm"; then
    :
else
    build_status=$?
    find "$top/BUILD" -path '*/meson-logs/testlog.txt' -exec cp {} "$out/" \; || true
    exit "$build_status"
fi

cp "$srpm" "$top"/RPMS/*/*.rpm "$out/"
ls -l "$out"
# After the copy, so a lint failure keeps the packages to look at.
rpmlint --strict "$spec" "$srpm" "$top"/RPMS/*/*.rpm
