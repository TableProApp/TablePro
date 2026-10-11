#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for command_name in dbus-run-session dbus-update-activation-environment gdbus xvfb-run python3; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing required command: $command_name" >&2
    exit 1
  fi
done

if ! python3 -c "import pyatspi" >/dev/null 2>&1; then
  echo "missing Python module: pyatspi" >&2
  exit 1
fi

# Always isolate from the desktop bus. A pre-existing session is not a test
# fixture, and its AT-SPI/portal processes may be tied to another display.
if [[ "${TABLEPRO_GTK_DBUS_ACTIVE:-0}" != "1" ]]; then
  gtk_runtime="$(mktemp -d "${TMPDIR:-/tmp}/tablepro-gtk.XXXXXX")"
  cleanup_gtk_runtime() {
    # Portal/GVFS services may leave FUSE mounts until their bus-loss handler
    # runs. Detach only mounts inside this test's private runtime directory.
    if command -v fusermount3 >/dev/null 2>&1; then
      for gtk_mount in "$gtk_runtime/doc" "$gtk_runtime/gvfs"; do
        fusermount3 -uz -- "$gtk_mount" >/dev/null 2>&1 || true
      done
    fi
    rm -rf -- "$gtk_runtime"
  }
  trap cleanup_gtk_runtime EXIT
  env -u NO_AT_BRIDGE TABLEPRO_GTK_DBUS_ACTIVE=1 XDG_RUNTIME_DIR="$gtk_runtime" \
    ATSPI_DBUS_IMPLEMENTATION=dbus-daemon XDG_CURRENT_DESKTOP=GNOME \
    dbus-run-session -- "$ROOT/scripts/test-gtk-safety.sh" "$@"
  exit $?
fi

if [[ "${TABLEPRO_GTK_XVFB_ACTIVE:-0}" != "1" ]]; then
  exec env TABLEPRO_GTK_XVFB_ACTIVE=1 \
    xvfb-run --auto-servernum --server-args="-screen 0 1280x1024x24 -nolisten tcp" "$ROOT/scripts/test-gtk-safety.sh" "$@"
fi

export GDK_BACKEND=x11
export GSK_RENDERER=cairo
export GTK_A11Y=atspi
unset NO_AT_BRIDGE
# D-Bus was started before Xvfb assigned DISPLAY/XAUTHORITY. Portal and
# accessibility activation must inherit the fixture display, not the desktop.
dbus-update-activation-environment DISPLAY XAUTHORITY GDK_BACKEND GTK_A11Y

# A bare dbus-run-session does not run a desktop autostart phase. Explicitly
# activate the AT-SPI bus before importing pyatspi so installed-package runs
# behave the same on Arch and Ubuntu CI images.
gdbus call --session \
  --dest org.a11y.Bus \
  --object-path /org/a11y/bus \
  --method org.a11y.Bus.GetAddress >/dev/null

if [[ "${TABLEPRO_GTK_KEYRING_READY:-0}" != "1" ]] && command -v gnome-keyring-daemon >/dev/null 2>&1; then
  keyring_home="$XDG_RUNTIME_DIR/keyring-home"
  mkdir -p "$keyring_home/data"
  eval "$(printf 'tablepro-test' | HOME="$keyring_home" XDG_DATA_HOME="$keyring_home/data" \
    gnome-keyring-daemon --daemonize --unlock --components=secrets)"
fi

TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
if [[ -n "${TABLEPRO_GTK_BINARY:-}" ]]; then
  test_binary="$TABLEPRO_GTK_BINARY"
else
  cargo build --release --locked -p tablepro-app --bin tablepro-app
  test_binary="$TARGET_DIR/installed/usr/bin/tablepro"
  install -Dm755 "$TARGET_DIR/release/tablepro-app" "$test_binary"
fi
if [[ ! -x "$test_binary" ]]; then
  echo "installed GTK test binary is not executable: $test_binary" >&2
  exit 1
fi
timeout 600s python3 "$ROOT/crates/app/tests/gtk_safety.py" "$test_binary"
