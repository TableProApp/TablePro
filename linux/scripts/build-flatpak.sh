#!/usr/bin/env bash
# Attempt an end-to-end flatpak-builder run (requires flatpak + flatpak-builder).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${FLATPAK_BUILD_DIR:-/tmp/tablepro-flatpak-build}"
REPO_DIR="${FLATPAK_REPO_DIR:-/tmp/tablepro-flatpak-repo}"

if ! command -v flatpak-builder >/dev/null; then
  cat >&2 <<'EOF'
flatpak-builder is not installed.

Debian / Ubuntu:
  sudo apt install -y flatpak flatpak-builder
  flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  flatpak install -y flathub org.gnome.Sdk//47 org.gnome.Platform//47 \
    org.freedesktop.Sdk.Extension.rust-stable//24.08 \
    org.freedesktop.Sdk.Extension.llvm19//24.08

Arch:
  sudo pacman -S --needed flatpak flatpak-builder
  # then install the same runtimes from Flathub as above
EOF
  exit 1
fi

mkdir -p "$BUILD_DIR" "$REPO_DIR"
cd "$ROOT"
flatpak-builder --force-clean --repo="$REPO_DIR" "$BUILD_DIR" flatpak/com.tablepro.linux.json
flatpak build-bundle "$REPO_DIR" /tmp/tablepro.flatpak com.tablepro.linux
echo "Bundle: /tmp/tablepro.flatpak"
echo "Install: flatpak install --user /tmp/tablepro.flatpak"
