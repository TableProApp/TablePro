#!/usr/bin/env bash
set -euo pipefail

/opt/mssql/bin/sqlservr &
server_pid=$!
sqlcmd=/opt/mssql-tools18/bin/sqlcmd

for _ in $(seq 1 120); do
  if "$sqlcmd" -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -Q "SELECT 1" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

"$sqlcmd" -b -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -i /fixture/setup.sql
wait "$server_pid"
