#!/bin/sh
# Builds the source RPM from the two release tarballs in a fresh Fedora
# container, then the binary RPMs from it in Mock, as COPR builds them:
# Mock installs the BuildRequires into a fresh chroot of the container's
# release and architecture, then runs rpmbuild there with no network.
# rpmlint checks the spec and every package. COPR takes its sources from
# the release (build-aux/rpm/copr-sources.sh). The container must be
# privileged, since Mock mounts filesystems and unshares namespaces.
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
dnf install -y --setopt=install_weak_deps=False mock rpm-build rpmlint glibc-langpack-en tar xz iproute util-linux

# Outside SPECS, where rpmbuild --rebuild removes the spec it unpacks, so
# rpmlint still has this one to read.
spec="$top/tablepro.spec"
tar -xOf "$1" "$name/linux/build-aux/rpm/tablepro.spec" > "$spec"
rpmbuild --define "_topdir $top" -bs "$spec"
srpm="$(find "$top/SRPMS" -name '*.src.rpm')"

# A container runs neither systemd-nspawn nor the podman that would pull
# Mock's bootstrap image, so Mock isolates with chroot alone.
chroot="fedora-$(rpm -E %fedora)-$(uname -m)"
set -- -r "$chroot" --isolation=simple --no-bootstrap-image

# The BuildRequires come from Fedora's repositories first.
mock "$@" --init
mock "$@" --installdeps "$srpm"

# COPR builds in systemd-nspawn's private network, where Mock turns the
# network off for rpmbuild. Without nspawn Mock leaves it on, so the build
# runs in a network namespace of its own with only the loopback, and Mock
# reads nothing but its cache. Meson prints only the end of a failed
# suite's log, so the whole log is kept beside the packages, with Mock's,
# and Mock keeps a failed build's chroot for it to be read from.
if unshare --net sh -euc 'ip link set lo up; ip route add default via 127.0.0.1; exec "$@"' offline \
    mock "$@" --no-clean --offline --config-opts=cleanup_on_failure=False \
    --resultdir "$top/result" --rebuild "$srpm"; then
    :
else
    build_status=$?
    cp "$top/result/build.log" "$out/" || true
    find "$(mock "$@" --print-root-path)" -path '*/meson-logs/testlog.txt' -exec cp {} "$out/" \; || true
    exit "$build_status"
fi

cp "$top"/result/*.rpm "$top/result/build.log" "$out/"
ls -l "$out"
# After the copy, so a lint failure keeps the packages to look at.
rpmlint --strict "$spec" "$top"/result/*.rpm
