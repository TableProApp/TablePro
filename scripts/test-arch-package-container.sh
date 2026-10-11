#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
released_url="${ARCH_RELEASED_URL:-https://github.com/cozyGarage/BookiE/releases/download/linux-v0.1.5/bookie-0.1.5-1-x86_64.pkg.tar.zst}"
version="${ARCH_CANDIDATE_VERSION:-0.1.6}"

docker run --rm -v "$PWD/..:/src:ro" -e RELEASED_URL="$released_url" -e VERSION="$version" archlinux:latest bash -ceu '
  pacman -Syu --noconfirm --needed base-devel git rust pkgconf clang gettext sudo curl \
    gtk4 libadwaita gtksourceview5 libsecret krb5 sqlite openssl desktop-file-utils appstream namcap >/dev/null
  useradd -m builder
  echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
  mkdir /home/builder/src
  tar -C /src --exclude=./target --exclude=./.git -cf - . | tar -C /home/builder/src -xf -
  chown -R builder /home/builder/src
  sudo -u builder bash -ceu "
    cd /home/builder/src
    git init -q && git add -A && git -c user.email=ci@local -c user.name=ci commit -qm candidate
    curl -fsSL -o /home/builder/released.pkg.tar.zst \"$RELEASED_URL\"
    cd linux
    TABLEPRO_RC_COMMIT=\$(git rev-parse HEAD) TABLEPRO_RC_VERSION=$VERSION bash scripts/build-arch-rc.sh
    bash scripts/test-arch-package.sh /home/builder/released.pkg.tar.zst packaging/arch/bookie-$VERSION-1-x86_64.pkg.tar.zst
  "
'
