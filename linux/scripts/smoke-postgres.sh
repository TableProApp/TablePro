#!/usr/bin/env bash
# Driver-level smoke: connect → list tables → fetch rows → edit a cell.
# Requires a running Postgres (see scripts/smoke-compose or the plan's podman one-liner).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOST="${SMOKE_PG_HOST:-127.0.0.1}"
PORT="${SMOKE_PG_PORT:-54329}"
USER="${SMOKE_PG_USER:-tablepro}"
PASS="${SMOKE_PG_PASS:-tablepro}"
DB="${SMOKE_PG_DB:-tablepro}"

if [[ -f "$ROOT/scripts/dev-env.sh" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/dev-env.sh"
fi

export SMOKE_PG_HOST="$HOST" SMOKE_PG_PORT="$PORT" SMOKE_PG_USER="$USER" SMOKE_PG_PASS="$PASS" SMOKE_PG_DB="$DB"

echo "Smoke against postgres://${USER}@${HOST}:${PORT}/${DB}"
cargo test -p tablepro-driver-postgres --test smoke_local -- --nocapture
echo "Smoke passed."
