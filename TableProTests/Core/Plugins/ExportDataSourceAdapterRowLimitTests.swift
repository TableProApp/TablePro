import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class StreamRecordingDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []

    var streamedQueries: [String] {
        lock.withLock { queries }
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        lock.withLock { queries.append(query) }
        return AsyncThrowingStream { $0.finish() }
    }

    func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }
    func connect() async throws {}
    func disconnect() {}
    func execute(query: String) async throws -> PluginQueryResult { .empty }
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

struct ExportDataSourceAdapterRowLimitTests {
    private func streamedQuery(
        type: DatabaseType,
        table: String,
        schema: String,
        scope: PluginExportRowScope
    ) -> String? {
        let recorder = StreamRecordingDriver()
        let driver = PluginDriverAdapter(
            connection: TestFixtures.makeConnection(type: type), pluginDriver: recorder
        )
        let adapter = ExportDataSourceAdapter(driver: driver, databaseType: type)
        _ = adapter.streamRows(for: PluginExportTable(
            name: table, databaseName: schema, tableType: "table", schema: schema, kind: .table,
            rowScope: scope
        ))
        return recorder.streamedQueries.last
    }

    @Test("A scoped SQL Server export limits its rows with TOP")
    func sqlServerScopedExport() {
        let query = streamedQuery(
            type: .mssql, table: "orders", schema: "dbo",
            scope: PluginExportRowScope(filter: "total > 10", rowLimit: 10)
        )
        #expect(query == "SELECT TOP 10 * FROM \"dbo\".\"orders\" WHERE total > 10")
    }

    @Test("A scoped Oracle export of one column limits its rows with FETCH FIRST and sorts nothing")
    func oracleScopedExport() {
        let query = streamedQuery(
            type: .oracle, table: "ORDERS", schema: "HR",
            scope: PluginExportRowScope(rowLimit: 10, columns: ["DOCUMENT"])
        )
        #expect(query == "SELECT \"DOCUMENT\" FROM \"HR\".\"ORDERS\" FETCH FIRST 10 ROWS ONLY")
    }

    @Test("A scoped MySQL export keeps LIMIT")
    func mysqlScopedExport() {
        let query = streamedQuery(
            type: .mysql, table: "orders", schema: "shop",
            scope: PluginExportRowScope(filter: "total > 10", rowLimit: 10)
        )
        #expect(query == "SELECT * FROM \"shop\".\"orders\" WHERE total > 10 LIMIT 10")
    }
}
