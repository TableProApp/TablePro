import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private class QueryCompletionProfileDriverBase {
    func connect() async throws {}
    func disconnect() {}

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

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

private final class DefaultQueryCompletionProfileDriver: QueryCompletionProfileDriverBase, PluginDatabaseDriver,
    @unchecked Sendable {}

private final class OverrideQueryCompletionProfileDriver: QueryCompletionProfileDriverBase, PluginDatabaseDriver,
    @unchecked Sendable {
    private(set) var receivedTypeIds: [String] = []

    func resolveQueryCompletionProfile(
        databaseTypeId: String,
        base: QueryCompletionProfile
    ) async throws -> QueryCompletionProfile {
        receivedTypeIds.append(databaseTypeId)
        return QueryCompletionProfile(
            resolvedDialect: base.resolvedDialect,
            statementCompletions: base.statementCompletions + [CompletionEntry(label: "TOP", insertText: "TOP")],
            revision: "override-\(databaseTypeId)"
        )
    }
}

@Suite("PluginDriverAdapter query completion profile")
struct PluginDriverAdapterQueryCompletionProfileTests {
    private func connection() -> DatabaseConnection {
        DatabaseConnection(
            name: "Completion Profile Test",
            host: "127.0.0.1",
            port: 1_433,
            database: "test",
            username: "sa",
            type: .mssql
        )
    }

    @Test("The adapter forwards completion profile resolution to the plugin driver")
    func forwardsResolutionOverride() async throws {
        let driver = OverrideQueryCompletionProfileDriver()
        let adapter = PluginDriverAdapter(connection: connection(), pluginDriver: driver)
        let base = QueryCompletionProfile(
            resolvedDialect: nil,
            statementCompletions: [CompletionEntry(label: "SELECT", insertText: "SELECT")],
            revision: "base"
        )

        let resolved = try await adapter.resolveQueryCompletionProfile(
            databaseTypeId: "SQL Server",
            base: base
        )

        #expect(driver.receivedTypeIds == ["SQL Server"])
        #expect(resolved.statementCompletions.map(\.label) == ["SELECT", "TOP"])
        #expect(resolved.revision == "override-SQL Server")
    }

    @Test("The adapter keeps the base profile when the plugin relies on the default implementation")
    func preservesBaseProfileByDefault() async throws {
        let adapter = PluginDriverAdapter(
            connection: connection(),
            pluginDriver: DefaultQueryCompletionProfileDriver()
        )
        let base = QueryCompletionProfile(
            resolvedDialect: nil,
            statementCompletions: [CompletionEntry(label: "SELECT", insertText: "SELECT")],
            revision: "base"
        )

        let resolved = try await adapter.resolveQueryCompletionProfile(
            databaseTypeId: "SQL Server",
            base: base
        )

        #expect(resolved.resolvedDialect == nil)
        #expect(resolved.statementCompletions.map(\.label) == ["SELECT"])
        #expect(resolved.revision == "base")
    }
}
