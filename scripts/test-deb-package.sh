#!/usr/bin/env bash
# Build the .deb on a supported Debian-family stack, install it with apt, and check what landed.
# Usage: [PREVIOUS_DEB=path/to/released.deb] bash scripts/test-deb-package.sh [ubuntu:24.04|debian:13 ...]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
images=("$@")
[ ${#images[@]} -gt 0 ] || images=(ubuntu:24.04 debian:13)
previous_mount=()
if [ -n "${PREVIOUS_DEB:-}" ]; then
  previous_mount=(-v "$(dirname "$(realpath "$PREVIOUS_DEB")"):/previous:ro" -e "PREVIOUS_DEB_NAME=$(basename "$PREVIOUS_DEB")")
fi

for base in "${images[@]}"; do
  tag="bookie-floor-${base//[:\/]/-}"
  echo "== $base"
  docker build -q -t "$tag" --build-arg "BASE=$base" scripts/distro-floor >/dev/null
  docker run --rm "${previous_mount[@]}" -v "$PWD:/src:ro" -v "${tag}-target:/target" -v "${tag}-cargo:/opt/cargo/registry" -v "${tag}-git:/opt/cargo/git" -e CARGO_TARGET_DIR=/target "$tag" bash -ceu '
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends desktop-file-utils >/dev/null
    rm -rf /work && mkdir /work && cp -a /src/. /work/
    cd /work
    DEB_OUT=/work/out bash scripts/build-deb.sh >/tmp/build.log 2>&1 || { tail -40 /tmp/build.log; exit 1; }
    tail -3 /tmp/build.log
    deb=$(ls /work/out/tablepro_*.deb)
    dpkg-deb --info "$deb" | sed -n "1,12p"
    mkdir -p ~/.config/tablepro ~/.local/share/tablepro
    echo keep > ~/.config/tablepro/connections.json
    echo keep > ~/.local/share/tablepro/history.db
    older=$deb
    dpkg-deb -R "$older" /work/repack
    sed -i "s/^Version: .*/Version: 0.1.5-2/" /work/repack/DEBIAN/control
    newer=/work/out/tablepro_0.1.5-2_amd64.deb
    dpkg-deb --root-owner-group --build /work/repack "$newer" >/dev/null
    installed_version() { dpkg-query -W -f="\${Version}" tablepro; }
    keeps_user_data() {
      test "$(cat ~/.config/tablepro/connections.json)" = keep
      test "$(cat ~/.local/share/tablepro/history.db)" = keep
    }
    apt-get install -y -qq "$older" >/dev/null
    bash /src/scripts/check-installed-deb.sh
    apt-get install -y -qq --reinstall "$older" >/dev/null
    bash /src/scripts/check-installed-deb.sh
    apt-get install -y -qq "$newer" >/dev/null
    test "$(installed_version)" = 0.1.5-2
    bash /src/scripts/check-installed-deb.sh
    keeps_user_data
    apt-get install -y -qq --allow-downgrades "$older" >/dev/null
    test "$(installed_version)" = 0.1.5-1
    bash /src/scripts/check-installed-deb.sh
    keeps_user_data
    if [ -n "${PREVIOUS_DEB_NAME:-}" ]; then
      apt-get purge -y -qq tablepro >/dev/null
      apt-get install -y -qq "/previous/$PREVIOUS_DEB_NAME" >/dev/null
      test "$(installed_version)" = 0.1.5-1
      keeps_user_data
      apt-get install -y -qq "$newer" >/dev/null
      test "$(installed_version)" = 0.1.5-2
      bash /src/scripts/check-installed-deb.sh
      keeps_user_data
      echo "an upgrade from the released package keeps the user data"
    fi
    apt-get purge -y -qq tablepro >/dev/null
    test ! -e /usr/bin/bookie
    keeps_user_data
    echo "install, reinstall, upgrade, downgrade and purge keep the user data under the tablepro paths"
  '
done
