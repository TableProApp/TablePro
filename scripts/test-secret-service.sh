#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Never unlock or write a probe into the user's desktop keyring.
if [[ "${TABLEPRO_SECRET_DBUS_ACTIVE:-0}" != "1" ]]; then
  secret_root="$(mktemp -d)"
  mkdir -p \
    "$secret_root/home" \
    "$secret_root/config" \
    "$secret_root/data" \
    "$secret_root/cache" \
    "$secret_root/state" \
    "$secret_root/runtime"
  chmod 0700 "$secret_root/runtime"
  trap 'rm -rf -- "$secret_root"' EXIT
  cargo_home="${CARGO_HOME:-$HOME/.cargo}"
  rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
  TABLEPRO_SECRET_DBUS_ACTIVE=1 \
    CARGO_HOME="$cargo_home" \
    RUSTUP_HOME="$rustup_home" \
    HOME="$secret_root/home" \
    XDG_CONFIG_HOME="$secret_root/config" \
    XDG_DATA_HOME="$secret_root/data" \
    XDG_CACHE_HOME="$secret_root/cache" \
    XDG_STATE_HOME="$secret_root/state" \
    XDG_RUNTIME_DIR="$secret_root/runtime" \
    dbus-run-session -- "$ROOT/scripts/test-secret-service.sh" "$@"
  exit
fi

eval "$(printf 'tablepro-test' | gnome-keyring-daemon --daemonize --unlock --components=secrets)"
printf 'probe' | secret-tool store --label='TablePro CI probe' application tablepro-ci
secret-tool clear application tablepro-ci
python3 "$ROOT/scripts/run-isolated-tests.py" keyring
