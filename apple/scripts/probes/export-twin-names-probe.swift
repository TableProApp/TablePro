import Foundation
import TableProPluginKit

// Reads one schema through a real driver the way the app's export adapter does, and dumps it through the real SQL
// export. check-export-twin-names.sh creates the fixture, restores each dump and compares the rows.
final class ProbeExportSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId: String
    let driver: any PluginDatabaseDriver
    let schema: String?

    init(databaseTypeId: String, driver: any PluginDatabaseDriver, schema: String?) {
        self.databaseTypeId = databaseTypeId
        self.driver = driver
        self.schema = schema
    }

    var bulkReads: PluginExportBulkReads { driver.exportBulkReads }
    var tableDDLIncludesForeignKeys: Bool { driver.tableDDLIncludesForeignKeys }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        driver.streamRows(query: "SELECT * FROM \(driver.quoteIdentifier(table)) ORDER BY 1")
    }

    func execute(query: String) async throws -> PluginQueryResult { try await driver.execute(query: query) }
    func quoteIdentifier(_ identifier: String) -> String { driver.quoteIdentifier(identifier) }
    func escapeStringLiteral(_ value: String) -> String { driver.escapeStringLiteral(value) }
    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        try await driver.fetchTableDDL(table: table, schema: schema)
    }

    func dropStatement(for object: PluginExportTable) -> String? {
        driver.generateDropRelationSQL(name: object.name, kind: object.kind, schema: schema)
    }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        try await driver.fetchColumns(table: table, schema: schema)
    }

    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
        try await driver.fetchAllColumnsForExport(schema: schema)
    }

    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] {
        try await driver.fetchForeignKeys(table: table, schema: schema)
    }

    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
        try await driver.fetchAllForeignKeysForExport(schema: schema)
    }

    func fetchIndexes(table: String, databaseName: String) async throws -> [PluginIndexInfo] {
        try await driver.fetchIndexes(table: table, schema: schema)
    }

    func fetchAllIndexes(databaseName: String) async throws -> [String: [PluginIndexInfo]] {
        try await driver.fetchAllIndexesForExport(schema: schema)
    }

    func fetchIndexDDL(table: String, databaseName: String) async throws -> [String] {
        try await driver.fetchIndexDDL(table: table, schema: schema)
    }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        try await driver.openSessionScope(for: purpose)
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        try await driver.closeSessionScope(scope)
    }
}

private func hex(_ text: String) -> String {
    text.utf8.map { String(format: "%02x", $0) }.joined()
}

private func describe(_ column: PluginColumnInfo) -> String {
    "\(hex(column.name)) \(column.dataType) generated=\(column.isGenerated) key=\(column.isPrimaryKey)"
}

private func describe(_ key: PluginForeignKeyInfo) -> String {
    "\(hex(key.name)) \(hex(key.column)) -> \(hex(key.referencedTable)).\(hex(key.referencedColumn))"
}

// An export read either throws, so the export reads each table alone, or answers each table as its own read does.
@MainActor
private func checkRead<Value>(
    _ label: String,
    tables: [String],
    group: () async throws -> [String: [Value]],
    alone: (String) async throws -> [Value],
    describe: (Value) -> String
) async throws -> Bool {
    let answer: [String: [Value]]
    do {
        answer = try await group()
    } catch {
        print("\(label) read threw (\(error.localizedDescription)), so each table is read alone")
        return true
    }
    var sound = true
    for table in tables {
        let own = try await alone(table).map(describe)
        switch PluginExportSpelling.entry(table, in: answer) {
        case .answered(let values):
            let given = values.map(describe)
            if !given.elementsEqual(own, by: { Array($0.utf8) == Array($1.utf8) }) {
                print("BUG: the \(label) read gives \(hex(table)) \(given.count) entries, its own read \(own.count)")
                sound = false
            }
        case .absent:
            if !own.isEmpty {
                print("BUG: the \(label) read leaves out \(hex(table)), which has \(own.count)")
                sound = false
            }
        case .otherSpelling:
            break
        }
    }
    if sound { print("\(label) read: every table answered as its own read answers it, or read alone") }
    return sound
}

@main
enum ExportTwinNamesProbe {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 10 else {
            print("usage: Probe <type id> <host> <port> <user> <database> <schema> <out-dir> <check|count> <run>...")
            exit(2)
        }
        let typeId = arguments[1]
        var fields: [String: String] = [:]
        if let variant = EnginePlugin.driverVariant(for: typeId) { fields["driverVariant"] = variant }
        let driver = EnginePlugin().createDriver(config: DriverConnectionConfig(
            host: arguments[2], port: Int(arguments[3]) ?? 0, username: arguments[4],
            password: ProcessInfo.processInfo.environment["PROBE_PASSWORD"] ?? "", database: arguments[5],
            ssl: SSLConfiguration(mode: .disabled), additionalFields: fields
        ))
        let schema = arguments[6].isEmpty ? nil : arguments[6]
        let folder = URL(fileURLWithPath: arguments[7])
        let checksReads = arguments[8] == "check"
        // Each run: a label, then the tables it exports, as "label=t1,t2"; "label=*" exports every table.
        let runs = arguments.dropFirst(9).map { run -> (String, String) in
            let parts = run.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0], parts.count > 1 ? parts[1] : "*")
        }
        do {
            try await driver.connect()
            let tables = try await driver.fetchTables(schema: schema)
                .filter { $0.type.uppercased() != "VIEW" }
                .map(\.name)
            var sound = true
            if checksReads {
                sound = try await checkRead(
                    "column", tables: tables,
                    group: { try await driver.fetchAllColumnsForExport(schema: schema) },
                    alone: { try await driver.fetchColumns(table: $0, schema: schema) },
                    describe: describe
                ) && sound
                sound = try await checkRead(
                    "foreign key", tables: tables,
                    group: { try await driver.fetchAllForeignKeysForExport(schema: schema) },
                    alone: { try await driver.fetchForeignKeys(table: $0, schema: schema) },
                    describe: describe
                ) && sound
            }
            for (label, list) in runs {
                let wanted = list == "*" ? tables : list.split(separator: ",").map { decode(String($0)) }
                let objects = wanted.map {
                    PluginExportTable(
                        name: $0, databaseName: schema ?? "", tableType: "table",
                        optionValues: [true, true, true], schema: schema, kind: .table
                    )
                }
                let source = ProbeExportSource(databaseTypeId: typeId, driver: driver, schema: schema)
                let sql = SQLExportPlugin()
                sql.settings = SQLExportOptions()
                let result = try await sql.export(
                    tables: objects, dataSource: source, destination: folder.appendingPathComponent("\(label).sql"),
                    progress: PluginExportProgress(progress: Progress(totalUnitCount: 1))
                )
                print("dump \(label): \(objects.count) tables")
                for warning in result.warnings { print("  warning: \(warning)") }
            }
            driver.disconnect()
            exit(sound ? 0 : 1)
        } catch {
            print("error: \(error)")
            exit(2)
        }
    }

    // Table names arrive as hex, so a decomposed name survives every shell on the way.
    static func decode(_ hexName: String) -> String {
        var bytes: [UInt8] = []
        var index = hexName.startIndex
        while index < hexName.endIndex {
            let next = hexName.index(index, offsetBy: 2)
            bytes.append(UInt8(hexName[index..<next], radix: 16) ?? 0)
            index = next
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
}
