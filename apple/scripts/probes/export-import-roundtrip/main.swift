// Round trip of every export format through the plugins a built TablePro.app ships, against a live
// MySQL or PostgreSQL server. Driven by scripts/probes/check-export-import-roundtrip.sh.

import Foundation
import TableProPluginKit

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

struct Settings {
    var plugins: URL
    var engine: String
    var host: String
    var port: Int
    var user: String
    var password: String
    var database: String
    var restoreDatabase: String
    var rows: Int
    var work: URL
    var formats: [String]
    var client: [String]

    static func parse() throws -> Settings {
        var values: [String: String] = [:]
        var client: [String] = []
        var arguments = CommandLine.arguments.dropFirst()
        while let key = arguments.popFirst() {
            if key == "--" {
                client = Array(arguments)
                break
            }
            guard key.hasPrefix("--"), let value = arguments.popFirst() else {
                throw ProbeFailure(description: "bad argument \(key)")
            }
            values[String(key.dropFirst(2))] = value
        }
        func required(_ key: String) throws -> String {
            guard let value = values[key] else { throw ProbeFailure(description: "missing --\(key)") }
            return value
        }
        return Settings(
            plugins: URL(fileURLWithPath: try required("plugins")),
            engine: try required("engine"),
            host: try required("host"),
            port: Int(try required("port")) ?? 0,
            user: try required("user"),
            password: ProcessInfo.processInfo.environment["PROBE_PASSWORD"] ?? "",
            database: try required("database"),
            restoreDatabase: try required("restore-database"),
            rows: Int(try required("rows")) ?? 0,
            work: URL(fileURLWithPath: try required("work")),
            formats: try required("formats").split(separator: ",").map(String.init),
            client: client
        )
    }
}

// The SQL each engine needs around the plugins: the source table, an empty copy of it, and a
// checksum computed by the server over its own stored values.
struct Engine {
    let typeId: String
    let bundle: String
    let schema: (Settings) -> String?
    let createSource: (Int) -> [String]
    let createTarget: (String) -> String
    let prepareSession: [String]
    let checksum: (String, Bool) -> String

    static let sharedColumns = ["id", "whole", "fraction", "amount", "flag", "label", "created"]

    static let postgresql = Engine(
        typeId: "PostgreSQL",
        bundle: "PostgreSQLDriver",
        schema: { _ in "public" },
        createSource: { rows in
            [
                "DROP TABLE IF EXISTS rt_source",
                """
                CREATE TABLE rt_source (id bigint PRIMARY KEY, whole bigint, fraction double precision,
                  amount numeric(20,6), flag boolean, label text, created timestamp, payload bytea)
                """,
                """
                INSERT INTO rt_source
                SELECT g, (g * 7919 % 2000001) - 1000000,
                  (g::float8 / 7) * CASE WHEN g % 2 = 0 THEN 1 ELSE -1 END,
                  round((g * 1.000001 - 50000)::numeric, 6), g % 3 = 0,
                  CASE WHEN g % 5 = 0 THEN NULL ELSE 'row ' || g || ' "double", ''single''; =1+1' || chr(10)
                    || 'line ' || chr(13) || chr(10) || 'é 日本 😀 ' || repeat('x', 400 + g % 200) END,
                  timestamp '2020-01-01' + g * interval '1 second',
                  decode(md5(g::text) || md5((g + 1)::text), 'hex')
                FROM generate_series(1, \(rows)) g
                """,
            ]
        },
        createTarget: { name in
            """
            CREATE TABLE \(name) (id bigint PRIMARY KEY, whole bigint, fraction double precision,
              amount numeric(20,6), flag boolean, label text, created timestamp)
            """
        },
        prepareSession: ["SET client_min_messages = warning"],
        checksum: { table, withPayload in
            let columns = sharedColumns + (withPayload ? ["payload"] : [])
            return """
                SELECT count(*), coalesce(md5(string_agg(md5(row(\(columns.joined(separator: ", ")))::text), '' ORDER BY id)), '')
                FROM \(table)
                """
        }
    )

    static let mysql = Engine(
        typeId: "MySQL",
        bundle: "MySQLDriver",
        schema: { $0.database },
        createSource: { rows in
            [
                "DROP TABLE IF EXISTS rt_source",
                """
                CREATE TABLE rt_source (id BIGINT PRIMARY KEY, whole BIGINT, fraction DOUBLE,
                  amount DECIMAL(20,6), flag TINYINT(1), label TEXT, created DATETIME, payload BLOB)
                  CHARACTER SET utf8mb4
                """,
                """
                INSERT INTO rt_source
                SELECT g, (g * 7919 % 2000001) - 1000000,
                  (g / 7) * IF(g % 2 = 0, 1, -1),
                  ROUND(g * 1.000001 - 50000, 6), g % 3 = 0,
                  IF(g % 5 = 0, NULL, CONCAT('row ', g, ' "double", ''single''; =1+1', CHAR(10),
                    'line ', CHAR(13), CHAR(10), 'é 日本 😀 ', REPEAT('x', 400 + g % 200))),
                  TIMESTAMPADD(SECOND, g, '2020-01-01 00:00:00'),
                  UNHEX(CONCAT(MD5(g), MD5(g + 1)))
                FROM (
                  SELECT a.d + 10 * b.d + 100 * c.d + 1000 * d.d + 10000 * e.d + 100000 * f.d + 1 AS g
                  FROM \(digits("a")) CROSS JOIN \(digits("b")) CROSS JOIN \(digits("c"))
                  CROSS JOIN \(digits("d")) CROSS JOIN \(digits("e")) CROSS JOIN \(digits("f"))
                ) numbers
                WHERE g <= \(rows)
                """,
            ]
        },
        createTarget: { name in
            """
            CREATE TABLE \(name) (id BIGINT PRIMARY KEY, whole BIGINT, fraction DOUBLE,
              amount DECIMAL(20,6), flag TINYINT(1), label TEXT, created DATETIME) CHARACTER SET utf8mb4
            """
        },
        prepareSession: ["SET SESSION group_concat_max_len = 1073741824"],
        checksum: { table, withPayload in
            let values = [
                "id", "COALESCE(whole, '\\\\N')", "COALESCE(fraction, '\\\\N')", "COALESCE(amount, '\\\\N')",
                "COALESCE(flag, '\\\\N')", "COALESCE(label, '\\\\N')", "COALESCE(created, '\\\\N')",
            ] + (withPayload ? ["COALESCE(HEX(payload), '\\\\N')"] : [])
            return """
                SELECT COUNT(*), COALESCE(MD5(GROUP_CONCAT(MD5(CONCAT_WS('|', \(values.joined(separator: ", "))))
                  ORDER BY id SEPARATOR '')), '')
                FROM \(table)
                """
        }
    )

    private static func digits(_ alias: String) -> String {
        "(SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 "
            + "UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) \(alias)"
    }
}

// The host side of an export: `SELECT *` through the driver, quoted and escaped by it.
final class DriverExportSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId: String
    private let driver: any PluginDatabaseDriver
    private let schema: String?

    init(driver: any PluginDatabaseDriver, typeId: String, schema: String?) {
        self.driver = driver
        self.databaseTypeId = typeId
        self.schema = schema
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        driver.streamRows(query: "SELECT * FROM \(driver.quoteIdentifier(table))")
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        try await driver.fetchTableDDL(table: table, schema: schema)
    }

    func execute(query: String) async throws -> PluginQueryResult {
        try await driver.execute(query: query)
    }

    func quoteIdentifier(_ identifier: String) -> String {
        driver.quoteIdentifier(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        driver.escapeStringLiteral(value)
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
}

// The host side of a row import once every field is mapped to the column of its name: a field the
// target does not have stays unmapped, and each batch goes in as one bound multi-row INSERT.
final class DriverImportSink: PluginImportDataSink, @unchecked Sendable {
    let databaseTypeId: String
    let targetTable: String?
    private let driver: any PluginDatabaseDriver
    private let columns: Set<String>

    init(driver: any PluginDatabaseDriver, typeId: String, table: String, columns: [String]) {
        self.driver = driver
        self.databaseTypeId = typeId
        self.targetTable = table
        self.columns = Set(columns)
    }

    func execute(statement: String) async throws {
        _ = try await driver.execute(query: statement)
    }

    func insertRow(_ values: [String: PluginCellValue]) async throws {
        try await insertRows([values])
    }

    func insertRows(_ rows: [[String: PluginCellValue]]) async throws {
        guard let table = targetTable, let first = rows.first else { return }
        let names = first.keys.filter { columns.contains($0) }.sorted()
        var parameters: [PluginCellValue] = []
        var tuples: [String] = []
        for row in rows {
            var placeholders: [String] = []
            for name in names {
                parameters.append(row[name] ?? .null)
                placeholders.append(driver.parameterStyle == .dollar ? "$\(parameters.count)" : "?")
            }
            tuples.append("(\(placeholders.joined(separator: ", ")))")
        }
        let quoted = names.map { driver.quoteIdentifier($0) }.joined(separator: ", ")
        _ = try await driver.executeParameterized(
            query: "INSERT INTO \(driver.quoteIdentifier(table)) (\(quoted)) VALUES \(tuples.joined(separator: ", "))",
            parameters: parameters
        )
    }

    func deleteAllRowsFromTargetTable() async throws {
        guard let table = targetTable else { return }
        _ = try await driver.execute(query: "DELETE FROM \(driver.quoteIdentifier(table))")
    }

    func beginTransaction() async throws { try await driver.beginTransaction() }
    func commitTransaction() async throws { try await driver.commitTransaction() }
    func rollbackTransaction() async throws { try await driver.rollbackTransaction() }
}

final class FileSource: PluginImportSource, @unchecked Sendable {
    private let url: URL

    init(_ url: URL) {
        self.url = url
    }

    func fileURL() -> URL { url }

    func fileSizeBytes() -> Int64 {
        Int64(Probe.size(of: url))
    }

    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        throw ProbeFailure(description: "row formats have no statements")
    }
}

@main
enum Probe {
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let code: Int32
        do {
            code = try await run(try Settings.parse())
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            code = 3
        }
        exit(code)
    }

    static func run(_ settings: Settings) async throws -> Int32 {
        let engine = settings.engine == "mysql" ? Engine.mysql : Engine.postgresql
        let driver = try await connect(settings, engine: engine, database: settings.database)
        let restore = try await connect(settings, engine: engine, database: settings.restoreDatabase)
        defer {
            driver.disconnect()
            restore.disconnect()
        }

        print("creating rt_source with \(settings.rows) rows")
        for statement in engine.createSource(settings.rows) {
            _ = try await driver.execute(query: statement)
        }
        let source = DriverExportSource(driver: driver, typeId: engine.typeId, schema: engine.schema(settings))
        let shared = try await checksum(driver, engine, "rt_source", withPayload: false)
        let full = try await checksum(driver, engine, "rt_source", withPayload: true)
        print("source          rows=\(shared.rows) checksum=\(shared.digest) with payload=\(full.digest)")

        var failed = false
        for format in settings.formats {
            do {
                let mismatched = try await roundTrip(
                    format, source: source, driver: driver, restore: restore, engine: engine,
                    settings: settings, expected: (shared: shared.digest, full: full.digest)
                )
                failed = mismatched || failed
            } catch {
                print("\(format.padding(toLength: 15, withPad: " ", startingAt: 0)) FAILED: \(error)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }

    static func roundTrip(
        _ format: String,
        source: DriverExportSource,
        driver: any PluginDatabaseDriver,
        restore: any PluginDatabaseDriver,
        engine: Engine,
        settings: Settings,
        expected: (shared: String, full: String)
    ) async throws -> Bool {
        let started = Date()
        let outcome: (files: [URL], rows: Int, digest: String, expected: String)
        switch format {
        case "csv", "json", "ndjson", "xlsx":
            let file = try await exportRows(format, from: source, settings: settings)
            let table = "rt_\(format)"
            _ = try await driver.execute(query: "DROP TABLE IF EXISTS \(table)")
            _ = try await driver.execute(query: engine.createTarget(table))
            try await importRows(format, file: file, into: table, driver: driver, engine: engine, settings: settings)
            let read = try await checksum(driver, engine, table, withPayload: false)
            _ = try await driver.execute(query: "DROP TABLE \(table)")
            outcome = ([file], read.rows, read.digest, expected.shared)
        case "sql", "sql.gz", "sql-split":
            let files = try await exportDump(format, from: source, settings: settings)
            _ = try await restore.execute(query: "DROP TABLE IF EXISTS rt_source")
            try restoreDump(files, settings: settings)
            let read = try await checksum(restore, engine, "rt_source", withPayload: true)
            _ = try await restore.execute(query: "DROP TABLE rt_source")
            outcome = (files, read.rows, read.digest, expected.full)
        default:
            throw ProbeFailure(description: "unknown format \(format)")
        }
        let bytes = outcome.files.reduce(0) { $0 + size(of: $1) }
        let same = outcome.rows == settings.rows && outcome.digest == outcome.expected
        let megabytes = String(format: "%.1f MB", Double(bytes) / 1_048_576)
        let seconds = String(format: "%.0f s", Date().timeIntervalSince(started))
        print("\(format.padding(toLength: 15, withPad: " ", startingAt: 0)) rows=\(outcome.rows) checksum=\(outcome.digest) "
            + "files=\(outcome.files.count) size=\(megabytes) time=\(seconds) \(same ? "OK" : "MISMATCH")")
        for file in outcome.files {
            try? FileManager.default.removeItem(at: file)
        }
        return !same
    }

    static func connect(_ settings: Settings, engine: Engine, database: String) async throws -> any PluginDatabaseDriver {
        let plugin = try load(engine.bundle, from: settings)
        guard let driverPlugin = plugin as? any DriverPlugin else {
            throw ProbeFailure(description: "\(engine.bundle) is not a driver")
        }
        let driver = driverPlugin.createDriver(config: DriverConnectionConfig(
            host: settings.host, port: settings.port, username: settings.user,
            password: settings.password, database: database))
        try await driver.connect()
        for statement in engine.prepareSession {
            _ = try await driver.execute(query: statement)
        }
        return driver
    }

    static func load(_ name: String, from settings: Settings) throws -> any TableProPlugin {
        let url = settings.plugins.appendingPathComponent("\(name).tableplugin")
        guard let bundle = Bundle(url: url) else { throw ProbeFailure(description: "no bundle at \(url.path)") }
        try bundle.loadAndReturnError()
        guard let type = bundle.principalClass as? any TableProPlugin.Type else {
            throw ProbeFailure(description: "\(name) has no TableProPlugin principal class")
        }
        return type.init()
    }

    static func exportRows(_ format: String, from source: DriverExportSource, settings: Settings) async throws -> URL {
        let (bundle, options, fileExtension): (String, [String: Any], String) = switch format {
        case "csv": ("CSVExport", [:], "csv")
        case "json": ("JSONExport", ["layout": "object"], "json")
        case "ndjson": ("JSONExport", ["layout": "newlineDelimited"], "ndjson")
        default: ("XLSXExport", ["includeHeaderRow": true, "convertNullToEmpty": true], "xlsx")
        }
        let file = settings.work.appendingPathComponent("rt.\(fileExtension)")
        try await export(bundle, options: options, source: source, to: file, settings: settings)
        return file
    }

    static func exportDump(_ format: String, from source: DriverExportSource, settings: Settings) async throws -> [URL] {
        let options: [String: Any] = switch format {
        case "sql.gz": ["compressWithGzip": true]
        case "sql-split": ["splitSizeMegabytes": 32]
        default: [:]
        }
        let file = settings.work.appendingPathComponent(format == "sql.gz" ? "dump.sql.gz" : "dump.sql")
        try await export("SQLExport", options: options, source: source, to: file, settings: settings, structure: true)
        guard format == "sql-split" else { return [file] }
        var parts: [URL] = []
        while case let part = settings.work.appendingPathComponent("dump.part\(parts.count + 1).sql"),
              FileManager.default.fileExists(atPath: part.path) {
            parts.append(part)
        }
        return parts.isEmpty ? [file] : parts
    }

    static func export(
        _ bundle: String,
        options: [String: Any],
        source: DriverExportSource,
        to file: URL,
        settings: Settings,
        structure: Bool = false
    ) async throws {
        let plugin = try load(bundle, from: settings)
        guard let exporter = plugin as? any ExportFormatPlugin, let settable = plugin as? any SettablePluginDiscoverable else {
            throw ProbeFailure(description: "\(bundle) is not a settable export format")
        }
        settable.restoreSettingsData(try JSONSerialization.data(withJSONObject: options))
        let table = PluginExportTable(
            name: "rt_source",
            databaseName: settings.engine == "mysql" ? settings.database : "public",
            tableType: "table",
            optionValues: structure ? [true, true, true] : exporter.defaultTableOptionValues()
        )
        let result = try await exporter.export(
            tables: [table], dataSource: source, destination: file,
            progress: PluginExportProgress(progress: Progress(totalUnitCount: 1)))
        for warning in result.warnings {
            print("  warning: \(warning)")
        }
    }

    static func importRows(
        _ format: String,
        file: URL,
        into table: String,
        driver: any PluginDatabaseDriver,
        engine: Engine,
        settings: Settings
    ) async throws {
        let bundle = switch format {
        case "csv": "CSVImport"
        case "xlsx": "XLSXImport"
        default: "JSONImport"
        }
        guard let importer = try load(bundle, from: settings) as? any ImportFormatPlugin else {
            throw ProbeFailure(description: "\(bundle) is not an import format")
        }
        let result = try await importer.performImport(
            source: FileSource(file),
            sink: DriverImportSink(driver: driver, typeId: engine.typeId, table: table, columns: Engine.sharedColumns),
            progress: PluginImportProgress(progress: Progress(totalUnitCount: 1)))
        if let error = result.errors.first {
            throw ProbeFailure(description: "\(format) import: line \(error.line): \(error.errorMessage)")
        }
    }

    // The engine's own client, so the check is that the dump is a script the engine restores.
    static func restoreDump(_ files: [URL], settings: Settings) throws {
        for file in files {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            let reader = file.pathExtension == "gz" ? "gzip -dc" : "cat"
            process.arguments = ["-c", "set -o pipefail; \(reader) \"$0\" | \"$@\"", file.path] + settings.client
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw ProbeFailure(description: "restoring \(file.lastPathComponent) failed")
            }
        }
    }

    static func checksum(
        _ driver: any PluginDatabaseDriver,
        _ engine: Engine,
        _ table: String,
        withPayload: Bool
    ) async throws -> (rows: Int, digest: String) {
        let result = try await driver.execute(query: engine.checksum(table, withPayload))
        guard let row = result.rows.first, row.count == 2 else {
            throw ProbeFailure(description: "no checksum for \(table)")
        }
        return (Int(row[0].asText ?? "") ?? -1, row[1].asText ?? "")
    }

    static func size(of url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
    }
}
