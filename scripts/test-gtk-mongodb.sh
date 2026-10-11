#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${TABLEPRO_GTK_MONGODB_DBUS_ACTIVE:-0}" != "1" ]]; then
  cargo_home="${CARGO_HOME:-$HOME/.cargo}"
  rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
  runtime="$(mktemp -d "${TMPDIR:-/tmp}/tablepro-gtk-mongodb.XXXXXX")"
  mkdir -p "$runtime"/{home,config,data,cache,state,runtime}
  chmod 0700 "$runtime/runtime"
  cleanup_runtime() {
    if command -v fusermount3 >/dev/null 2>&1; then
      for mount in "$runtime/runtime/doc" "$runtime/runtime/gvfs"; do
        fusermount3 -uz -- "$mount" >/dev/null 2>&1 || true
      done
    fi
    rm -rf -- "$runtime"
  }
  trap cleanup_runtime EXIT
  TABLEPRO_GTK_MONGODB_DBUS_ACTIVE=1 \
    ATSPI_DBUS_IMPLEMENTATION=dbus-daemon \
    XDG_CURRENT_DESKTOP=GNOME \
    HOME="$runtime/home" \
    XDG_CONFIG_HOME="$runtime/config" \
    XDG_DATA_HOME="$runtime/data" \
    XDG_CACHE_HOME="$runtime/cache" \
    XDG_STATE_HOME="$runtime/state" \
    XDG_RUNTIME_DIR="$runtime/runtime" \
    CARGO_HOME="$cargo_home" \
    RUSTUP_HOME="$rustup_home" \
    dbus-run-session -- "$ROOT/scripts/test-gtk-mongodb.sh"
  exit $?
fi

for command_name in docker dbus-run-session gnome-keyring-daemon secret-tool rg; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing required command: $command_name" >&2
    exit 1
  fi
done

container="$(docker run --rm --detach --publish 127.0.0.1::27017 mongo:7 --bind_ip_all)"
cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

port="$(docker port "$container" 27017/tcp | sed -n 1p)"
port="${port##*:}"
attempt=0
until docker exec "$container" mongosh --quiet --eval 'db.adminCommand("ping").ok' | rg -q '^1$'; do
  attempt=$((attempt + 1))
  if (( attempt >= 90 )); then
    docker logs "$container" >&2
    echo "MongoDB fixture did not become ready" >&2
    exit 1
  fi
  sleep 1
done

docker exec "$container" mongosh --quiet bookie_test --eval \
  'db.people.insertMany([{_id: 1, name: "Ada Lovelace", note: "keep"}, {_id: 2, name: "Grace Hopper", note: "untouched"}])' >/dev/null

TABLEPRO_GTK_MONGODB_CONTAINER="$container" \
  TABLEPRO_GTK_MONGODB_HOST=127.0.0.1 \
  TABLEPRO_GTK_MONGODB_PORT="$port" \
  TABLEPRO_GTK_SCENARIO="${TABLEPRO_GTK_SCENARIO:-mongodb_grid_observes_cursor_values_until_refresh_and_edits_native_row}" \
  bash "$ROOT/scripts/test-gtk-safety.sh"
