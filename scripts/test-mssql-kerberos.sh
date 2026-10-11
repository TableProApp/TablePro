#!/usr/bin/env bash
# Opt-in end-to-end SQL Server Kerberos + TLS qualification using a local AD DC.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$ROOT/tests/fixtures/mssql-kerberos"
cd "$ROOT"

for command in docker cargo ktutil openssl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "missing required command: $command" >&2
    exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  echo "Docker Compose is required" >&2
  exit 1
fi

TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT/target}"
export BOOKIE_TEST_DEPS="$TARGET_DIR/debug/deps"
export BOOKIE_UID="$(id -u)"
export BOOKIE_GID="$(id -g)"
export BOOKIE_TEST_BINARY=placeholder
COMPOSE=(docker compose --project-directory "$FIXTURE" -f "$FIXTURE/docker-compose.yml")
KEEP_UP="${BOOKIE_MSSQL_KERBEROS_KEEP_UP:-0}"
AD_ADMIN_CREDENTIAL='Administrator%Passw0rd'

teardown() {
  if [[ "$KEEP_UP" == "1" ]]; then
    echo "leaving the SQL Server Kerberos fixture and its generated keytab in place"
  else
    "${COMPOSE[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$FIXTURE/materials"
  fi
}
trap teardown EXIT

"${COMPOSE[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
bash "$FIXTURE/generate-materials.sh"
"${COMPOSE[@]}" build client mssql
"${COMPOSE[@]}" up -d --wait ad

"${COMPOSE[@]}" exec -T ad samba-tool user create bookiekerb \
  'BookieFixture!2026' --given-name=Bookie --surname=Kerberos
"${COMPOSE[@]}" exec -T ad samba-tool user create mssqlsvc \
  'BookieFixture!2026' --given-name=Bookie --surname=SQL
"${COMPOSE[@]}" exec -T ad samba-tool spn add \
  MSSQLSvc/mssql.domain1.sink.test:1433 mssqlsvc
"${COMPOSE[@]}" exec -T ad samba-tool dns add 127.0.0.1 domain1.sink.test \
  mssql A 172.30.50.3 -U "$AD_ADMIN_CREDENTIAL"
"${COMPOSE[@]}" exec -T ad samba-tool dns add 127.0.0.1 domain1.sink.test \
  DOMAIN1 A 172.30.50.2 -U "$AD_ADMIN_CREDENTIAL"
"${COMPOSE[@]}" exec -T ad samba-tool dns zonecreate 127.0.0.1 \
  50.30.172.in-addr.arpa -U "$AD_ADMIN_CREDENTIAL"
"${COMPOSE[@]}" exec -T ad samba-tool dns add 127.0.0.1 50.30.172.in-addr.arpa \
  2 PTR dc1.domain1.sink.test. -U "$AD_ADMIN_CREDENTIAL"

"${COMPOSE[@]}" exec -T ad samba-tool domain exportkeytab \
  /tmp/mssql-spn.keytab --principal=MSSQLSvc/mssql.domain1.sink.test:1433
"${COMPOSE[@]}" exec -T ad samba-tool domain exportkeytab \
  /tmp/mssql-account.keytab --principal=mssqlsvc
"${COMPOSE[@]}" cp ad:/tmp/mssql-spn.keytab "$FIXTURE/materials/mssql-spn.keytab"
"${COMPOSE[@]}" cp ad:/tmp/mssql-account.keytab "$FIXTURE/materials/mssql-account.keytab"
printf 'rkt %s\nrkt %s\nwkt %s\nquit\n' \
  "$FIXTURE/materials/mssql-spn.keytab" \
  "$FIXTURE/materials/mssql-account.keytab" \
  "$FIXTURE/materials/mssql.keytab" | ktutil
rm -f "$FIXTURE/materials/mssql-spn.keytab" "$FIXTURE/materials/mssql-account.keytab"
chmod 0600 "$FIXTURE/materials/mssql.keytab"

"${COMPOSE[@]}" up -d --wait mssql
cargo test --locked --features mssql-kerberos -p tablepro-driver-tls-tests \
  --test mssql_kerberos --no-run
test_binary="$(find "$BOOKIE_TEST_DEPS" -maxdepth 1 -type f -executable -name 'mssql_kerberos-*' -print -quit)"
if [[ -z "$test_binary" ]]; then
  echo "could not locate the compiled mssql_kerberos integration test" >&2
  exit 1
fi
export BOOKIE_TEST_BINARY="$(basename "$test_binary")"

"${COMPOSE[@]}" run --rm client
