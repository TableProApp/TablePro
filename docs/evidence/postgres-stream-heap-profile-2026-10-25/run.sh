#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUTPUT_DIR="${1:?usage: run.sh OUTPUT_DIR}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
REAL_BINARY="$TARGET_DIR/installed-release/usr/bin/tablepro"
POSTGRES_IMAGE="postgres:16-alpine@sha256:57c72fd2a128e416c7fcc499958864df5301e940bca0a56f58fddf30ffc07777"
RUNTIME="$(mktemp -d "${TMPDIR:-/tmp}/bookie-stream-heap.XXXXXX")"
CONTAINER=""

cleanup() {
  if [[ -n "$CONTAINER" ]]; then
    docker rm --force "$CONTAINER" >/dev/null 2>&1 || true
  fi
  if [[ "${KEEP_TEMP:-0}" == "1" ]]; then
    printf 'temporary profile files: %s\n' "$RUNTIME"
  else
    rm -rf -- "$RUNTIME"
  fi
}
trap cleanup EXIT

mkdir -p "$RUNTIME/home" "$RUNTIME/config" "$RUNTIME/data" "$RUNTIME/cache" "$RUNTIME/state" "$RUNTIME/runtime"
chmod 0700 "$RUNTIME/runtime"
test -x "$REAL_BINARY"

CONTAINER="$(docker run --rm --detach --publish 127.0.0.1::5432 \
  --env POSTGRES_PASSWORD=tablepro_test --env POSTGRES_DB=bookie_test "$POSTGRES_IMAGE")"
attempt=0
until docker exec "$CONTAINER" pg_isready --host=127.0.0.1 --username=postgres --dbname=bookie_test >/dev/null 2>&1; do
  attempt=$((attempt + 1))
  if (( attempt >= 180 )); then
    docker logs "$CONTAINER" >&2
    exit 1
  fi
  sleep 1
done

docker exec --interactive "$CONTAINER" psql --username=postgres --dbname=bookie_test --set=ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE people (id integer PRIMARY KEY, name text NOT NULL);
INSERT INTO people VALUES (1, 'Ada Lovelace');
CREATE TABLE big AS
SELECT g AS id,
       md5(g::text) AS hash,
       'user_' || g AS username,
       (random() * 100000)::numeric(10, 2) AS amount,
       now() - (g || ' seconds')::interval AS created_at,
       g % 2 = 0 AS flag,
       repeat('lorem ipsum ', 5) AS note,
       g % 1000 AS bucket,
       CASE WHEN g % 10 = 0 THEN NULL ELSE g % 7 END AS maybe,
       random() AS ratio
FROM generate_series(1, 2000000) AS g;
SQL

PORT="$(docker port "$CONTAINER" 5432/tcp | sed -n '1p')"
PORT="${PORT##*:}"
HEAPTRACK="${HEAPTRACK:-1}"
if [[ "$HEAPTRACK" == "1" ]]; then
  cat >"$RUNTIME/profile-wrapper" <<WRAPPER
#!/usr/bin/env bash
exec heaptrack --output "$OUTPUT_DIR/bookie.heaptrack" --record-only "$REAL_BINARY" "\$@"
WRAPPER
  chmod 0700 "$RUNTIME/profile-wrapper"
  export TABLEPRO_PROFILE_REAL_BINARY="$REAL_BINARY"
  export TABLEPRO_PROFILE_WRAPPER="$RUNTIME/profile-wrapper"
  profile_output="$OUTPUT_DIR/profile.json"
else
  export TABLEPRO_PROFILE_WRAPPER="$REAL_BINARY"
  unset TABLEPRO_PROFILE_REAL_BINARY
  profile_output="$OUTPUT_DIR/profile-uninstrumented.json"
fi

cat >"$RUNTIME/run-inner.sh" <<'INNER'
#!/usr/bin/env bash
set -euo pipefail
eval "$(printf 'tablepro-test' | gnome-keyring-daemon --daemonize --unlock --components=secrets)"
printf 'tablepro_test' | secret-tool store --label='BookiE result heap profile' \
  xdg:schema com.tablepro.linux.Password \
  connection-id 0b6d4a52-3d1a-4f0e-8f6c-5f3f0c2a9e11 \
  kind db_password
xvfb-run --auto-servernum --server-args='-screen 0 1280x1024x24 -nolisten tcp' \
  bash "$RUNTIME/run-display.sh"
INNER
chmod 0700 "$RUNTIME/run-inner.sh"

cat >"$RUNTIME/run-display.sh" <<'DISPLAY'
#!/usr/bin/env bash
set -euo pipefail
export GDK_BACKEND=x11
export GSK_RENDERER=cairo
export GTK_A11Y=atspi
export ATSPI_DBUS_IMPLEMENTATION=dbus-daemon
export XDG_CURRENT_DESKTOP=GNOME
unset NO_AT_BRIDGE
dbus-update-activation-environment DISPLAY XAUTHORITY GDK_BACKEND GTK_A11Y
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \
  --method org.a11y.Bus.GetAddress >/dev/null
exec /usr/bin/python3 "$TABLEPRO_PROFILE_REPO/docs/evidence/postgres-stream-heap-profile-2026-10-25/probe.py" \
  "$TABLEPRO_PROFILE_WRAPPER"
DISPLAY
chmod 0700 "$RUNTIME/run-display.sh"

export HOME="$RUNTIME/home"
export RUNTIME
export XDG_CONFIG_HOME="$RUNTIME/config"
export XDG_DATA_HOME="$RUNTIME/data"
export XDG_CACHE_HOME="$RUNTIME/cache"
export XDG_STATE_HOME="$RUNTIME/state"
export XDG_RUNTIME_DIR="$RUNTIME/runtime"
export ATSPI_DBUS_IMPLEMENTATION=dbus-daemon
export XDG_CURRENT_DESKTOP=GNOME
export TABLEPRO_PROFILE_REPO="$ROOT"
export TABLEPRO_PROFILE_OUT="$profile_output"
export TABLEPRO_PROFILE_ROWS=2000000
export TABLEPRO_PROFILE_REPETITIONS=1
export TABLEPRO_PROFILE_VERIFY_PAGER=1
export TABLEPRO_GTK_ARTIFACT_DIR="$OUTPUT_DIR/failure-artifacts"
export TABLEPRO_GTK_SCENARIO=profile_postgres_large_stream
export TABLEPRO_GTK_POSTGRES_CONTAINER="$CONTAINER"
export TABLEPRO_GTK_POSTGRES_HOST=127.0.0.1
export TABLEPRO_GTK_POSTGRES_PORT="$PORT"
export TABLEPRO_GTK_DBUS_ACTIVE=1
export TABLEPRO_GTK_KEYRING_READY=1

dbus-run-session -- bash "$RUNTIME/run-inner.sh"
if [[ "$HEAPTRACK" == "1" ]]; then
  heaptrack_print "$OUTPUT_DIR/bookie.heaptrack.zst" \
    | sed "s|$REAL_BINARY|BookiE release binary|g" \
    | gzip -n -9 >"$OUTPUT_DIR/heaptrack-report.txt.gz"
  rm -f "$OUTPUT_DIR/bookie.heaptrack.zst"
  printf 'Heaptrack report: %s\n' "$OUTPUT_DIR/heaptrack-report.txt.gz"
fi
