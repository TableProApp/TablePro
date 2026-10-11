#!/usr/bin/env bash
set -euo pipefail

work_root="$(mktemp -d)"
socket_root="$work_root/socket"
config_root="$work_root/config"
secret_root="$work_root/secret"
mkdir -p "$socket_root" "$config_root" \
  "$secret_root/home" "$secret_root/data" "$secret_root/cache" "$secret_root/state" "$secret_root/runtime"
chmod 0700 "$secret_root/runtime"
container_name="tablepro-pg-socket-${RANDOM}-$$"
cleanup() {
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  # PostgreSQL owns the sticky socket directory and its lock file inside the
  # bind mount. Clear those as container root before removing our temp root.
  docker run --rm --entrypoint sh --volume "$socket_root:/cleanup" postgres:16-alpine \
    -c 'rm -f /cleanup/.s.PGSQL.*; chmod 0777 /cleanup' >/dev/null 2>&1 || true
  rm -rf -- "$work_root"
}
trap cleanup EXIT

chmod 0777 "$socket_root"
docker run --detach --name "$container_name" \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  --volume "$socket_root:/var/run/postgresql" \
  postgres:16-alpine >/dev/null

for _ in $(seq 1 60); do
  if [[ -S "$socket_root/.s.PGSQL.5432" ]]; then
    break
  fi
  sleep 1
done
if [[ ! -S "$socket_root/.s.PGSQL.5432" ]]; then
  docker logs "$container_name" >&2
  echo "PostgreSQL socket did not become ready" >&2
  exit 1
fi

TABLEPRO_PG_SOCKET_DIR="$socket_root" \
  cargo test -p tablepro-driver-postgres --test socket_local -- --include-ignored --test-threads=1

cargo_home="${CARGO_HOME:-$HOME/.cargo}"
rustup_home="${RUSTUP_HOME:-$HOME/.rustup}"
CARGO_HOME="$cargo_home" \
  RUSTUP_HOME="$rustup_home" \
  HOME="$secret_root/home" \
  XDG_CONFIG_HOME="$config_root" \
  XDG_DATA_HOME="$secret_root/data" \
  XDG_CACHE_HOME="$secret_root/cache" \
  XDG_STATE_HOME="$secret_root/state" \
  XDG_RUNTIME_DIR="$secret_root/runtime" \
  TABLEPRO_PG_SOCKET_DIR="$socket_root" \
  dbus-run-session -- bash -c '
    set -euo pipefail
    eval "$(printf "tablepro-test" | gnome-keyring-daemon --daemonize --unlock --components=secrets)"
    cargo test -p tablepro-agentd --test socket_local -- --include-ignored --test-threads=1
  '
