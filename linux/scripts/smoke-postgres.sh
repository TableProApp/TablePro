#!/usr/bin/env bash
# Driver-level smoke: connect, list tables, fetch rows, edit a cell.
# Needs a Postgres already listening on SMOKE_PG_HOST:SMOKE_PG_PORT.
# docs/testing.md has a one-liner that starts one.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SMOKE_HOST="${SMOKE_PG_HOST:-127.0.0.1}"
SMOKE_PORT="${SMOKE_PG_PORT:-54329}"
SMOKE_USER="${SMOKE_PG_USER:-tablepro}"
SMOKE_PASS="${SMOKE_PG_PASS:-tablepro}"
SMOKE_DB="${SMOKE_PG_DB:-tablepro}"

if [[ -f "$ROOT/scripts/dev-env.sh" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/dev-env.sh"
fi

export SMOKE_PG_HOST="$SMOKE_HOST"
export SMOKE_PG_PORT="$SMOKE_PORT"
export SMOKE_PG_USER="$SMOKE_USER"
export SMOKE_PG_PASS="$SMOKE_PASS"
export SMOKE_PG_DB="$SMOKE_DB"

echo "Smoke against postgres://${SMOKE_USER}@${SMOKE_HOST}:${SMOKE_PORT}/${SMOKE_DB}"
cargo test -p tablepro-driver-postgres --test smoke_local -- --include-ignored --nocapture
echo "Smoke passed."
