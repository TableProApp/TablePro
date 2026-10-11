#!/usr/bin/env bash
# Widget tests do not use AT-SPI. Installed accessibility flows have their own tier.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
widget_root="$(mktemp -d)"
cleanup_widget_root() {
  if command -v fusermount3 >/dev/null 2>&1; then
    for widget_mount in "$widget_root/runtime/doc" "$widget_root/runtime/gvfs"; do
      fusermount3 -uz -- "$widget_mount" >/dev/null 2>&1 || true
    done
  fi
  rm -rf -- "$widget_root" || true
}
trap cleanup_widget_root EXIT
export XDG_RUNTIME_DIR="$widget_root/runtime"
export XDG_CONFIG_HOME="$widget_root/config"
export XDG_DATA_HOME="$widget_root/data"
export XDG_CACHE_HOME="$widget_root/cache"
mkdir -m 700 "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME"
export G_DEBUG=fatal-criticals GDK_BACKEND=x11 GSK_RENDERER=cairo GTK_A11Y=none GIO_USE_VFS=local
dbus-run-session -- xvfb-run -a python3 "$ROOT/scripts/run-isolated-tests.py" gtk
