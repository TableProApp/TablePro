#!/usr/bin/env bash
set -euo pipefail

VERSION="0.9.2"
TARGET="x86_64-unknown-linux-musl"
SHA256="9099a59e820c38a68b9d65f300662a567d56562f9a10f6aa4c7e86c17c2566af"
BINARY_SHA256="b06bd6a8bfd726cffb90e3e0588e3e0b1cfbb582bf6a34f4c1c2692ba8f2e7b8"
TOOL_DIR="${TABLEPRO_TOOL_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/bookie-tools}/cargo-about-$VERSION"
BIN="$TOOL_DIR/cargo-about"

cached_binary_is_valid() {
  [ -x "$BIN" ] && printf '%s  %s\n' "$BINARY_SHA256" "$BIN" | sha256sum --check --status
}

if [ "$(uname -m)" != "x86_64" ]; then
  echo "ensure-cargo-about: only x86_64 Linux is pinned; install cargo-about $VERSION yourself and set CARGO_ABOUT to it" >&2
  exit 1
fi

if ! cached_binary_is_valid; then
  if [ -e "$BIN" ] || [ -L "$BIN" ]; then
    rm -f -- "$BIN"
  fi
  mkdir -p "$TOOL_DIR"
  work="$(mktemp -d "$TOOL_DIR/download.XXXXXX")"
  trap 'rm -rf -- "$work"' EXIT
  name="cargo-about-$VERSION-$TARGET"
  archive="$work/$name.tar.gz"
  url="https://github.com/EmbarkStudios/cargo-about/releases/download/$VERSION/$name.tar.gz"
  curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --max-time 120 -o "$archive" "$url"
  echo "$SHA256  $archive" | sha256sum --check --quiet
  tar -xzf "$archive" -C "$work" "$name/cargo-about"
  binary="$work/$name/cargo-about"
  echo "$BINARY_SHA256  $binary" | sha256sum --check --quiet
  mv "$binary" "$BIN"
fi

echo "$BIN"
