import Foundation
@testable import ProbeDriver
@testable import ProbeSQLExport
import TableProPluginKit

// Dumps each schema twice through the real driver and SQL export plugin: once reading each table's index, comment,
// sequence and enum DDL alone, once taking the schema-wide reads the driver declares. check-postgres-dump-schema-reads.sh
// diffs the two files.
final class ProbeExportSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId = "PostgreSQL"
    let driver: PostgreSQLPluginDriver
    let readsSchemas: Bool

    init(driver: PostgreSQLPluginDriver, readsSchemas: Bool) {
        self.driver = driver
        self.readsSchemas = readsSchemas
    }

    var bulkReads: PluginExportBulkReads { readsSchemas ? driver.exportBulkReads : [] }
    var tableDDLIncludesForeignKeys: Bool { driver.tableDDLIncludesForeignKeys }
    var supportsCascadeDrop: Bool { true }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        driver.streamRows(query: "SELECT * FROM \(driver.quoteIdentifier(databaseName)).\(driver.quoteIdentifier(table))")
    }

    func execute(query: String) async throws -> PluginQueryResult { try await driver.execute(query: query) }
    func quoteIdentifier(_ identifier: String) -> String { driver.quoteIdentifier(identifier) }
    func escapeStringLiteral(_ value: String) -> String { driver.escapeStringLiteral(value) }
    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        try await driver.fetchTableDDL(table: table, schema: databaseName)
    }

    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
        switch object.kind {
        case .view, .materializedView:
            return try await driver.fetchViewDefinition(view: object.name, schema: object.databaseName)
        case .sequence:
            let sequences = try await driver.fetchSequences(schema: object.databaseName)
            guard let sequence = sequences.first(where: { $0.name == object.name }) else {
                throw PluginObjectSourceError.unsupported(object.name)
            }
            return sequence.ddl
        default:
            return try await driver.fetchTableDDL(table: object.name, schema: object.databaseName)
        }
    }

    func dropStatement(for object: PluginExportTable) -> String? {
        guard [.table, .view, .materializedView].contains(object.kind) else { return nil }
        return driver.generateDropRelationSQL(name: object.name, kind: object.kind, schema: object.databaseName)
    }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        try await driver.fetchColumns(table: table, schema: databaseName)
    }

    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
        try await driver.fetchAllColumnsForExport(schema: databaseName)
    }

    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] {
        try await driver.fetchForeignKeys(table: table, schema: databaseName)
    }

    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
        try await driver.fetchAllForeignKeysForExport(schema: databaseName)
    }

    func fetchIndexDDL(table: String, databaseName: String) async throws -> [String] {
        try await driver.fetchIndexDDL(table: table, schema: databaseName)
    }

    func fetchCommentDDL(table: String, databaseName: String) async throws -> [String] {
        try await driver.fetchCommentDDL(table: table, schema: databaseName)
    }

    func fetchDependentSequences(table: String, databaseName: String) async throws -> [PluginSequenceInfo] {
        try await driver.fetchDependentSequences(table: table, schema: databaseName)
            .map { PluginSequenceInfo(name: $0.name, ddl: $0.ddl) }
    }

    func fetchDependentTypes(table: String, databaseName: String) async throws -> [PluginEnumTypeInfo] {
        try await driver.fetchDependentTypes(table: table, schema: databaseName)
            .map { PluginEnumTypeInfo(name: $0.name, labels: $0.labels) }
    }

    func fetchAllIndexDDL(databaseName: String) async throws -> [String: [String]] {
        try await driver.fetchAllIndexDDL(schema: databaseName)
    }

    func fetchAllCommentDDL(databaseName: String) async throws -> [String: [String]] {
        try await driver.fetchAllCommentDDL(schema: databaseName)
    }

    func fetchAllDependentSequences(databaseName: String) async throws -> [String: [PluginSequenceInfo]] {
        try await driver.fetchAllDependentSequences(schema: databaseName)
    }

    func fetchAllDependentTypes(databaseName: String) async throws -> [String: [PluginEnumTypeInfo]] {
        try await driver.fetchAllDependentTypes(schema: databaseName)
    }

    func openSessionScope(for purpose: PluginSessionPurpose) async throws -> PluginSessionScope? {
        try await driver.openSessionScope(for: purpose)
    }

    func closeSessionScope(_ scope: PluginSessionScope) async throws {
        try await driver.closeSessionScope(scope)
    }
}

@main
enum DumpSchemaReadsProbe {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 7 else {
            FileHandle.standardError.write(Data("usage: probe host port user database schema[,schema] out-dir\n".utf8))
            exit(2)
        }
        let driver = PostgreSQLPluginDriver(config: DriverConnectionConfig(
            host: arguments[1],
            port: Int(arguments[2]) ?? 5_432,
            username: arguments[3],
            password: ProcessInfo.processInfo.environment["PGPASSWORD"] ?? "",
            database: arguments[4]
        ))
        let schemas = arguments[5].split(separator: ",").map(String.init)
        let folder = URL(fileURLWithPath: arguments[6])
        do {
            try await driver.connect()
            let objects = try await exportObjects(driver, schemas: schemas)
            for readsSchemas in [false, true] {
                let plugin = SQLExportPlugin()
                plugin.settings = SQLExportOptions()
                let file = folder.appendingPathComponent(readsSchemas ? "schema-reads.sql" : "table-reads.sql")
                let started = Date()
                let result = try await plugin.export(
                    tables: objects,
                    dataSource: ProbeExportSource(driver: driver, readsSchemas: readsSchemas),
                    destination: file,
                    progress: PluginExportProgress(progress: Progress(totalUnitCount: 1))
                )
                let milliseconds = Int(Date().timeIntervalSince(started) * 1_000)
                print("\(readsSchemas ? "schema reads" : "table reads"): \(objects.count) objects, \(milliseconds) ms")
                for warning in result.warnings { print("  warning: \(warning)") }
            }
            driver.disconnect()
        } catch {
            print("error: \(error)")
            exit(2)
        }
    }

    // Every relation the export tree lists, partitions under their parent, and the sequences no column owns.
    static func exportObjects(_ driver: PostgreSQLPluginDriver, schemas: [String]) async throws -> [PluginExportTable] {
        var objects: [PluginExportTable] = []
        for schema in schemas {
            let listing = try await driver.execute(query: """
                SELECT c.relname, c.relkind::text FROM pg_catalog.pg_class c
                JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
                  AND c.relkind IN ('r', 'p', 'f', 'v', 'm', 'S') AND NOT c.relispartition
                  AND NOT (c.relkind = 'S' AND EXISTS (SELECT 1 FROM pg_catalog.pg_depend d
                      WHERE d.objid = c.oid AND d.deptype IN ('a', 'i')))
                ORDER BY c.relname COLLATE "C"
                """)
            for row in listing.rows {
                guard let name = row[0].asText, let relkind = row[1].asText else { continue }
                let kind: PluginExportObjectKind = switch relkind {
                case "v": .view
                case "m": .materializedView
                case "f": .foreignTable
                case "S": .sequence
                default: .table
                }
                objects.append(PluginExportTable(
                    name: name, databaseName: schema, tableType: relkind,
                    optionValues: [true, true, true], schema: schema, kind: kind
                ))
            }
        }
        return objects
    }
}
