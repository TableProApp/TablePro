#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
sha=${1:?usage: distro-floor-package.sh <commit-sha>}
cache=${DISTRO_FLOOR_PACKAGE_CACHE:-/var/cache/ci/floor-package}
image=bookie-floor-package-ubuntu-24.04

mkdir -p "$cache"
exec 9>"$cache/.lock"
flock 9
docker build -q -t "$image" --build-arg BASE=ubuntu:24.04 "$root/scripts/distro-floor" >/dev/null
marker=".visible-$$"
touch "$cache/$marker"
if ! docker run --rm -v "$cache:/probe:ro" "$image" test -e "/probe/$marker" 2>/dev/null; then
  cache="$root/.floor-package"
  mkdir -p "$cache"
fi
rm -f "${DISTRO_FLOOR_PACKAGE_CACHE:-/var/cache/ci/floor-package}/$marker"
find "$cache" -mindepth 1 -maxdepth 1 -type d -mmin +1440 -exec rm -rf {} +

package=$(find "$cache/$sha" -maxdepth 1 -name '*.deb' -print -quit 2>/dev/null || true)
if [ -z "$package" ]; then
  staging="$cache/$sha.partial"
  rm -rf "$staging"
  mkdir -p "$staging"
  docker run --rm -e "HOST_IDS=$(id -u):$(id -g)" -e "BOOKIE_BUILD_PROFILE=${BOOKIE_BUILD_PROFILE:-release}" -v "$root:/src:ro" -v "$staging:/out" \
    -v bookie-floor-build-target:/target "$image" bash -ceu '
      trap "chown -R \"$HOST_IDS\" /out" EXIT
      apt-get update -qq
      apt-get install -y -qq --no-install-recommends desktop-file-utils >/dev/null
      CARGO_TARGET_DIR=/target DEB_OUT=/out bash /src/scripts/build-deb.sh >/tmp/build.log 2>&1 || { tail -40 /tmp/build.log; exit 1; }
      tail -3 /tmp/build.log
    ' >&2
  rm -rf "${cache:?}/$sha"
  mv "$staging" "$cache/$sha"
  package=$(find "$cache/$sha" -maxdepth 1 -name '*.deb' -print -quit)
fi
test -s "$package"
printf '%s\n' "$package"
