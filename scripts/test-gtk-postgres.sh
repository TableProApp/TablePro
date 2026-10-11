#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "${TABLEPRO_GTK_POSTGRES_DBUS_ACTIVE:-0}" != "1" ]]; then
  runtime="$(mktemp -d "${TMPDIR:-/tmp}/tablepro-gtk-postgres.XXXXXX")"
  mkdir -p "$runtime/home" "$runtime/config" "$runtime/data" "$runtime/cache" "$runtime/state" "$runtime/runtime"
  chmod 0700 "$runtime/runtime"
  cleanup_runtime() {
    if command -v fusermount3 >/dev/null 2>&1; then
      for mount in "$runtime/runtime/doc" "$runtime/runtime/gvfs"; do
        fusermount3 -uz -- "$mount" >/dev/null 2>&1 || true
      done
    fi
    rm -rf -- "$runtime" 2>/dev/null || true
  }
  trap cleanup_runtime EXIT
  TABLEPRO_GTK_POSTGRES_DBUS_ACTIVE=1 \
    ATSPI_DBUS_IMPLEMENTATION=dbus-daemon \
    XDG_CURRENT_DESKTOP=GNOME \
    HOME="$runtime/home" \
    XDG_CONFIG_HOME="$runtime/config" \
    XDG_DATA_HOME="$runtime/data" \
    XDG_CACHE_HOME="$runtime/cache" \
    XDG_STATE_HOME="$runtime/state" \
    XDG_RUNTIME_DIR="$runtime/runtime" \
    CARGO_HOME="${CARGO_HOME:-$(env HOME="$OLDPWD" sh -c 'echo ${CARGO_HOME:-$HOME/.cargo}')}" \
    RUSTUP_HOME="${RUSTUP_HOME:-$(env HOME="$OLDPWD" sh -c 'echo ${RUSTUP_HOME:-$HOME/.rustup}')}" \
    dbus-run-session -- "$ROOT/scripts/test-gtk-postgres.sh" "$@"
  exit $?
fi

for command_name in docker dbus-run-session gnome-keyring-daemon secret-tool; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "missing required command: $command_name" >&2
    exit 1
  fi
done

container="$(docker run --rm --detach --publish 127.0.0.1::5432 \
  --env POSTGRES_PASSWORD=tablepro_test --env POSTGRES_DB=bookie_test \
  postgres:17-alpine)"
cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

port="$(docker port "$container" 5432/tcp | sed -n 1p)"
port="${port##*:}"
attempt=0
until docker exec "$container" pg_isready --host=127.0.0.1 --username=postgres --dbname=bookie_test >/dev/null 2>&1 \
  && docker exec "$container" psql --host=127.0.0.1 --username=postgres --dbname=bookie_test --command='SELECT 1' >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if (( attempt >= 90 )); then
    docker logs "$container" >&2
    echo "PostgreSQL fixture did not become ready" >&2
    exit 1
  fi
  sleep 1
done

docker exec "$container" psql --username=postgres --dbname=bookie_test --set=ON_ERROR_STOP=1 --command='CREATE DATABASE bookie_other'
docker exec --interactive "$container" psql --username=postgres --dbname=bookie_other --set=ON_ERROR_STOP=1 \
  --command='CREATE TABLE other_things (id integer PRIMARY KEY, label text)' --command="INSERT INTO other_things VALUES (1, 'switched')"
docker exec --interactive "$container" psql --username=postgres --dbname=bookie_test --set=ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE people (id integer PRIMARY KEY, name text NOT NULL, profile jsonb, active boolean NOT NULL);
INSERT INTO people VALUES
  (1, 'Ada Lovelace', '{"role":"analyst","langs":["en","fr"]}', true),
  (2, 'Grace Hopper', NULL, false);
CREATE TYPE public.gtk_enum_state AS ENUM ('ready', 'done', 'NULL', '');
CREATE TABLE public.enum_grid (id integer PRIMARY KEY, state public.gtk_enum_state, sibling text NOT NULL);
INSERT INTO public.enum_grid VALUES
  (1, 'ready', 'target'), (2, 'NULL', 'literal NULL'),
  (3, NULL, 'SQL NULL'), (4, '', 'empty'), (5, 'ready', 'sibling');
SQL

eval "$(printf 'tablepro-test' | gnome-keyring-daemon --daemonize --unlock --components=secrets)"
printf 'tablepro_test' | secret-tool store --label='BookiE GTK PostgreSQL fixture' \
  xdg:schema com.tablepro.linux.Password \
  connection-id 0b6d4a52-3d1a-4f0e-8f6c-5f3f0c2a9e11 \
  kind db_password

TABLEPRO_GTK_POSTGRES_CONTAINER="$container" \
  TABLEPRO_GTK_KEYRING_READY=1 \
  TABLEPRO_GTK_DBUS_ACTIVE=1 \
  TABLEPRO_GTK_POSTGRES_HOST=127.0.0.1 \
  TABLEPRO_GTK_POSTGRES_PORT="$port" \
  TABLEPRO_GTK_SCENARIO="${TABLEPRO_GTK_SCENARIO:-postgres_saved_connection_browses_rows_and_values,postgres_hidden_projection_refresh_and_edit_preserve_hidden_value,postgres_grid_edit_and_delete_commit_to_the_server,postgres_enum_grid_edit_preserves_native_label_and_siblings,postgres_database_switcher_reconnects_to_the_chosen_database}" \
  bash "$ROOT/scripts/test-gtk-safety.sh"
