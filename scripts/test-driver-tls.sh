#!/usr/bin/env bash
# Driver TLS tier: proves each network driver's TLS mode mapping against a
# real server holding a privately issued certificate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/driver-tls"
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
XDG_CONFIG_HOME="$(mktemp -d)"
export XDG_CONFIG_HOME
trap teardown EXIT

compose() {
  docker compose --project-directory "$FIXTURE" -f "$FIXTURE/docker-compose.yml" "$@"
}

teardown() {
  if [[ "$KEEP_UP" == "1" ]]; then
    echo "leaving the driver-tls fixture running (TABLEPRO_FIXTURE_KEEP_UP=1)"
  else
    compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  fi
  rm -rf "$XDG_CONFIG_HOME"
}

bash "$FIXTURE/generate-materials.sh" --force
compose down --volumes --remove-orphans >/dev/null 2>&1 || true
compose up -d --build --wait

export TABLEPRO_FIXTURE_DRIVER_TLS=1
export TABLEPRO_DRIVER_TLS_MATERIALS="$FIXTURE/materials"
export TABLEPRO_DRIVER_TLS_SSH_KEY="$FIXTURE/materials/ssh_client"

cargo test --locked -p tablepro-driver-tls-tests --tests -- --include-ignored --test-threads=1 --skip system_store_
SSL_CERT_FILE="$FIXTURE/materials/ca.crt" SSL_CERT_DIR="$FIXTURE/materials/empty-system-store" \
  cargo test --locked -p tablepro-driver-tls-tests --test system_trust -- --include-ignored --test-threads=1
