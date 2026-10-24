#!/usr/bin/env bash
set -euo pipefail

VERSION="24.22.1"
SHA256="6c172a9ab6718f7b801fb5a7bd486af2ee5e32758086a04b84fcce2aa77095e6"
BINARY_SHA256="e32e2d16081cf644f88392934288086e7662529d0d43277c34f7aad2207cfafb"
TOOL_DIR="${TABLEPRO_TOOL_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/bookie-tools}/node-$VERSION"
BIN="$TOOL_DIR/node"

if [ "$(uname -m)" != "x86_64" ]; then
  echo "ensure-node: only x86_64 Linux is pinned" >&2
  exit 1
fi

mkdir -p "$TOOL_DIR"
exec 9>"$TOOL_DIR/.lock"
flock 9
if [ ! -L "$BIN" ] && [ -x "$BIN" ] && printf '%s  %s\n' "$BINARY_SHA256" "$BIN" | sha256sum --check --status; then
  printf '%s\n' "$TOOL_DIR"
  exit 0
fi

work="$(mktemp -d "$TOOL_DIR/download.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT
name="node-v$VERSION-linux-x64"
archive="$work/node.tar.xz"
curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --max-time 120 \
  -o "$archive" "https://nodejs.org/dist/v$VERSION/$name.tar.xz"
printf '%s  %s\n' "$SHA256" "$archive" | sha256sum --check --quiet
tar -xJf "$archive" -C "$work" "$name/bin/node"
binary="$work/$name/bin/node"
printf '%s  %s\n' "$BINARY_SHA256" "$binary" | sha256sum --check --quiet
mv -fT "$binary" "$BIN"
printf '%s\n' "$TOOL_DIR"
