#!/usr/bin/env bash
set -euo pipefail

VERSION="0.9.148"
TARGET="x86_64-unknown-linux-gnu"
SHA256="223ba936714cc861a9cdedad5a8eb664dfdd69d6fbdf6cea6aa8184f523290dc"
TOOL_DIR="${TABLEPRO_TOOL_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/bookie-tools}/nextest-$VERSION"
BIN="$TOOL_DIR/cargo-nextest"

if [ "$(uname -m)" != "x86_64" ]; then
  echo "ensure-nextest: only x86_64 Linux is pinned; install cargo-nextest $VERSION yourself" >&2
  exit 1
fi

if [ ! -x "$BIN" ]; then
  mkdir -p "$TOOL_DIR"
  work="$(mktemp -d "$TOOL_DIR/download.XXXXXX")"
  trap 'rm -rf -- "$work"' EXIT
  archive="$work/nextest.tar.gz"
  url="https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-$VERSION/cargo-nextest-$VERSION-$TARGET.tar.gz"
  curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --max-time 120 -o "$archive" "$url"
  echo "$SHA256  $archive" | sha256sum --check --quiet
  tar -xzf "$archive" -C "$work" cargo-nextest
  mv "$work/cargo-nextest" "$BIN"
fi

echo "$BIN"
