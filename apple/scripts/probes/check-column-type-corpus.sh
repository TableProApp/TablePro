#!/usr/bin/env bash
#
# Take every column type an engine's driver lists through browse, edit and export against a real server.
#
# A type a driver has never seen can crash it or show the wrong value (#3241, #2454, #2130). This builds a harness
# from the driver's own sources, the CSV, JSON and SQL export plugins and the runner in Plugins/ColumnTypeCorpus, then
# runs Plugins/ColumnTypeCorpus/Corpus/<engine>.json: per column it creates a table, inserts the values, reads them
# through the table tab's query and the export's stream, saves one edit through the grid's statements, reads it
# back, and exports the table three ways. The SQL dump is replayed into the emptied table and has to read back the
# same. A listed type with no corpus column fails too.
#
# A corpus column is {"type", "covers", "values": [{"sql", "cell"}], "edit": {"text" | "hex", "cell"}, "skip",
# "known"}. "cell" is the text the driver hands the grid for the value, null for NULL, 0x-hex for bytes. "covers"
# names the listed types the column stands for, by default the type up to its "(". "skip" names a step that does not
# apply to the type and why; "known" names a step that fails today and the defect, and fails the run once it passes.
#
# Usage:
#   scripts/probes/check-column-type-corpus.sh <engine> [--only <type>] [--keep]
#
#   engine: postgresql, mysql, mariadb, clickhouse, duckdb, mssql, oracle, sqlite
#   --only  run the columns whose declared type contains <type>
#   --keep  leave the tables behind for a look
#
# With no server listening on the engine's port, the script starts one in Docker as tablepro-corpus-<engine> and
# leaves it running for the next run. TP_CORPUS_HOST, TP_CORPUS_PORT, TP_CORPUS_USER, TP_CORPUS_PASSWORD and
# TP_CORPUS_DATABASE point it at another server instead. TP_CORPUS_BUILD_DIR keeps the harness between runs.
# Exits 1 when a check fails, 3 when it cannot run.

set -uo pipefail

ENGINE="${1:-}"
shift || true
ONLY=""
KEEP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --only)
            [ $# -ge 2 ] || { echo "--only needs a type" >&2; exit 3; }
            ONLY="$2"
            shift 2
            ;;
        --keep) KEEP=1; shift ;;
        *) echo "unknown argument $1" >&2; exit 3 ;;
    esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGINS="$ROOT/Plugins"
CORPUS="$PLUGINS/ColumnTypeCorpus/Corpus/$ENGINE.json"
PASSWORD_DEFAULT="TpCorpus#2026"

# Per engine: plugin folder, principal class, C module, TableProCore products, link flags, image, port, user,
# database, and the command that answers once the server takes connections.
C_MODULE=""
PRODUCTS="TableProLogRedaction"
LINK=""
IMAGE=""
PORT_IN=""
USER_DEFAULT=""
DATABASE_DEFAULT=""
FIELDS=""
DOCKER_ENV=()
READY=()
case "$ENGINE" in
    postgresql)
        FOLDER=PostgreSQLDriverPlugin CLASS=PostgreSQLPlugin C_MODULE=CLibPQ
        PRODUCTS="TableProCoreTypes TableProKerberos TableProLogRedaction TableProPostgreSQLCore TableProSQLVocabulary"
        LINK="$ROOT/Libs/libpq.a $ROOT/Libs/libpgcommon.a $ROOT/Libs/libpgport.a -lssl.3 -lcrypto.3 -lz -framework GSS -lcom_err"
        IMAGE=postgres:17-alpine PORT_IN=5432 PORT=15467 USER_DEFAULT=postgres DATABASE_DEFAULT=postgres
        DOCKER_ENV=(-e "POSTGRES_PASSWORD=$PASSWORD_DEFAULT")
        READY=(pg_isready -h 127.0.0.1 -U postgres)
        ;;
    mysql | mariadb)
        FOLDER=MySQLDriverPlugin CLASS=MySQLPlugin C_MODULE=CMariaDB
        PRODUCTS="TableProGeometry TableProLogRedaction TableProMySQLCore"
        LINK="$ROOT/Libs/libmariadb.a -lssl.3 -lcrypto.3 -liconv -lz"
        USER_DEFAULT=root DATABASE_DEFAULT=tp_corpus PORT_IN=3306
        if [ "$ENGINE" = mysql ]; then
            IMAGE=mysql:8.4 PORT=13367
            DOCKER_ENV=(-e "MYSQL_ROOT_PASSWORD=$PASSWORD_DEFAULT" -e MYSQL_DATABASE=tp_corpus)
            READY=(mysqladmin ping -h 127.0.0.1 -uroot "-p$PASSWORD_DEFAULT" --silent)
        else
            IMAGE=mariadb:11.8 PORT=13368
            DOCKER_ENV=(-e "MARIADB_ROOT_PASSWORD=$PASSWORD_DEFAULT" -e MARIADB_DATABASE=tp_corpus)
            READY=(mariadb-admin ping -h 127.0.0.1 -uroot "-p$PASSWORD_DEFAULT" --silent)
        fi
        ;;
    clickhouse)
        FOLDER=ClickHouseDriverPlugin CLASS=ClickHousePlugin
        PRODUCTS="TableProNumberFormatting TableProTLSClientIdentity"
        IMAGE=clickhouse/clickhouse-server:25.8 PORT_IN=8123 PORT=18123 USER_DEFAULT=default DATABASE_DEFAULT=tp_corpus
        DOCKER_ENV=(-e "CLICKHOUSE_PASSWORD=$PASSWORD_DEFAULT" -e CLICKHOUSE_DB=tp_corpus)
        READY=(clickhouse-client --password "$PASSWORD_DEFAULT" --query "SELECT 1")
        ;;
    duckdb)
        FOLDER=DuckDBDriverPlugin CLASS=DuckDBPlugin C_MODULE=CDuckDB PRODUCTS=""
        LINK="$ROOT/Libs/libduckdb.a -lc++"
        ;;
    mssql)
        FOLDER=MSSQLDriverPlugin CLASS=MSSQLPlugin C_MODULE=CFreeTDS
        PRODUCTS="TableProCoreTypes TableProLogRedaction TableProMSSQLCore"
        LINK="$ROOT/Libs/libsybdb.a -lssl.3 -lcrypto.3 -liconv -framework GSS -lcom_err"
        # SQL Server proper rather than Azure SQL Edge, which has no CLR types (geometry, geography, hierarchyid).
        IMAGE=mcr.microsoft.com/mssql/server:2022-latest PORT_IN=1433 PORT=14367 USER_DEFAULT=sa DATABASE_DEFAULT=tp_corpus
        DOCKER_ENV=(--platform linux/amd64 -e ACCEPT_EULA=Y -e "MSSQL_SA_PASSWORD=$PASSWORD_DEFAULT")
        READY=(/opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P "$PASSWORD_DEFAULT"
            -Q "IF DB_ID('tp_corpus') IS NULL CREATE DATABASE tp_corpus")
        ;;
    oracle)
        FOLDER=OracleDriverPlugin CLASS=OraclePlugin
        # Not a slim image: those leave out Spatial, so SDO_GEOMETRY does not exist.
        IMAGE=gvenzl/oracle-free:23-faststart PORT_IN=1521 PORT=15421 USER_DEFAULT=probe DATABASE_DEFAULT=FREEPDB1
        DOCKER_ENV=(-e "ORACLE_PASSWORD=$PASSWORD_DEFAULT" -e APP_USER=probe -e "APP_USER_PASSWORD=$PASSWORD_DEFAULT")
        READY=(healthcheck.sh)
        FIELDS="oracleServiceName=FREEPDB1"
        ;;
    sqlite)
        FOLDER=SQLiteDriverPlugin CLASS=SQLitePlugin PRODUCTS="CSQLite TableProSQLiteCore"
        LINK="$ROOT/Libs/libsqlite3_vendored.a"
        ;;
    *)
        echo "usage: $0 <postgresql|mysql|mariadb|clickhouse|duckdb|mssql|oracle|sqlite> [--only <type>] [--keep]" >&2
        exit 3
        ;;
esac

[ -f "$CORPUS" ] || { echo "no corpus at $CORPUS" >&2; exit 3; }
command -v swift > /dev/null || { echo "swift not found" >&2; exit 3; }
for library in $LINK; do
    case "$library" in
        /*) [ -f "$library" ] || { echo "not found: $library (run scripts/download-libs.sh)" >&2; exit 3; } ;;
    esac
done

HOST="${TP_CORPUS_HOST:-127.0.0.1}"
PORT="${TP_CORPUS_PORT:-${PORT:-0}}"
USER_NAME="${TP_CORPUS_USER:-$USER_DEFAULT}"
PASSWORD="${TP_CORPUS_PASSWORD:-$PASSWORD_DEFAULT}"
DATABASE="${TP_CORPUS_DATABASE:-$DATABASE_DEFAULT}"
CONTAINER="tablepro-corpus-$ENGINE"

if [ -n "$IMAGE" ] && ! nc -z "$HOST" "$PORT" > /dev/null 2>&1; then
    command -v docker > /dev/null || { echo "no server at $HOST:$PORT and no docker to start one" >&2; exit 3; }
    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
        echo "starting container $CONTAINER"
        docker start "$CONTAINER" > /dev/null || exit 3
    else
        echo "starting $IMAGE as $CONTAINER on $HOST:$PORT"
        docker run -d --name "$CONTAINER" ${DOCKER_ENV[@]+"${DOCKER_ENV[@]}"} -p "$HOST:$PORT:$PORT_IN" "$IMAGE" \
            > /dev/null || exit 3
    fi
fi
if [ ${#READY[@]} -gt 0 ] && docker ps --format '{{.Names}}' 2> /dev/null | grep -qx "$CONTAINER"; then
    for _ in $(seq 1 120); do
        docker exec "$CONTAINER" "${READY[@]}" > /dev/null 2>&1 && break
        sleep 2
    done
fi

WORK="${TP_CORPUS_BUILD_DIR:-}"
if [ -z "$WORK" ]; then
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
fi
SOURCES="$WORK/Sources/Probe"
rm -rf "$SOURCES" "$WORK/CModule"
mkdir -p "$SOURCES"

link_sources() {
    local prefix="$1" directory="$2" source
    while IFS= read -r source; do
        ln -s "$source" "$SOURCES/${prefix}_$(basename "$source")"
    done < <(find "$directory" -name '*.swift' -not -path '*/Tests/*')
}
link_sources driver "$PLUGINS/$FOLDER"
link_sources corpus "$PLUGINS/ColumnTypeCorpus"
link_sources csv "$PLUGINS/CSVExportPlugin"
link_sources json "$PLUGINS/JSONExportPlugin"
link_sources sql "$PLUGINS/SQLExportPlugin"
for shared in PluginConnectTimeout PluginQueryTimeout PluginURLSessionTaskBox; do
    ln -s "$PLUGINS/Shared/$shared.swift" "$SOURCES/shared_$shared.swift"
done

dependencies='.product(name: "TableProPluginKit", package: "TableProCore"),
                .product(name: "TableProSQLGrammar", package: "TableProCore"),'
for product in $PRODUCTS; do
    dependencies="$dependencies
                .product(name: \"$product\", package: \"TableProCore\"),"
done
packages=".package(path: \"$ROOT/Packages/TableProCore\"),"
if [ "$ENGINE" = oracle ]; then
    packages="$packages
        .package(path: \"$ROOT/Packages/TableProOracle\"),"
    dependencies="$dependencies
                .product(name: \"TableProOracleCore\", package: \"TableProOracle\"),"
fi
system_target=""
swift_flags=""
if [ -n "$C_MODULE" ]; then
    swift_flags=", .unsafeFlags([\"-Xcc\", \"-I$PLUGINS/$FOLDER/$C_MODULE/include\"])"
    ln -s "$PLUGINS/$FOLDER/$C_MODULE" "$WORK/CModule"
    system_target=".systemLibrary(name: \"$C_MODULE\", path: \"CModule\"),"
    dependencies="$dependencies
                \"$C_MODULE\","
fi
flags="\"-L$ROOT/Libs\", \"-L$ROOT/Libs/dylibs\", \"-Xlinker\", \"-rpath\", \"-Xlinker\", \"$ROOT/Libs/dylibs\""
for flag in $LINK; do
    flags="$flags, \"$flag\""
done

cat > "$WORK/Package.swift" << MANIFEST
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ColumnTypeCorpusProbe",
    platforms: [.macOS(.v14)],
    dependencies: [
        $packages
    ],
    targets: [
        $system_target
        .executableTarget(
            name: "Probe",
            dependencies: [
                $dependencies
            ],
            path: "Sources/Probe",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("MemberImportVisibility")$swift_flags],
            linkerSettings: [.unsafeFlags([$flags])]
        ),
    ]
)
MANIFEST

cat > "$SOURCES/probe_Engine.swift" << SWIFT
typealias EnginePlugin = $CLASS
SWIFT

cat > "$SOURCES/probe_Probe.swift" << 'SWIFT'
import Foundation
import TableProPluginKit

@main
enum Probe {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 10 else {
            print("usage: Probe <corpus> <host> <port> <user> <password> <database> <fields> <only> <keep>")
            exit(3)
        }
        let corpus: ColumnTypeCorpus
        do {
            corpus = try ColumnTypeCorpus.load(URL(fileURLWithPath: arguments[1]))
        } catch {
            print("cannot read the corpus: \(error)")
            exit(3)
        }
        var fields: [String: String] = [:]
        for pair in arguments[7].split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        if let variant = EnginePlugin.driverVariant(for: corpus.databaseTypeId) {
            fields["driverVariant"] = variant
        }
        let driver = EnginePlugin().createDriver(config: DriverConnectionConfig(
            host: arguments[2], port: Int(arguments[3]) ?? 0, username: arguments[4], password: arguments[5],
            database: arguments[6], additionalFields: fields
        ))
        do {
            try await driver.connect()
        } catch {
            print("cannot connect: \(error)")
            exit(3)
        }
        print("\(corpus.engine): \(driver.serverVersion ?? "server version unknown")")

        let csv = CSVExportPlugin()
        let json = JSONExportPlugin()
        let sql = SQLExportPlugin()
        let exports = [
            ColumnTypeCorpusExport(formatId: "csv", optionValues: []) { tables, source, destination in
                _ = try await csv.export(tables: tables, dataSource: source, destination: destination, progress: PluginExportProgress(progress: Progress(totalUnitCount: 1)))
            },
            ColumnTypeCorpusExport(formatId: "json", optionValues: []) { tables, source, destination in
                _ = try await json.export(tables: tables, dataSource: source, destination: destination, progress: PluginExportProgress(progress: Progress(totalUnitCount: 1)))
            },
            ColumnTypeCorpusExport(formatId: "sql", optionValues: [false, false, true]) { tables, source, destination in
                _ = try await sql.export(tables: tables, dataSource: source, destination: destination, progress: PluginExportProgress(progress: Progress(totalUnitCount: 1)))
            },
        ]
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("tp-corpus-\(getpid())")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let only = arguments[8]
        var runner = ColumnTypeCorpusRunner(
            corpus: corpus,
            driver: driver,
            listedTypes: EnginePlugin.columnTypesByCategory,
            dialect: EnginePlugin.sqlDialect,
            supportsCascadeDrop: EnginePlugin.supportsCascadeDrop,
            exports: exports,
            workDirectory: work
        )
        runner.tablePrefix = "tpc\(getpid() % 10_000)_"
        runner.keepTables = arguments[9] == "1"
        if !only.isEmpty {
            runner.includes = { $0.type.localizedCaseInsensitiveContains(only) }
        }
        let report = await runner.run { line in
            print(line)
            fflush(stdout)
        }
        driver.disconnect()
        let failures = report.failures
        print(failures.isEmpty ? "\nall checks hold" : "\n\(failures.count) failing check(s)")
        exit(failures.isEmpty ? 0 : 1)
    }
}
SWIFT

# A database file the caller names only gets the runner's tables; a scratch one is made fresh, and outlives the run
# when --keep asks for the tables.
case "$ENGINE" in
    duckdb | sqlite)
        if [ -z "${TP_CORPUS_DATABASE:-}" ]; then
            if [ -n "$KEEP" ]; then
                DATABASE="$(mktemp -d)/corpus.$ENGINE"
                echo "keeping the tables in $DATABASE"
            else
                DATABASE="$WORK/corpus.$ENGINE"
                rm -f "$DATABASE" "$DATABASE.wal"
            fi
        fi
        ;;
esac

echo "building the $ENGINE harness (the first build takes a few minutes)"
(cd "$WORK" && swift build -c debug > "$WORK/build.log" 2>&1) || {
    grep -E "error:" "$WORK/build.log" | head -30 >&2
    exit 3
}
# A session takes the client's zone for TIMESTAMP WITH LOCAL TIME ZONE and the like, so the cells read the same on
# every Mac.
TZ=UTC "$WORK/.build/debug/Probe" "$CORPUS" "$HOST" "$PORT" "$USER_NAME" "$PASSWORD" "$DATABASE" "$FIELDS" "$ONLY" "$KEEP"
