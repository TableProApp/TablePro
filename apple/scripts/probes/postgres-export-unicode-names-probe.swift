import Foundation
@testable import ProbeDataDictionary
@testable import ProbeDriver
@testable import ProbeSQLExport
import TableProPluginKit

// Exports the given schemas twice through the real driver, SQL export and Data Dictionary plugins: once with every read
// per table, once taking the schema-wide reads the driver declares, the way the app's export adapter asks for them.
// check-postgres-export-unicode-names.sh diffs the files and restores the schema-wide dump.
private struct NoGroupRead: Error {}

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
        driver.streamRows(
            query: "SELECT * FROM \(driver.quoteIdentifier(databaseName)).\(driver.quoteIdentifier(table)) ORDER BY 1"
        )
    }

    func execute(query: String) async throws -> PluginQueryResult { try await driver.execute(query: query) }
    func quoteIdentifier(_ identifier: String) -> String { driver.quoteIdentifier(identifier) }
    func escapeStringLiteral(_ value: String) -> String { driver.escapeStringLiteral(value) }
    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        try await driver.fetchTableDDL(table: table, schema: databaseName)
    }

    func fetchObjectDDL(_ object: PluginExportTable) async throws -> String {
        try await driver.fetchTableDDL(table: object.name, schema: object.databaseName)
    }

    func dropStatement(for object: PluginExportTable) -> String? {
        driver.generateDropRelationSQL(name: object.name, kind: object.kind, schema: object.databaseName)
    }

    func fetchColumns(table: String, databaseName: String) async throws -> [PluginColumnInfo] {
        try await driver.fetchColumns(table: table, schema: databaseName)
    }

    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
        guard readsSchemas else { throw NoGroupRead() }
        #if EXPORT_READS
        return try await driver.fetchAllColumnsForExport(schema: databaseName)
        #else
        return try await driver.fetchAllColumns(schema: databaseName)
        #endif
    }

    func fetchForeignKeys(table: String, databaseName: String) async throws -> [PluginForeignKeyInfo] {
        try await driver.fetchForeignKeys(table: table, schema: databaseName)
    }

    func fetchAllForeignKeys(databaseName: String) async throws -> [String: [PluginForeignKeyInfo]] {
        guard readsSchemas else { throw NoGroupRead() }
        #if EXPORT_READS
        return try await driver.fetchAllForeignKeysForExport(schema: databaseName)
        #else
        return try await driver.fetchAllForeignKeys(schema: databaseName)
        #endif
    }

    func fetchIndexes(table: String, databaseName: String) async throws -> [PluginIndexInfo] {
        try await driver.fetchIndexes(table: table, schema: databaseName)
    }

    func fetchAllIndexes(databaseName: String) async throws -> [String: [PluginIndexInfo]] {
        #if EXPORT_READS
        return try await driver.fetchAllIndexesForExport(schema: databaseName)
        #else
        return try await driver.fetchAllIndexes(schema: databaseName)
        #endif
    }

    func fetchObjectComment(_ object: PluginExportTable) async throws -> String? {
        try await driver.fetchObjectComment(table: object.name, schema: object.databaseName)
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
enum ExportUnicodeNamesProbe {
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
            let tables = try await exportTables(driver, schemas: schemas)
            for readsSchemas in [false, true] {
                let mode = readsSchemas ? "schema" : "table"
                let source = ProbeExportSource(driver: driver, readsSchemas: readsSchemas)
                let sql = SQLExportPlugin()
                sql.settings = SQLExportOptions()
                let dump = try await sql.export(
                    tables: tables, dataSource: source, destination: folder.appendingPathComponent("sql-\(mode).sql"),
                    progress: PluginExportProgress(progress: Progress(totalUnitCount: 1))
                )
                let dictionary = DataDictionaryExportPlugin()
                dictionary.settings = DataDictionaryExportOptions()
                // One file name for both, since the dictionary's title is its file's name.
                let described = try await dictionary.export(
                    tables: tables, dataSource: source,
                    destination: folder.appendingPathComponent(mode).appendingPathComponent("dictionary.md"),
                    progress: PluginExportProgress(progress: Progress(totalUnitCount: 1))
                )
                print("\(mode) reads: \(tables.count) tables")
                for warning in dump.warnings + described.warnings { print("  warning: \(warning)") }
            }
            driver.disconnect()
        } catch {
            print("error: \(error)")
            exit(2)
        }
    }

    // Every ordinary table in the listed schemas, in byte order of schema and name.
    static func exportTables(_ driver: PostgreSQLPluginDriver, schemas: [String]) async throws -> [PluginExportTable] {
        var tables: [PluginExportTable] = []
        for schema in schemas {
            let listing = try await driver.execute(query: """
                SELECT c.relname FROM pg_catalog.pg_class c
                JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema)) AND c.relkind = 'r'
                ORDER BY c.relname COLLATE "C"
                """)
            for row in listing.rows {
                guard let name = row[0].asText else { continue }
                tables.append(PluginExportTable(
                    name: name, databaseName: schema, tableType: "table",
                    optionValues: [true, true, true], schema: schema, kind: .table
                ))
            }
        }
        return tables
    }
}
