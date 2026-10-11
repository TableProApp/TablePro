#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for command_name in dbus-run-session gdbus gnome-shell python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing required command: $command_name" >&2
    exit 1
  fi
done

if ! python3 -c "import pyatspi" >/dev/null 2>&1; then
  echo "missing Python module: pyatspi" >&2
  exit 1
fi

if [[ "${TABLEPRO_GTK_DBUS_ACTIVE:-0}" != "1" ]]; then
  gtk_runtime="$(mktemp -d "${TMPDIR:-/tmp}/tablepro-gtk.XXXXXX")"
  chmod 700 "$gtk_runtime"
  cleanup_gtk_runtime() {
    if command -v fusermount3 >/dev/null 2>&1; then
      for gtk_mount in "$gtk_runtime/doc" "$gtk_runtime/gvfs"; do
        fusermount3 -uz -- "$gtk_mount" >/dev/null 2>&1 || true
      done
    fi
    rm -rf -- "$gtk_runtime"
  }
  trap cleanup_gtk_runtime EXIT
  env -u NO_AT_BRIDGE -u DISPLAY TABLEPRO_GTK_DBUS_ACTIVE=1 XDG_RUNTIME_DIR="$gtk_runtime" \
    ATSPI_DBUS_IMPLEMENTATION=dbus-daemon XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_TYPE=wayland \
    dbus-run-session -- "$ROOT/scripts/test-gtk-wayland.sh" "$@"
  exit $?
fi

export GDK_BACKEND=wayland
export WAYLAND_DISPLAY=wayland-tablepro
export GSK_RENDERER=cairo
export GTK_A11Y=atspi
unset NO_AT_BRIDGE DISPLAY

if [[ "${TABLEPRO_GTK_KEYRING_READY:-0}" != "1" ]] && command -v gnome-keyring-daemon >/dev/null 2>&1; then
  keyring_home="$XDG_RUNTIME_DIR/keyring-home"
  mkdir -p "$keyring_home/data"
  eval "$(printf 'tablepro-test' | HOME="$keyring_home" XDG_DATA_HOME="$keyring_home/data" \
    gnome-keyring-daemon --daemonize --unlock --components=secrets)"
fi

gnome-shell --headless --wayland --virtual-monitor "${TABLEPRO_GTK_MONITOR:-1280x1024}" \
  --wayland-display "$WAYLAND_DISPLAY" >"$XDG_RUNTIME_DIR/gnome-shell.log" 2>&1 &
shell_pid=$!
trap 'kill -KILL "$shell_pid" 2>/dev/null || true' EXIT
for _ in $(seq 30); do
  [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] && break
  sleep 1
done
if [[ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
  echo "headless compositor did not start" >&2
  cat "$XDG_RUNTIME_DIR/gnome-shell.log" >&2
  exit 1
fi

dbus-update-activation-environment WAYLAND_DISPLAY GDK_BACKEND GTK_A11Y
gdbus call --session \
  --dest org.a11y.Bus \
  --object-path /org/a11y/bus \
  --method org.a11y.Bus.GetAddress >/dev/null

test_binary="${TABLEPRO_GTK_BINARY:-$(command -v bookie || true)}"
if [[ -z "$test_binary" || ! -x "$test_binary" ]]; then
  echo "installed GTK test binary is not executable: ${test_binary:-bookie}" >&2
  exit 1
fi
timeout 600s python3 "$ROOT/crates/app/tests/gtk_safety.py" "$test_binary"
