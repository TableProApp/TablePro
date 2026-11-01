import Foundation
import TableProPluginKit
import Testing

private final class StubTableDriver: PluginDatabaseDriver, @unchecked Sendable {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}
    func ping() async throws {}
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

struct PluginTableOptionsDefaultsTests {
    @Test("A driver that implements no table options reads none and writes none")
    func defaultsAreNil() async throws {
        let driver = StubTableDriver()
        #expect(try await driver.fetchTableOptions(table: "t", schema: nil) == nil)
        #expect(try await driver.fetchTableOptionsCatalog() == nil)
        #expect(try await driver.fetchDefaultTableOptions(schema: "app") == nil)
        let change = PluginTableOptionsChange(characterSet: "utf8mb4", collation: "utf8mb4_bin", autoIncrement: 5)
        #expect(driver.tableOptionsStatement(table: "t", schema: nil, change: change) == nil)
    }

    @Test("A change leaves every field it is not given as it is")
    func changeDefaultsLeaveFieldsAlone() {
        let change = PluginTableOptionsChange()
        #expect(change.characterSet == nil)
        #expect(change.collation == nil)
        #expect(!change.convertsColumns)
        #expect(change.autoIncrement == nil)
    }
}
