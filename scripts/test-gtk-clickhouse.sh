#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${TABLEPRO_GTK_CLICKHOUSE_DBUS_ACTIVE:-0}" != "1" ]]; then
  cargo_home="${CARGO_HOME:-$HOME/.cargo}"
  rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
  runtime="$(mktemp -d "${TMPDIR:-/tmp}/tablepro-gtk-clickhouse.XXXXXX")"
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
  TABLEPRO_GTK_CLICKHOUSE_DBUS_ACTIVE=1 \
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
    dbus-run-session -- "$ROOT/scripts/test-gtk-clickhouse.sh"
  exit $?
fi

for command_name in docker dbus-run-session gnome-keyring-daemon secret-tool rg; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing required command: $command_name" >&2
    exit 1
  fi
done

container="$(docker run --rm --detach --publish 127.0.0.1::8123 \
  --env CLICKHOUSE_PASSWORD=tablepro \
  --env CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1 \
  clickhouse/clickhouse-server:24.8)"
cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

port="$(docker port "$container" 8123/tcp | sed -n 1p)"
port="${port##*:}"
attempt=0
until docker exec "$container" clickhouse-client --user=default --password=tablepro \
  --query='SELECT 1' 2>/dev/null | rg -q '^1$'; do
  attempt=$((attempt + 1))
  if (( attempt >= 90 )); then
    docker logs "$container" >&2
    echo "ClickHouse fixture did not become ready" >&2
    exit 1
  fi
  sleep 1
done

docker exec "$container" clickhouse-client --user=default --password=tablepro \
  --query="CREATE TABLE enum_grid (id UInt8, state8 Nullable(Enum8('low8' = -128, 'NULL' = 0, 'high8' = 127, '' = 1)), state16 Nullable(Enum16('low16' = -32768, 'NULL' = 0, 'high16' = 32767, '' = 1))) ENGINE = MergeTree ORDER BY id"
docker exec "$container" clickhouse-client --user=default --password=tablepro \
  --query="INSERT INTO enum_grid VALUES (1, 'low8', 'low16'), (2, 'NULL', 'NULL'), (3, NULL, NULL), (4, '', ''), (5, 'high8', 'high16')"

eval "$(printf 'tablepro' | gnome-keyring-daemon --daemonize --unlock --components=secrets)"
printf 'tablepro' | secret-tool store --label='BookiE GTK ClickHouse fixture' \
  xdg:schema com.tablepro.linux.Password \
  connection-id 31e33a85-4cbd-42ec-8f54-c66be5630f17 \
  kind db_password

TABLEPRO_GTK_KEYRING_READY=1 \
  TABLEPRO_GTK_DBUS_ACTIVE=1 \
  TABLEPRO_GTK_CLICKHOUSE_CONTAINER="$container" \
  TABLEPRO_GTK_CLICKHOUSE_HOST=127.0.0.1 \
  TABLEPRO_GTK_CLICKHOUSE_PORT="$port" \
  TABLEPRO_GTK_SCENARIO=clickhouse_enum_grid_edit_preserves_native_label_and_siblings \
  bash "$ROOT/scripts/test-gtk-safety.sh"
