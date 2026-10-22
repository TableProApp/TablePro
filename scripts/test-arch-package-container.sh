#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
released_url="${ARCH_RELEASED_URL:-https://github.com/cozyGarage/BookiE/releases/download/linux-v0.1.5/bookie-0.1.5-1-x86_64.pkg.tar.zst}"
source_version="$(python3 scripts/check-release-version.py --print)"
version="${ARCH_CANDIDATE_VERSION:-$source_version}"
release_date="${ARCH_CANDIDATE_DATE:-${TABLEPRO_RC_DATE:-$(date -u +%F)}}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([a-z]+[0-9]+)?$ ]]; then
  echo "invalid candidate version: $version" >&2
  exit 1
fi
if [[ "$version" != "$source_version" ]]; then
  echo "candidate version $version does not match source version $source_version" >&2
  exit 1
fi
if [[ ! "$release_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || \
   [[ "$(date -u -d "$release_date" +%F 2>/dev/null || true)" != "$release_date" ]]; then
  echo "invalid candidate release date: $release_date (use YYYY-MM-DD)" >&2
  exit 1
fi

docker run --rm -i -v "$PWD:/src:ro" -e RELEASED_URL="$released_url" -e VERSION="$version" \
  -e TABLEPRO_RC_DATE="$release_date" archlinux:latest bash -seu <<'CONTAINER'
  pacman -Syu --noconfirm --needed base-devel git rust pkgconf clang gettext sudo curl \
    gtk4 libadwaita gtksourceview5 libsecret krb5 sqlite openssl desktop-file-utils appstream namcap >/dev/null
  useradd -m builder
  echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
  mkdir /home/builder/src
  tar -C /src --exclude=./target --exclude=./.git -cf - . | tar -C /home/builder/src -xf -
  chown -R builder /home/builder/src
  sudo -u builder env RELEASED_URL="$RELEASED_URL" VERSION="$VERSION" TABLEPRO_RC_DATE="$TABLEPRO_RC_DATE" bash -seu <<'BUILD'
    cd /home/builder/src
    git init -q && git add -A && git -c user.email=ci@local -c user.name=ci commit -qm candidate
    curl -fsSL -o /home/builder/released.pkg.tar.zst -- "$RELEASED_URL"
    TABLEPRO_RC_COMMIT="$(git rev-parse HEAD)" TABLEPRO_RC_VERSION="$VERSION" bash scripts/build-arch-rc.sh
    bash scripts/test-arch-package.sh /home/builder/released.pkg.tar.zst "apps/linux/packaging/arch/bookie-$VERSION-1-x86_64.pkg.tar.zst"
BUILD
CONTAINER
