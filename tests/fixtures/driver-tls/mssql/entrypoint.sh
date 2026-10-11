#!/bin/bash
set -e

/opt/mssql/bin/sqlservr &
SERVER_PID=$!

SQLCMD=/opt/mssql-tools18/bin/sqlcmd
for _ in $(seq 1 60); do
  if "$SQLCMD" -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -Q "SELECT 1" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

"$SQLCMD" -C -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -i /fixture/setup.sql

wait "$SERVER_PID"
