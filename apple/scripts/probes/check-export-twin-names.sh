#!/usr/bin/env bash
#
# Checks that SQLite, DuckDB and MariaDB exports keep apart tables and columns whose names differ only in Unicode form
# (NFC and NFD), which those engines keep apart and Swift's String equates.
#
# Builds this checkout's driver and SQL export with SwiftPM and loads a fixture: two tables named café (composed and
# decomposed), each with a plain column the other has as a generated one and a foreign key to its own parent, and a
# table with a plain and a generated column named é in the two forms. It asks the driver's export reads for the
# schema, which must throw or answer each table as its own read does, then dumps each café table alone with the
# parents and the column table, restores each dump into an empty database and compares the rows.
# With --count (MariaDB) it dumps 50 plain tables instead and prints how many statements the export sent.
#
# Usage: scripts/probes/check-export-twin-names.sh <sqlite|duckdb|mariadb> [--count] [host] [port]
# Environment: PROBE_APPLE_ROOT (the apple/ folder to build, default this checkout's), PROBE_USER (MariaDB, default
# root), PROBE_PASSWORD, PROBE_DATABASE (MariaDB, default tablepro_export_twin_drivers): a database that must not exist
# yet, which it creates and drops.
# Prints OK, or BUG with what differs. Exits 0, 1 on a difference, 2 when it cannot run.
set -euo pipefail

ENGINE="${1:-}"
shift || true
MODE=check
if [[ "${1:-}" == --count ]]; then
    MODE=count
    shift
fi
HOST="${1:-127.0.0.1}"
PORT="${2:-3306}"
ROOT="${PROBE_APPLE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
PROBES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS="$ROOT/Plugins"
USER_NAME="${PROBE_USER:-root}"
DATABASE="${PROBE_DATABASE:-tablepro_export_twin_drivers}"
[[ "$DATABASE" =~ ^[a-z_][a-z0-9_]*$ ]] || { echo "FAIL: PROBE_DATABASE must be a plain lowercase name" >&2; exit 2; }

C_MODULE=""
case "$ENGINE" in
    sqlite)
        FOLDER=SQLiteDriverPlugin CLASS=SQLitePlugin TYPE_ID=SQLite
        PRODUCTS="CSQLite TableProSQLiteCore TableProSQLQuoting TableProSQLVocabulary TableProWireIO"
        LINK="$ROOT/Libs/libsqlite3_vendored.a"
        command -v sqlite3 > /dev/null || { echo "FAIL: sqlite3 not found" >&2; exit 2; }
        ;;
    duckdb)
        FOLDER=DuckDBDriverPlugin CLASS=DuckDBPlugin TYPE_ID=DuckDB C_MODULE=CDuckDB
        PRODUCTS="TableProDuckDBCore TableProSQLQuoting TableProSQLVocabulary"
        LINK="-Xlinker -force_load -Xlinker $ROOT/Libs/libduckdb.a -lc++"
        command -v duckdb > /dev/null || { echo "FAIL: duckdb not found" >&2; exit 2; }
        ;;
    mariadb)
        FOLDER=MySQLDriverPlugin CLASS=MySQLPlugin TYPE_ID=MariaDB C_MODULE=CMariaDB
        PRODUCTS="TableProCoreTypes TableProGeometry TableProKerberos TableProLogRedaction TableProMySQLCore TableProSQLQuoting TableProSQLVocabulary"
        LINK="$ROOT/Libs/libmariadb.a -lssl.3 -lcrypto.3 -liconv -lz"
        command -v mariadb > /dev/null || { echo "FAIL: mariadb client not found" >&2; exit 2; }
        ;;
    *)
        echo "usage: $0 <sqlite|duckdb|mariadb> [--count] [host] [port]" >&2
        exit 2
        ;;
esac
[[ $MODE == count && $ENGINE != mariadb ]] && { echo "FAIL: --count runs on mariadb" >&2; exit 2; }

COMPOSED=$'caf\xc3\xa9'
DECOMPOSED=$'cafe\xcc\x81'
ACUTE_COMPOSED=$'\xc3\xa9'
ACUTE_DECOMPOSED=$'e\xcc\x81'
hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

WORK="$(mktemp -d)"
CREATED=0
mariadb_run() {
    MYSQL_PWD="${PROBE_PASSWORD:-}" mariadb --no-defaults -h "$HOST" -P "$PORT" -u "$USER_NAME" -N -B "$@"
}
cleanup() {
    if [[ $CREATED -eq 1 ]]; then
        mariadb_run -e "DROP DATABASE IF EXISTS $DATABASE" > /dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# The plugin target's sources: its folder plus the shared files project.yml gives it, and the SQL export.
SOURCES="$WORK/Sources/Probe"
mkdir -p "$SOURCES"
while IFS= read -r source; do
    ln -s "$source" "$SOURCES/driver_$(basename "$source")"
done < <(find "$PLUGINS/$FOLDER" -name '*.swift' -not -path '*/Tests/*')
for source in "$PLUGINS"/SQLExportPlugin/*.swift; do
    ln -s "$source" "$SOURCES/sql_$(basename "$source")"
done
[[ $FOLDER == SQLiteDriverPlugin ]] && for source in "$PLUGINS"/SharedSpill/*.swift; do
    ln -s "$source" "$SOURCES/spill_$(basename "$source")"
done
for shared in PluginConnectTimeout PluginQueryTimeout PluginURLSessionTaskBox PluginRedirectRefusingDelegate \
    PluginNameSpellings PluginExportOutputBuffer PluginExportSpelling PluginHexText; do
    [[ -f "$PLUGINS/Shared/$shared.swift" ]] || continue
    ln -s "$PLUGINS/Shared/$shared.swift" "$SOURCES/shared_$shared.swift"
done
ln -s "$PROBES/export-twin-names-probe.swift" "$SOURCES/probe_Probe.swift"
printf 'typealias EnginePlugin = %s\n' "$CLASS" > "$SOURCES/probe_Engine.swift"

dependencies=""
for product in TableProPluginKit TableProGzip TableProSQLGrammar TableProProcess $PRODUCTS; do
    dependencies="$dependencies .product(name: \"$product\", package: \"TableProCore\"),"
done
system_target=""
swift_flags=""
if [[ -n "$C_MODULE" ]]; then
    ln -s "$PLUGINS/$FOLDER/$C_MODULE" "$WORK/CModule"
    system_target=".systemLibrary(name: \"$C_MODULE\", path: \"CModule\"),"
    dependencies="$dependencies \"$C_MODULE\","
    swift_flags=", .unsafeFlags([\"-Xcc\", \"-I$PLUGINS/$FOLDER/$C_MODULE/include\"])"
fi
flags="\"-L$ROOT/Libs\", \"-L$ROOT/Libs/dylibs\", \"-Xlinker\", \"-rpath\", \"-Xlinker\", \"$ROOT/Libs/dylibs\""
for flag in $LINK; do
    flags="$flags, \"$flag\""
done
cat > "$WORK/Package.swift" <<MANIFEST
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ExportTwinNamesProbe", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "$ROOT/Packages/TableProCore")],
    targets: [
        $system_target
        .executableTarget(name: "Probe", dependencies: [$dependencies], path: "Sources/Probe",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("MemberImportVisibility")$swift_flags],
            linkerSettings: [.unsafeFlags([$flags])])
    ])
MANIFEST
echo "Building the $ENGINE driver and the SQL export from $ROOT..."
if ! (cd "$WORK" && swift build --jobs 2 > "$WORK/build.log" 2>&1); then
    grep -E "error:" "$WORK/build.log" | head -20 >&2
    exit 2
fi
PROBE="$WORK/.build/debug/Probe"

fixture_sql() {
    case "$ENGINE" in
    sqlite) cat <<SQL
CREATE TABLE p1 (id INTEGER PRIMARY KEY);
CREATE TABLE p2 (id INTEGER PRIMARY KEY);
INSERT INTO p1 VALUES (1), (2);
INSERT INTO p2 VALUES (1), (2);
CREATE TABLE "$COMPOSED" (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER GENERATED ALWAYS AS (id * 2) VIRTUAL,
    r INTEGER REFERENCES p1 (id));
CREATE TABLE "$DECOMPOSED" (id INTEGER PRIMARY KEY, a INTEGER GENERATED ALWAYS AS (id * 3) VIRTUAL, b INTEGER,
    s INTEGER REFERENCES p2 (id));
INSERT INTO "$COMPOSED" (id, a, r) VALUES (1, 10, 1), (2, 20, 2);
INSERT INTO "$DECOMPOSED" (id, b, s) VALUES (1, 100, 1), (2, 200, 2);
CREATE TABLE tn (id INTEGER PRIMARY KEY, "$ACUTE_COMPOSED" INTEGER,
    "$ACUTE_DECOMPOSED" INTEGER GENERATED ALWAYS AS (id * 5) VIRTUAL);
INSERT INTO tn (id, "$ACUTE_COMPOSED") VALUES (1, 7), (2, 8);
SQL
    ;;
    duckdb) cat <<SQL
CREATE TABLE p1 (id INTEGER PRIMARY KEY);
CREATE TABLE p2 (id INTEGER PRIMARY KEY);
INSERT INTO p1 VALUES (1), (2);
INSERT INTO p2 VALUES (1), (2);
CREATE TABLE "$COMPOSED" (id INTEGER PRIMARY KEY, a INTEGER, r INTEGER REFERENCES p1 (id));
CREATE TABLE "$DECOMPOSED" (id INTEGER PRIMARY KEY, b INTEGER, s INTEGER REFERENCES p2 (id));
INSERT INTO "$COMPOSED" VALUES (1, 10, 1), (2, 20, 2);
INSERT INTO "$DECOMPOSED" VALUES (1, 100, 1), (2, 200, 2);
CREATE TABLE tn (id INTEGER PRIMARY KEY, "$ACUTE_COMPOSED" INTEGER, "$ACUTE_DECOMPOSED" INTEGER);
INSERT INTO tn VALUES (1, 7, 70), (2, 8, 80);
SQL
    ;;
    mariadb)
        if [[ $MODE == count ]]; then
            for n in $(seq 1 50); do
                printf 'CREATE TABLE t%02d (id INT PRIMARY KEY, v INT%s) ENGINE=InnoDB;\n' "$n" \
                    "$([[ $n -gt 1 ]] && printf ', p INT, FOREIGN KEY (p) REFERENCES t%02d (id)' $((n - 1)))"
                printf 'INSERT INTO t%02d (id, v) VALUES (1, %d), (2, %d);\n' "$n" "$n" $((n * 2))
            done
            return
        fi
        cat <<SQL
CREATE TABLE p1 (id INT PRIMARY KEY) ENGINE=InnoDB;
CREATE TABLE p2 (id INT PRIMARY KEY) ENGINE=InnoDB;
INSERT INTO p1 VALUES (1), (2);
INSERT INTO p2 VALUES (1), (2);
CREATE TABLE \`$COMPOSED\` (id INT PRIMARY KEY, a INT, b INT AS (id * 2) VIRTUAL, r INT,
    CONSTRAINT fk_composed FOREIGN KEY (r) REFERENCES p1 (id)) ENGINE=InnoDB;
CREATE TABLE \`$DECOMPOSED\` (id INT PRIMARY KEY, a INT AS (id * 3) VIRTUAL, b INT, s INT,
    CONSTRAINT fk_decomposed FOREIGN KEY (s) REFERENCES p2 (id)) ENGINE=InnoDB;
INSERT INTO \`$COMPOSED\` (id, a, r) VALUES (1, 10, 1), (2, 20, 2);
INSERT INTO \`$DECOMPOSED\` (id, b, s) VALUES (1, 100, 1), (2, 200, 2);
CREATE TABLE tn (id INT PRIMARY KEY, \`$ACUTE_COMPOSED\` INT, \`$ACUTE_DECOMPOSED\` INT AS (id * 5) VIRTUAL) ENGINE=InnoDB;
INSERT INTO tn (id, \`$ACUTE_COMPOSED\`) VALUES (1, 7), (2, 8);
SQL
    ;;
    esac
}

SOURCE_DB=""
load_fixture() {
    case "$ENGINE" in
    sqlite)
        SOURCE_DB="$WORK/source.sqlite"
        rm -f "$SOURCE_DB"
        fixture_sql | sqlite3 "$SOURCE_DB"
        ;;
    duckdb)
        SOURCE_DB="$WORK/source.duckdb"
        rm -f "$SOURCE_DB"
        fixture_sql | duckdb "$SOURCE_DB" > /dev/null
        ;;
    mariadb)
        mariadb_run -e "DROP DATABASE IF EXISTS $DATABASE; CREATE DATABASE $DATABASE CHARACTER SET utf8mb4"
        fixture_sql | mariadb_run "$DATABASE"
        ;;
    esac
}

# Every row of one table, the generated columns included, in key order.
rows() {
    local where="$1" table="$2"
    case "$ENGINE" in
    sqlite) sqlite3 -batch -noheader "$where" "SELECT * FROM \"$table\" ORDER BY 1" ;;
    duckdb) duckdb -csv -noheader "$where" -c "SELECT * FROM \"$table\" ORDER BY 1" ;;
    mariadb) mariadb_run "$DATABASE" -e "SELECT * FROM \`$table\` ORDER BY 1" ;;
    esac
}

restore() {
    local dump="$1" target="$2"
    case "$ENGINE" in
    sqlite) sqlite3 -bail "$target" < "$dump" ;;
    duckdb) duckdb "$target" < "$dump" > /dev/null ;;
    mariadb) mariadb_run "$DATABASE" < "$dump" ;;
    esac
}

if [[ $ENGINE == mariadb ]]; then
    mariadb_run -e 'SELECT 1' > /dev/null || { echo "FAIL: cannot connect to $HOST:$PORT" >&2; exit 2; }
    echo "MariaDB $(mariadb_run -e 'SELECT VERSION()') at $HOST:$PORT"
    if [[ -n "$(mariadb_run -e "SHOW DATABASES LIKE '$DATABASE'")" ]]; then
        echo "FAIL: database $DATABASE already exists; drop it or set PROBE_DATABASE" >&2
        exit 2
    fi
    CREATED=1
fi
load_fixture
case "$ENGINE" in
    sqlite | duckdb) CONNECT=("" 0 "" "$SOURCE_DB") ;;
    mariadb) CONNECT=("$HOST" "$PORT" "$USER_NAME" "$DATABASE") ;;
esac
SCHEMA=""
[[ $ENGINE == duckdb ]] && SCHEMA=main
[[ $ENGINE == mariadb ]] && SCHEMA="$DATABASE"

if [[ $MODE == count ]]; then
    mariadb_run -e "SET GLOBAL log_output = 'FILE'; SET GLOBAL general_log_file = '$WORK/general.log';
        SET GLOBAL general_log = 1"
    PROBE_PASSWORD="${PROBE_PASSWORD:-}" "$PROBE" "$TYPE_ID" "${CONNECT[@]}" "$SCHEMA" "$WORK" count "all=*" || exit 2
    mariadb_run -e "SET GLOBAL general_log = 0"
    echo "statements the 50-table export sent: $(grep -E $'\tQuery\t' "$WORK/general.log" | grep -vc 'general_log')"
    exit 0
fi

status=0
COMPOSED_RUN="composed=$(hex p1),$(hex p2),$(hex "$COMPOSED"),$(hex tn)"
DECOMPOSED_RUN="decomposed=$(hex p1),$(hex p2),$(hex "$DECOMPOSED"),$(hex tn)"
PROBE_PASSWORD="${PROBE_PASSWORD:-}" "$PROBE" "$TYPE_ID" "${CONNECT[@]}" "$SCHEMA" "$WORK" check \
    "$COMPOSED_RUN" "$DECOMPOSED_RUN" || {
    [[ $? -eq 1 ]] || exit 2
    status=1
}

for run in composed decomposed; do
    twin="$COMPOSED"
    [[ $run == decomposed ]] && twin="$DECOMPOSED"
    tables=(p1 p2 "$twin" tn)
    load_fixture
    for table in "${tables[@]}"; do rows "$SOURCE_DB" "$table" > "$WORK/$run-$(hex "$table").before"; done
    case "$ENGINE" in
    sqlite | duckdb)
        target="$WORK/restored-$run.$ENGINE"
        rm -f "$target"
        ;;
    mariadb)
        target="$DATABASE"
        mariadb_run "$DATABASE" -e "SET FOREIGN_KEY_CHECKS = 0; DROP TABLE p1, p2, \`$twin\`, tn"
        ;;
    esac
    if ! restore "$WORK/$run.sql" "$target" > "$WORK/$run.restore.log" 2>&1; then
        echo "BUG: the $run dump does not restore"
        tail -3 "$WORK/$run.restore.log" || true
        status=1
        continue
    fi
    restored=1
    for table in "${tables[@]}"; do
        rows "$target" "$table" > "$WORK/$run-$(hex "$table").after"
        if ! diff "$WORK/$run-$(hex "$table").before" "$WORK/$run-$(hex "$table").after" > /dev/null; then
            echo "BUG: the $run dump restores table $(hex "$table") with other rows"
            diff "$WORK/$run-$(hex "$table").before" "$WORK/$run-$(hex "$table").after" | head -6 || true
            restored=0
            status=1
        fi
    done
    [[ $restored -eq 1 ]] && echo "the $run dump restores every row of its four tables"
done

[[ $status -eq 0 ]] && echo "OK"
exit $status
