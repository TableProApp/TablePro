import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class RowScopeRecordingDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []

    var sentStatements: [String] {
        lock.withLock { statements }
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        lock.withLock { statements.append(query) }
        return AsyncThrowingStream { $0.finish() }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        lock.withLock { statements.append(query) }
        return .empty
    }

    func connect() async throws {}
    func disconnect() {}
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

struct ExportDataSourceAdapterRowScopeTests {
    private let firstRowOnly = PluginExportTable(
        name: "users",
        databaseName: "",
        tableType: "table",
        schema: nil,
        kind: .table,
        rowScope: PluginExportRowScope(rowLimit: 1)
    )

    private func adapter(
        for type: DatabaseType,
        over recorder: RowScopeRecordingDriver
    ) -> ExportDataSourceAdapter {
        let driver = PluginDriverAdapter(connection: TestFixtures.makeConnection(type: type), pluginDriver: recorder)
        return ExportDataSourceAdapter(driver: driver, databaseType: type)
    }

    @Test("A row scope on an engine without SQL fails the export and sends the driver nothing")
    func engineWithoutSQLRefusesTheScope() async {
        let recorder = RowScopeRecordingDriver()
        let stream = adapter(for: .mongodb, over: recorder).streamRows(for: firstRowOnly)
        await #expect(throws: PluginExportError.self) {
            for try await _ in stream {}
        }
        #expect(recorder.sentStatements.isEmpty)
    }

    @Test("A row scope on a SQL engine is sent as one limited statement")
    func sqlEngineAppliesTheScope() async throws {
        let recorder = RowScopeRecordingDriver()
        let stream = adapter(for: .postgresql, over: recorder).streamRows(for: firstRowOnly)
        for try await _ in stream {}
        #expect(recorder.sentStatements.count == 1)
        #expect(recorder.sentStatements.first?.hasSuffix("LIMIT 1") == true)
    }
}
