//
//  ExportServiceStateTests.swift
//  TableProTests
//
//  Tests for ExportServiceState wrapper that delegates to ExportService.
//

import Foundation
@testable import TablePro
import Testing

private final class StubDriver: DatabaseDriver {
    let connection = TestFixtures.makeConnection(type: .sqlite)
    var status: ConnectionStatus = .connected
    var serverVersion: String?

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func applyQueryTimeout(_ seconds: Int) async throws {}
    func execute(query: String) async throws -> QueryResult { .empty }
    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult { .empty }
    func fetchRowCount(query: String) async throws -> Int { 0 }
    func fetchRows(query: String, offset: Int, limit: Int) async throws -> QueryResult { .empty }
    func fetchTables() async throws -> [TableInfo] { [] }
    func fetchColumns(table: String) async throws -> [ColumnInfo] { [] }
    func fetchAllColumns() async throws -> [String: [ColumnInfo]] { [:] }
    func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }
    func fetchTableDDL(table: String) async throws -> String { "" }
    func fetchDependentSequences(forTable table: String) async throws -> [(name: String, ddl: String)] { [] }
    func fetchDependentTypes(forTable table: String) async throws -> [(name: String, labels: [String])] { [] }
    func fetchViewDefinition(view: String) async throws -> String { "" }
    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(tableName: tableName, dataSize: nil, indexSize: nil, totalSize: nil,
                      avgRowLength: nil, rowCount: nil, comment: nil, engine: nil,
                      collation: nil, createTime: nil, updateTime: nil)
    }
    func fetchDatabases() async throws -> [String] { [] }
    func fetchSchemas() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(id: database, name: database, tableCount: nil, sizeBytes: nil,
                         lastAccessed: nil, isSystemDatabase: false, icon: "cylinder")
    }
    func createDatabase(name: String, charset: String, collation: String?) async throws {}
    func cancelQuery() throws {}
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
}

@MainActor
@Suite("ExportServiceState")
struct ExportServiceStateTests {
    // MARK: - Default Values (No Service)

    @Test("Default values when no service is set")
    func defaultValuesNoService() {
        let state = ExportServiceState()

        #expect(state.service == nil)
        #expect(state.currentTable == "")
        #expect(state.currentTableIndex == 0)
        #expect(state.totalTables == 0)
        #expect(state.processedRows == 0)
        #expect(state.totalRows == 0)
        #expect(state.statusMessage == "")
    }

    // MARK: - Service Delegation

    @Test("Properties delegate to service state after setting service")
    func propertiesDelegateToService() {
        let state = ExportServiceState()
        let driver = StubDriver()
        let service = ExportService(driver: driver, databaseType: .sqlite)

        service.state = ExportState(
            currentTable: "users",
            currentTableIndex: 2,
            totalTables: 5,
            processedRows: 100,
            totalRows: 500,
            statusMessage: "Exporting..."
        )

        state.setService(service)

        #expect(state.currentTable == "users")
        #expect(state.currentTableIndex == 2)
        #expect(state.totalTables == 5)
        #expect(state.processedRows == 100)
        #expect(state.totalRows == 500)
        #expect(state.statusMessage == "Exporting...")
    }

    // MARK: - State Mutation

    @Test("Wrapper reflects changes after mutating service state")
    func wrapperReflectsServiceStateMutation() {
        let state = ExportServiceState()
        let driver = StubDriver()
        let service = ExportService(driver: driver, databaseType: .sqlite)

        state.setService(service)

        #expect(state.currentTable == "")
        #expect(state.processedRows == 0)

        service.state.currentTable = "orders"
        service.state.processedRows = 42
        service.state.totalRows = 200
        service.state.statusMessage = "Processing..."

        #expect(state.currentTable == "orders")
        #expect(state.processedRows == 42)
        #expect(state.totalRows == 200)
        #expect(state.statusMessage == "Processing...")
    }

    // MARK: - Service Replacement

    @Test("Setting a new service replaces the old one")
    func settingNewServiceReplacesOld() {
        let state = ExportServiceState()
        let driver = StubDriver()

        let service1 = ExportService(driver: driver, databaseType: .sqlite)
        service1.state.currentTable = "old_table"
        service1.state.processedRows = 999

        state.setService(service1)
        #expect(state.currentTable == "old_table")
        #expect(state.processedRows == 999)

        let service2 = ExportService(driver: driver, databaseType: .sqlite)
        service2.state.currentTable = "new_table"
        service2.state.processedRows = 1

        state.setService(service2)
        #expect(state.currentTable == "new_table")
        #expect(state.processedRows == 1)
        #expect(state.service === service2)
    }
}
