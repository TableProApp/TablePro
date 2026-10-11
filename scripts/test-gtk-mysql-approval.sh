#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${TABLEPRO_GTK_MYSQL_DBUS_ACTIVE:-0}" != "1" ]]; then
  runtime="$(mktemp -d "${TMPDIR:-/tmp}/tablepro-gtk-mysql.XXXXXX")"
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
  cargo_home="${CARGO_HOME:-$HOME/.cargo}"
  rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
  ATSPI_DBUS_IMPLEMENTATION=dbus-daemon \
  TABLEPRO_GTK_MYSQL_DBUS_ACTIVE=1 \
    CARGO_HOME="$cargo_home" \
    RUSTUP_HOME="$rustup_home" \
    HOME="$runtime/home" \
    XDG_CONFIG_HOME="$runtime/config" \
    XDG_DATA_HOME="$runtime/data" \
    XDG_CACHE_HOME="$runtime/cache" \
    XDG_STATE_HOME="$runtime/state" \
    XDG_RUNTIME_DIR="$runtime/runtime" \
    dbus-run-session -- "$ROOT/scripts/test-gtk-mysql-approval.sh"
  exit $?
fi

for command_name in docker dbus-run-session gnome-keyring-daemon secret-tool; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing required command: $command_name" >&2
    exit 1
  fi
done

container="$(docker run --rm --detach --publish 127.0.0.1::3306 \
  --env MYSQL_ROOT_PASSWORD=tablepro_test \
  --env MYSQL_ROOT_HOST=% \
  --env MYSQL_DATABASE=bookie_test \
  mysql:8.0 --default-authentication-plugin=mysql_native_password)"
cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

published="$(docker port "$container" 3306/tcp)"
port="${published##*:}"
attempt=0
until docker exec "$container" mysql --user=root --password=tablepro_test --batch --skip-column-names \
  --execute='SELECT 1' >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if (( attempt >= 90 )); then
    docker logs "$container" >&2
    echo "MySQL fixture did not become ready" >&2
    exit 1
  fi
  sleep 1
done

eval "$(printf 'tablepro-test' | gnome-keyring-daemon --daemonize --unlock --components=secrets)"
printf 'tablepro_test' | secret-tool store --label='BookiE GTK MySQL fixture' \
  xdg:schema com.tablepro.linux.Password \
  connection-id c38e2d93-4314-4c18-b192-08f164386e09 \
  kind db_password
TABLEPRO_GTK_KEYRING_READY=1 \
  TABLEPRO_GTK_DBUS_ACTIVE=1 \
  TABLEPRO_GTK_SCENARIO=mysql_unparseable_routine_dialog_denial_preserves_database \
  TABLEPRO_GTK_MYSQL_CONTAINER="$container" \
  TABLEPRO_GTK_MYSQL_HOST=127.0.0.1 \
  TABLEPRO_GTK_MYSQL_PORT="$port" \
  bash "$ROOT/scripts/test-gtk-safety.sh"
