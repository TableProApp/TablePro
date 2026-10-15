#!/bin/sh
# Makes rustc-X.Y and cargo-X.Y installable the way Launchpad finds them
# for the PPA build: from the series' own archive when it has them, and
# otherwise from ppa:rust-toolchain/staging, which the TablePro PPA
# depends on. Run as root in an Ubuntu container; installs nothing.
# Usage: add-rust-toolchain-ppa.sh <rust version, such as 1.97>
set -eu

if [ $# -ne 1 ]; then
    echo "usage: add-rust-toolchain-ppa.sh <rust version>" >&2
    exit 2
fi
here="$(cd "$(dirname "$0")" && pwd)"

apt-get update
if apt-cache show "rustc-$1" >/dev/null 2>&1; then
    exit 0
fi

# The key is committed, so no run trusts a key it fetched. apt checks
# InRelease against it, which makes plain HTTP as safe as the archive's
# own sources, and the base image has no CA bundle for HTTPS.
. /etc/os-release
mkdir -p /etc/apt/keyrings
cp "$here/rust-toolchain-staging.asc" /etc/apt/keyrings/rust-toolchain-staging.asc
cat > /etc/apt/sources.list.d/rust-toolchain-staging.sources <<EOF
Types: deb
URIs: http://ppa.launchpadcontent.net/rust-toolchain/staging/ubuntu/
Suites: $VERSION_CODENAME
Components: main
Signed-By: /etc/apt/keyrings/rust-toolchain-staging.asc
EOF
apt-get update
if ! apt-cache show "rustc-$1" >/dev/null 2>&1; then
    echo "add-rust-toolchain-ppa.sh: neither $VERSION_CODENAME nor ppa:rust-toolchain/staging has rustc-$1" >&2
    exit 1
fi
