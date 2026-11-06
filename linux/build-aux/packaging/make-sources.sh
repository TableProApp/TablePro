#!/bin/sh
# Writes the two release source tarballs into <output dir>:
# tablepro-X.Y.Z.tar.xz from make-dist.sh, and tablepro-X.Y.Z-vendor.tar.xz,
# which holds vendor/ with every crate in Cargo.lock and
# vendor/cargo-config.toml, so the packages build offline.
#
# --install-deps first installs, as root in a throwaway ubuntu:26.04, git
# and the build dependencies in build-aux/debian/control, the toolchain
# from ppa:rust-toolchain/staging among them.
# --posthog-key writes the PostHog project key to vendor/posthog-key, which
# debian/rules, the RPM spec and build-flatpak.sh pass to Meson as
# -Dposthog_key. The release gives it from a repository variable. Without one,
# or with an empty one, the packages send no usage data; with it, they send it
# unless the user turns it off.
# Usage: make-sources.sh [--install-deps] [--posthog-key KEY] <output dir>
set -eu

usage() {
    echo "usage: make-sources.sh [--install-deps] [--posthog-key KEY] <output dir>" >&2
    exit 2
}

not_a_key() {
    echo "make-sources.sh: --posthog-key takes a PostHog project key, phc_ then letters and digits" >&2
    exit 2
}

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
workspace="$(cd "$root/.." && pwd)"

container=""
posthog_key=""
while [ $# -gt 0 ]; do
    case "$1" in
    --install-deps)
        container=1
        shift
        ;;
    --posthog-key)
        [ $# -ge 2 ] || usage
        posthog_key="$2"
        shift 2
        ;;
    *) break ;;
    esac
done
[ $# -eq 1 ] || usage
# debian/rules puts the key on Meson's command line unquoted.
case "$posthog_key" in
    *[!0-9A-Za-z_-]*) not_a_key ;;
    "" | phc_?*) ;;
    *) not_a_key ;;
esac

if [ -n "$container" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates git xz-utils
    # The checkout belongs to another user, which git refuses to read.
    git config --global --add safe.directory '*'
    rust="$(sed -n 's/^rust-version = "\(.*\)"$/\1/p' "$workspace/Cargo.toml")"
    "$here/add-rust-toolchain-ppa.sh" "$rust"
    apt-get build-dep -y --no-install-recommends -P nocheck "$root/build-aux"
    PATH="/usr/lib/rust-$rust/bin:$PATH"
fi

mkdir -p "$1"
out="$(cd "$1" && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# In a container the crates go to the work directory, which build-packages.sh
# puts on the build volume, rather than the container's own layer.
if [ -n "$container" ]; then
    export CARGO_HOME="$work/cargo-home"
fi

dist="$("$here/make-dist.sh" "$out")"
version="$(basename "$dist" .tar.xz)"
version="${version#tablepro-}"

# cargo vendor prints the source replacement on stdout, naming the
# directory as it was given, and may prune that directory. Run from its
# parent so the config says "vendor", and move the config in afterwards.
mkdir "$work/vendor-root"
(
    cd "$work/vendor-root"
    cargo vendor --locked --versioned-dirs --manifest-path "$workspace/Cargo.toml" vendor
) > "$work/cargo-config.toml"
mv "$work/cargo-config.toml" "$work/vendor-root/vendor/cargo-config.toml"
if [ -n "$posthog_key" ]; then
    printf '%s\n' "$posthog_key" > "$work/vendor-root/vendor/posthog-key"
fi

mtime="$(git -C "$root" log -1 --format=%ct)"
XZ_OPT=-T0 tar -C "$work/vendor-root" --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@$mtime" -cJf "$out/tablepro-$version-vendor.tar.xz" vendor

echo "$out/tablepro-$version.tar.xz"
echo "$out/tablepro-$version-vendor.tar.xz"
