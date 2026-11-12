#!/usr/bin/env bash
#
# Check that the Parquet export writes the values it was given.
#
# The plugin links libduckdb.a, so no test bundle can hold its staging database. This compiles
# DuckDBStagingDatabase.swift against the shipped library, stages a table holding the values the
# export used to change (binary, a zero-length blob, bit(8), BIGINT UNSIGNED above 2^63, a TIME
# past 24 hours, an Oracle DATE with a time, text in an integer column, timestamps and a time
# with a UTC offset), writes the file and reads it back.
#
# Usage:
#   scripts/probes/check-parquet-export-values.sh
#
# Needs Libs/libduckdb.a (scripts/download-libs.sh) and a Debug build of TableProPluginKit in
# DerivedData (run verify.sh build first). Exits non-zero on a wrong value, 3 when a prerequisite
# is missing. Run it after touching the plugin's staging or type mapping, or bumping libduckdb.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PLUGIN="$ROOT/Plugins/ParquetExportPlugin"
CDUCKDB="$ROOT/Plugins/DuckDBDriverPlugin/CDuckDB"
LIB="$ROOT/Libs/libduckdb.a"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$LIB" ] || {
    echo "$LIB is missing; run scripts/download-libs.sh" >&2
    exit 3
}

if [ -z "${DEVELOPER_DIR:-}" ]; then
    DEVELOPER_DIR="$(xcode-select -p)"
    case "$DEVELOPER_DIR" in
        *CommandLineTools*) DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ;;
    esac
fi
export DEVELOPER_DIR

FRAMEWORK_DIR=""
for info in "$HOME"/Library/Developer/Xcode/DerivedData/TablePro-*/info.plist; do
    [ -f "$info" ] || continue
    workspace="$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$info" 2> /dev/null)"
    products="$(dirname "$info")/Build/Products/Debug"
    if [ "$workspace" = "$ROOT/TablePro.xcodeproj" ] && [ -d "$products/TableProPluginKit.framework" ]; then
        FRAMEWORK_DIR="$products"
    fi
done
if [ -z "$FRAMEWORK_DIR" ]; then
    FRAMEWORK_DIR="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type d -path '*/Build/Products/Debug/TableProPluginKit.framework' -print 2> /dev/null \
        | while read -r path; do echo "$(stat -f %m "$path") $(dirname "$path")"; done \
        | sort -rn | head -1 | cut -d' ' -f2-)"
fi
[ -n "$FRAMEWORK_DIR" ] || {
    echo "no Debug TableProPluginKit.framework in DerivedData; build the app first" >&2
    exit 3
}

cat > "$WORK/main.swift" << 'SWIFT'
import CDuckDB
import Foundation
import TableProPluginKit

@main
enum ParquetValuesProbe {
    static func main() throws {
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        let declared: [(name: String, type: String, engine: String)] = [
            ("id", "bigint", "PostgreSQL"),
            ("payload", "bytea", "PostgreSQL"),
            ("flags", "bit(8)", "PostgreSQL"),
            ("big", "bigint unsigned", "MySQL"),
            ("elapsed", "time", "MySQL"),
            ("seen", "DATE", "Oracle"),
            ("count", "int", "SQLite"),
            ("day", "date", "PostgreSQL"),
            ("note", "text", "PostgreSQL"),
            ("zoned", "timestamp with time zone", "PostgreSQL"),
            ("instant", "timestamptz", "PostgreSQL"),
            ("clock", "time with time zone", "PostgreSQL"),
            ("oracle_tz", "TIMESTAMP(6) WITH TIME ZONE", "Oracle"),
            ("oracle_ltz", "TIMESTAMP(6) WITH LOCAL TIME ZONE", "Oracle")
        ]
        let types = declared.map { ParquetTypeMapper.duckDBType(forColumnType: $0.type, databaseTypeId: $0.engine) }

        let staging = try DuckDBStagingDatabase()
        try staging.createTable(columns: declared.map(\.name), types: types)
        try staging.insert(rows: [
            [
                .text("1"), .bytes(Data([0x41, 0x42, 0x43])), .text("10101010"), .text("18446744073709551615"),
                .text("100:00:00"), .text("2024-01-01 12:30:00"), .text("7"), .text("2024-03-01"), .text("it's"),
                .text("2024-01-01 12:00:00+07"), .text("2024-10-27 02:30:00+02"), .text("12:00:00+07"),
                .text("2026-10-06 15:22:20.000001-05:30"), .text("2026-10-06 15:22:20.000001+07:00")
            ],
            [
                .text("2"), .bytes(Data()), .text("1"), .text("5"),
                .text("10:00:00"), .text("2024-01-02 00:00:00"), .text("seven"), .text("2024-03-02"), .text(""),
                .null, .text("2024-10-27 02:30:00+01"), .null, .null, .null
            ]
        ])
        try staging.insert(rows: [
            [
                .text("3"), .bytes(Data([0x00, 0xFF, 0x5C, 0x78])), .null, .null, .null, .null, .null, .null, .null,
                .null, .null, .null, .null, .null
            ]
        ])
        let fallbacks = try staging.copyToParquet(fileURL: file, compression: "SNAPPY", rowGroupSize: 122_880)

        var failures = 0
        func expect(_ label: String, _ actual: String, _ expected: String) {
            guard actual != expected else { return }
            print("FAIL \(label): got \(actual), expected \(expected)")
            failures += 1
        }

        let mapped: [(type: String, engine: String, expected: String)] = [
            ("bit", "PostgreSQL", "BOOLEAN"), ("bit(1)", "MySQL", "BOOLEAN"), ("bit", "SQL Server", "BOOLEAN"),
            ("bit(8)", "MySQL", "VARCHAR"), ("bit varying(8)", "PostgreSQL", "VARCHAR"),
            ("int unsigned", "MySQL", "BIGINT"), ("BIGINT(20) UNSIGNED", "MySQL", "UBIGINT"),
            ("bigint", "MySQL", "BIGINT"), ("date", "MySQL", "DATE"), ("DATE", "Oracle", "TIMESTAMP"),
            ("timestamp with time zone", "PostgreSQL", "TIMESTAMPTZ"), ("timestamptz", "PostgreSQL", "TIMESTAMPTZ"),
            ("timestamp(3) with time zone", "PostgreSQL", "TIMESTAMPTZ"),
            ("TIMESTAMP(6) WITH TIME ZONE", "Oracle", "TIMESTAMPTZ"), ("TIMESTAMP WITH TIME ZONE", "DuckDB", "TIMESTAMPTZ"),
            ("time with time zone", "PostgreSQL", "TIMETZ"), ("timetz", "PostgreSQL", "TIMETZ"),
            ("timestamp", "PostgreSQL", "TIMESTAMP"), ("timestamp without time zone", "PostgreSQL", "TIMESTAMP"),
            ("time", "PostgreSQL", "TIME"), ("TIMESTAMP(6) WITH LOCAL TIME ZONE", "Oracle", "TIMESTAMPTZ"),
            ("timestamp", "MySQL", "TIMESTAMP"), ("datetimeoffset", "SQL Server", "VARCHAR")
        ]
        for entry in mapped {
            expect(
                "\(entry.engine) \(entry.type)",
                ParquetTypeMapper.duckDBType(forColumnType: entry.type, databaseTypeId: entry.engine),
                entry.expected)
        }
        expect("bytes in a text column", ParquetStaging.text(forBytes: Data([0x41, 0x00, 0x5C, 0xC3])), "A\\x00\\x5C\\xC3")

        expect(
            "columns written as text",
            fallbacks.map { "\($0.column):\($0.type):\($0.valueCount)" }.joined(separator: " "),
            "elapsed:TIME:1 count:BIGINT:1")

        let reader = try Reader()
        let source = "read_parquet('\(file.path)')"
        let typeIds = try reader.columnTypes("SELECT * FROM \(source)")
        let expectedTypes: [duckdb_type] = [
            DUCKDB_TYPE_BIGINT, DUCKDB_TYPE_BLOB, DUCKDB_TYPE_VARCHAR, DUCKDB_TYPE_UBIGINT, DUCKDB_TYPE_VARCHAR,
            DUCKDB_TYPE_TIMESTAMP, DUCKDB_TYPE_VARCHAR, DUCKDB_TYPE_DATE, DUCKDB_TYPE_VARCHAR,
            DUCKDB_TYPE_TIMESTAMP_TZ, DUCKDB_TYPE_TIMESTAMP_TZ, DUCKDB_TYPE_TIME_TZ, DUCKDB_TYPE_TIMESTAMP_TZ,
            DUCKDB_TYPE_TIMESTAMP_TZ
        ]
        for (index, column) in declared.enumerated() {
            expect("type of \(column.name)", "\(typeIds[index].rawValue)", "\(expectedTypes[index].rawValue)")
        }

        func cell(_ expression: String, id: Int) throws -> String {
            try reader.scalar("SELECT CAST(\(expression) AS VARCHAR) FROM \(source) WHERE id = \(id)")
        }
        expect("row count", try reader.scalar("SELECT CAST(count(*) AS VARCHAR) FROM \(source)"), "3")
        expect("binary value", try cell("payload = '\\x41\\x42\\x43'::BLOB", id: 1), "true")
        expect("zero-length blob", try cell("payload = ''::BLOB", id: 2), "true")
        expect("binary with a NUL and a backslash", try cell("payload = '\\x00\\xFF\\x5C\\x78'::BLOB", id: 3), "true")
        expect("bit(8)", try cell("flags", id: 1), "10101010")
        expect("unsigned bigint", try cell("big", id: 1), "18446744073709551615")
        expect("time past 24 hours", try cell("elapsed", id: 1), "100:00:00")
        expect("Oracle date with a time", try cell("seen", id: 1), "2024-01-01 12:30:00")
        expect("text in an integer column", try cell("count", id: 2), "seven")
        expect("number beside it", try cell("count", id: 1), "7")
        expect("date", try cell("day", id: 2), "2024-03-02")
        expect("quoted text", try cell("note", id: 1), "it's")
        expect("empty text", try cell("note = ''", id: 2), "true")
        expect("null", try cell("note IS NULL AND big IS NULL AND seen IS NULL", id: 3), "true")
        expect("timestamp with time zone in UTC", try cell("timezone('UTC', zoned)", id: 1), "2024-01-01 05:00:00")
        expect("first 02:30 of the fall-back hour", try cell("timezone('UTC', instant)", id: 1), "2024-10-27 00:30:00")
        expect("second 02:30 of the fall-back hour", try cell("timezone('UTC', instant)", id: 2), "2024-10-27 01:30:00")
        expect("time with time zone in UTC", try cell("clock", id: 1), "05:00:00+00")
        expect("Oracle timestamp with time zone", try cell("timezone('UTC', oracle_tz)", id: 1), "2026-10-06 20:52:20.000001")
        expect("Oracle timestamp with local time zone", try cell("timezone('UTC', oracle_ltz)", id: 1), "2026-10-06 08:22:20.000001")

        if failures > 0 { exit(1) }
        print("PASS: the Parquet file holds every staged value")
    }
}

final class Reader {
    private var database: duckdb_database?
    private var connection: duckdb_connection?

    init() throws {
        guard duckdb_open(nil, &database) == DuckDBSuccess,
              duckdb_connect(database, &connection) == DuckDBSuccess else {
            throw ProbeError.failed("could not open the reader")
        }
    }

    deinit {
        duckdb_disconnect(&connection)
        duckdb_close(&database)
    }

    func scalar(_ sql: String) throws -> String {
        var result = duckdb_result()
        defer { duckdb_destroy_result(&result) }
        guard duckdb_query(connection, sql, &result) == DuckDBSuccess else {
            throw ProbeError.failed(duckdb_result_error(&result).map { String(cString: $0) } ?? sql)
        }
        guard duckdb_row_count(&result) == 1, let value = duckdb_value_varchar(&result, 0, 0) else {
            return "<no single value>"
        }
        defer { duckdb_free(value) }
        return String(cString: value)
    }

    func columnTypes(_ sql: String) throws -> [duckdb_type] {
        var result = duckdb_result()
        defer { duckdb_destroy_result(&result) }
        guard duckdb_query(connection, sql, &result) == DuckDBSuccess else {
            throw ProbeError.failed(duckdb_result_error(&result).map { String(cString: $0) } ?? sql)
        }
        return (0 ..< duckdb_column_count(&result)).map { duckdb_column_type(&result, $0) }
    }
}

enum ProbeError: Error {
    case failed(String)
}
SWIFT

xcrun swiftc -swift-version 6 -parse-as-library -module-name TableProSQLQuoting -Onone \
    -emit-module -emit-module-path "$WORK/TableProSQLQuoting.swiftmodule" -emit-library -static \
    -o "$WORK/libTableProSQLQuoting.a" "$ROOT/Packages/TableProCore/Sources/TableProSQLQuoting"/*.swift \
    > "$WORK/quoting.log" 2>&1 || {
    echo "TableProSQLQuoting failed to compile:" >&2
    grep -E 'error:' "$WORK/quoting.log" | sort -u | head -20 >&2
    exit 3
}

xcrun swiftc -swift-version 6 -parse-as-library -module-name ParquetValuesProbe -Onone \
    -I "$WORK" -Xlinker "$WORK/libTableProSQLQuoting.a" \
    -F "$FRAMEWORK_DIR" -framework TableProPluginKit -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR" \
    -I "$CDUCKDB" -Xcc -I"$CDUCKDB/include" \
    -Xlinker -force_load -Xlinker "$LIB" -lc++ \
    "$PLUGIN/DuckDBStagingDatabase.swift" "$PLUGIN/ParquetStaging.swift" "$PLUGIN/ParquetTypeMapper.swift" \
    "$WORK/main.swift" -o "$WORK/parquet-values" > "$WORK/compile.log" 2>&1 || {
    echo "harness failed to compile:" >&2
    grep -E 'error:' "$WORK/compile.log" | sort -u | head -20 >&2
    exit 3
}

echo "Checking the Parquet export against $(basename "$LIB")"
"$WORK/parquet-values" "$WORK/probe.parquet"
