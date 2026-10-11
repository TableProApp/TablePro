#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/postgres-release"
STATE="$FIXTURE/state"
cd "$ROOT"

if ! command -v docker >/dev/null 2>&1; then
  echo "missing required command: docker" >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "docker compose is required" >&2
  exit 1
fi

KEEP_UP="${TABLEPRO_FIXTURE_KEEP_UP:-0}"

compose() {
  docker compose --project-directory "$FIXTURE" -f "$FIXTURE/docker-compose.yml" "$@"
}

teardown() {
  if [[ "$KEEP_UP" == "1" ]]; then
    echo "leaving the fixture running (TABLEPRO_FIXTURE_KEEP_UP=1)"
    return
  fi
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf -- "${secret_root:-}"
}

wait_for_port() {
  local host="$1" port="$2" label="$3"
  for _ in $(seq 1 120); do
    if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  echo "$label did not accept connections on $host:$port" >&2
  return 1
}

bash "$FIXTURE/generate-materials.sh"

mkdir -p "$STATE/config"
rm -f "$STATE/config/tablepro/known_hosts"

trap teardown EXIT
compose down --volumes --remove-orphans >/dev/null 2>&1 || true
compose up -d --build --wait

wait_for_port 127.0.0.1 8474 "toxiproxy api"
wait_for_port 127.0.0.1 5433 "postgres path"
wait_for_port 127.0.0.1 2223 "bastion path"

# A forwarded Unix socket's path (under XDG_RUNTIME_DIR) is capped at
# 100 bytes, so the isolated runtime dir has to stay short -- the
# fixture's own state directory, deep under the checked-out repo, is
# already too long for that once a socket name is appended.
secret_root="$(mktemp -d)"
mkdir -p "$secret_root/home" "$secret_root/data" "$secret_root/cache" "$secret_root/state" "$secret_root/runtime"
chmod 0700 "$secret_root/runtime"

cargo_home="${CARGO_HOME:-$HOME/.cargo}"
target_dir="${CARGO_TARGET_DIR:-$ROOT/target}"
CARGO_HOME="$cargo_home" \
RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}" \
  HOME="$secret_root/home" \
  XDG_CONFIG_HOME="$STATE/config" \
  XDG_DATA_HOME="$secret_root/data" \
  XDG_CACHE_HOME="$secret_root/cache" \
  XDG_STATE_HOME="$secret_root/state" \
  XDG_RUNTIME_DIR="$secret_root/runtime" \
  TABLEPRO_FIXTURE_POSTGRES_RELEASE=1 \
  TABLEPRO_FIXTURE_MATERIALS="$FIXTURE/materials" \
  TABLEPRO_TARGET_DIR="$target_dir" \
  TABLEPRO_GTK_POSTGRES_CONTAINER="$(compose ps -q db)" \
  dbus-run-session -- bash -c '
    set -euo pipefail
    eval "$(printf "tablepro-test" | gnome-keyring-daemon --daemonize --unlock --components=secrets)"
    PATH="$TABLEPRO_TARGET_DIR/debug:$PATH" cargo build --locked -p tablepro-ssh --bin tablepro-askpass
    PATH="$TABLEPRO_TARGET_DIR/debug:$PATH" cargo test --locked -p tablepro-agentd --test g5_system_openssh -- --include-ignored --test-threads=1
    cargo test --locked -p tablepro-agentd --test mtls -- --include-ignored --test-threads=1
    cargo test --locked -p tablepro-release-tests --tests -- --include-ignored --test-threads=1
    cargo build --locked -p tablepro-app --bin tablepro-app
    TABLEPRO_GTK_DBUS_ACTIVE=0 \
      TABLEPRO_GTK_POSTGRES_DB=tablepro \
      TABLEPRO_GTK_POSTGRES_USER=tablepro \
      TABLEPRO_GTK_POSTGRES_MTLS_PASSWORD=tablepro \
      TABLEPRO_GTK_BINARY="${TABLEPRO_GTK_BINARY:-$TABLEPRO_TARGET_DIR/debug/tablepro-app}" \
      TABLEPRO_GTK_SCENARIO="${TABLEPRO_GTK_SCENARIO:-postgres_saved_mtls_connection_authenticates_and_queries,postgres_ssh_unknown_host_key_decline_is_durably_audited,postgres_ssh_multihop_trusts_both_hops_and_queries,postgres_ssh_second_hop_decline_does_not_learn_key,postgres_ssh_changed_second_hop_key_is_refused,postgres_ssh_setup_failure_is_durably_audited,postgres_ssh_tunnel_loss_retires_session_and_reconnects}" \
      TABLEPRO_GTK_POSTGRES_MTLS_PORT=5433 \
      TABLEPRO_GTK_POSTGRES_MTLS_HOST=localhost \
      TABLEPRO_GTK_POSTGRES_MTLS_DB=tablepro \
      TABLEPRO_GTK_POSTGRES_MTLS_USER=tablepro_mtls \
      TABLEPRO_GTK_POSTGRES_MTLS_CA="$TABLEPRO_FIXTURE_MATERIALS/ca.crt" \
      TABLEPRO_GTK_POSTGRES_MTLS_CERT="$TABLEPRO_FIXTURE_MATERIALS/client.crt" \
      TABLEPRO_GTK_POSTGRES_MTLS_KEY="$TABLEPRO_FIXTURE_MATERIALS/client.key" \
      TABLEPRO_GTK_POSTGRES_SSH_AUDIT_PORT=2223 \
      TABLEPRO_GTK_POSTGRES_SSH_AUDIT_HOST=127.0.0.1 \
      TABLEPRO_GTK_POSTGRES_SSH_AUDIT_JUMP_HOST=relay \
      TABLEPRO_GTK_POSTGRES_SSH_AUDIT_JUMP_PORT=22 \
      TABLEPRO_GTK_POSTGRES_SSH_AUDIT_JUMP_USER=tunnel \
      TABLEPRO_GTK_POSTGRES_SSH_AUDIT_READ_ONLY=false \
      TABLEPRO_GTK_POSTGRES_SSH_AUDIT_DB_HOST=db.tablepro.test \
      TABLEPRO_GTK_POSTGRES_SSH_AUDIT_DB_PORT=5432 \
      TABLEPRO_GTK_POSTGRES_SSH_AUDIT_KEY="$TABLEPRO_FIXTURE_MATERIALS/client_ed25519_key" \
      TABLEPRO_GTK_POSTGRES_SSH_AUDIT_CA="$TABLEPRO_FIXTURE_MATERIALS/ca.crt" \
      TABLEPRO_GTK_POSTGRES_SSH_AUDIT_PASSWORD=tablepro \
      bash scripts/test-gtk-safety.sh
  '
