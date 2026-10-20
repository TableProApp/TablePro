#!/usr/bin/env bash
#
# Round-trip a table of more than 100 MB through every export format on a live MySQL or PostgreSQL
# server. export-import-roundtrip/main.swift loads the driver and format plugins of a built
# TablePro.app, exports the table with each format, imports the file back with the matching import
# plugin, and prints the row count and a checksum the server computes on both sides. A SQL dump,
# gzipped or split into parts, is restored with the engine's own client into a second database.
#
# The unit-plan version of the same check, on SQLite, is FormatPluginTests/ExportImportRoundTripTests.
#
# Usage:
#   scripts/probes/check-export-import-roundtrip.sh <mysql|postgresql> [host] [port] [user]
#
# The plugins come from PROBE_PRODUCTS (a Build/Products/Debug folder holding the built .tableplugin
# bundles and TableProPluginKit.framework), else from the newest such folder in DerivedData. The
# password comes from MYSQL_PWD or PGPASSWORD. PROBE_ROWS sets the rows (200000, about 130 MB of CSV),
# PROBE_FORMATS the formats (csv,json,ndjson,xlsx,sql,sql.gz,sql-split). Creates and drops the
# databases tablepro_roundtrip_probe and tablepro_roundtrip_restore. Needs xcrun swiftc and the
# engine's client. Exits 0 when every format round-trips, 1 when one does not, 3 when it cannot run.

set -uo pipefail

ENGINE="${1:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROWS="${PROBE_ROWS:-200000}"
FORMATS="${PROBE_FORMATS:-csv,json,ndjson,xlsx,sql,sql.gz,sql-split}"
SOURCE_DB=tablepro_roundtrip_probe
RESTORE_DB=tablepro_roundtrip_restore
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cannot_run() {
    echo "$1" >&2
    exit 3
}

case "$ENGINE" in
    postgresql)
        HOST="${2:-127.0.0.1}"
        PORT="${3:-5432}"
        USER_NAME="${4:-postgres}"
        PASSWORD="${PGPASSWORD:-}"
        command -v psql > /dev/null || cannot_run "psql not found"
        export PGOPTIONS="-c client_min_messages=warning"
        CLIENT=(psql -X -q -h "$HOST" -p "$PORT" -U "$USER_NAME" -v ON_ERROR_STOP=1)
        admin() { "${CLIENT[@]}" -d postgres -c "$1" > /dev/null; }
        RESTORE=("${CLIENT[@]}" -d "$RESTORE_DB")
        ;;
    mysql)
        HOST="${2:-127.0.0.1}"
        PORT="${3:-3306}"
        USER_NAME="${4:-root}"
        PASSWORD="${MYSQL_PWD:-}"
        command -v mysql > /dev/null || cannot_run "mysql client not found"
        CLIENT=(mysql --no-defaults --default-character-set=utf8mb4 -h "$HOST" -P "$PORT" -u "$USER_NAME")
        admin() { "${CLIENT[@]}" -e "$1"; }
        RESTORE=("${CLIENT[@]}" "$RESTORE_DB")
        ;;
    *)
        cannot_run "usage: $0 <mysql|postgresql> [host] [port] [user]"
        ;;
esac

PRODUCTS="${PROBE_PRODUCTS:-}"
if [ -z "$PRODUCTS" ]; then
    for dir in "$HOME"/Library/Developer/Xcode/DerivedData/TablePro-*/Build/Products/Debug; do
        { [ -d "$dir/SQLExport.tableplugin" ] && [ -d "$dir/TableProPluginKit.framework" ]; } || continue
        if [ -z "$PRODUCTS" ] || [ "$dir/SQLExport.tableplugin" -nt "$PRODUCTS/SQLExport.tableplugin" ]; then
            PRODUCTS="$dir"
        fi
    done
fi
[ -d "$PRODUCTS/TableProPluginKit.framework" ] || cannot_run "no built plugins found; build, or set PROBE_PRODUCTS"
echo "plugins: $PRODUCTS"

admin "SELECT 1" > /dev/null 2>&1 || cannot_run "no $ENGINE server at $HOST:$PORT as $USER_NAME"

if ! xcrun swiftc -O -parse-as-library -module-name RoundTripProbe \
    -F "$PRODUCTS" -framework TableProPluginKit -Xlinker -rpath -Xlinker "$PRODUCTS" \
    "$ROOT/scripts/probes/export-import-roundtrip/main.swift" -o "$WORK/tablepro-roundtrip-probe" > "$WORK/swiftc.log" 2>&1; then
    cat "$WORK/swiftc.log" >&2
    cannot_run "the probe did not compile"
fi

for database in "$SOURCE_DB" "$RESTORE_DB"; do
    admin "DROP DATABASE IF EXISTS $database" || cannot_run "could not drop $database"
    admin "CREATE DATABASE $database" || cannot_run "could not create $database"
done

PROBE_PASSWORD="$PASSWORD" "$WORK/tablepro-roundtrip-probe" \
    --plugins "$PRODUCTS" --engine "$ENGINE" --host "$HOST" --port "$PORT" --user "$USER_NAME" \
    --database "$SOURCE_DB" --restore-database "$RESTORE_DB" --rows "$ROWS" --work "$WORK" \
    --formats "$FORMATS" -- "${RESTORE[@]}"
STATUS=$?
# The plugins keep their settings in the probe's own defaults domain.
defaults delete tablepro-roundtrip-probe > /dev/null 2>&1

for database in "$SOURCE_DB" "$RESTORE_DB"; do
    admin "DROP DATABASE IF EXISTS $database"
done
exit "$STATUS"
