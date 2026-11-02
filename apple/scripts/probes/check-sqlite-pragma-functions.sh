#!/usr/bin/env bash
#
# Lists the SQLite pragma table functions that change state, which SQLStateChangingFunctions names.
#
# A pragma_* table function exists for every pragma that returns a result. Measured on 3.54.0, the ones
# that take an argument are pragma_optimize, which runs ANALYZE, and the table and index reports, which
# take a name. The rest take at most a schema name, so a SELECT cannot hand one a value to set. Run
# after the SQLite the app links changes version.
#
# Usage: scripts/probes/check-sqlite-pragma-functions.sh [sqlite3]
#
set -euo pipefail

SQLITE="${1:-sqlite3}"
command -v "$SQLITE" > /dev/null || { echo "error: $SQLITE not found" >&2; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DB="$WORK/probe.db"
"$SQLITE" "$DB" "CREATE TABLE t(a); INSERT INTO t VALUES (1), (2);"

echo "sqlite: $("$SQLITE" --version | cut -d' ' -f1)"

for name in $("$SQLITE" "$DB" "SELECT name FROM pragma_pragma_list ORDER BY name"); do
    answer="$("$SQLITE" "$DB" "SELECT * FROM pragma_${name}(1)" 2>&1 || true)"
    case "$answer" in
        *"no such table"* | *"too many arguments"* | *"unknown database"*) ;;
        *) echo "takes an argument: pragma_${name}" ;;
    esac
done

"$SQLITE" "$DB" "SELECT * FROM pragma_optimize(0x10002)" > /dev/null
if "$SQLITE" "$DB" "SELECT count(*) FROM sqlite_stat1" > /dev/null 2>&1; then
    echo "pragma_optimize ran ANALYZE: sqlite_stat1 exists"
else
    echo "pragma_optimize changed nothing"
fi
