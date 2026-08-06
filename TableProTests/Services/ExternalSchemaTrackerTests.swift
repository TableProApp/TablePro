//
//  ExternalSchemaTrackerTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class ExternalSchemaMockDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var externalSchemasToReturn: Set<String> = []
    var externalSchemasError: Error?
    private(set) var externalSchemaCallCount = 0

    init(connection: DatabaseConnection = TestFixtures.makeConnection()) {
        self.connection = connection
    }

    func connect() async throws {}
    func disconnect() {}
    func testConnection() async throws -> Bool { true }
    func applyQueryTimeout(_ seconds: Int) async throws {}

    func execute(query: String) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func executeParameterized(query: String, parameters: [Any?]) async throws -> QueryResult {
        try await execute(query: query)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        try await execute(query: query)
    }

    func fetchExternalSchemaNames() async throws -> Set<String> {
        externalSchemaCallCount += 1
        if let externalSchemasError { throw externalSchemasError }
        return externalSchemasToReturn
    }

    func fetchTables() async throws -> [TableInfo] { [] }
    func fetchColumns(table: String) async throws -> [ColumnInfo] { [] }
    func fetchIndexes(table: String) async throws -> [IndexInfo] { [] }
    func fetchForeignKeys(table: String) async throws -> [ForeignKeyInfo] { [] }
    func fetchApproximateRowCount(table: String) async throws -> Int? { nil }
    func fetchTableDDL(table: String) async throws -> String { "" }
    func fetchViewDefinition(view: String) async throws -> String { "" }

    func fetchTableMetadata(tableName: String) async throws -> TableMetadata {
        TableMetadata(
            tableName: tableName, dataSize: nil, indexSize: nil, totalSize: nil,
            avgRowLength: nil, rowCount: nil, comment: nil, engine: nil,
            collation: nil, createTime: nil, updateTime: nil
        )
    }

    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> DatabaseMetadata {
        DatabaseMetadata(
            id: database, name: database, tableCount: nil, sizeBytes: nil,
            lastAccessed: nil, isSystemDatabase: false, icon: "cylinder"
        )
    }

    func cancelQuery() throws {}
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
    func fetchProcedures(schema: String?) async throws -> [RoutineInfo] { [] }
    func fetchFunctions(schema: String?) async throws -> [RoutineInfo] { [] }
}

@Suite("ExternalSchemaTracker")
@MainActor
struct ExternalSchemaTrackerTests {
    private func freshTracker(connectionId: UUID) -> ExternalSchemaTracker {
        let tracker = ExternalSchemaTracker.shared
        tracker.reset(connectionId: connectionId)
        return tracker
    }

    @Test("An unloaded schema is not reported as external")
    func unloadedSchemaIsNotExternal() {
        let connectionId = UUID()
        let tracker = freshTracker(connectionId: connectionId)
        #expect(!tracker.isExternal(connectionId: connectionId, database: "dev", schema: "etl"))
        tracker.reset(connectionId: connectionId)
    }

    @Test("Loaded external schemas are reported, local ones are not")
    func loadedSchemasAreClassified() async {
        let connectionId = UUID()
        let tracker = freshTracker(connectionId: connectionId)
        let driver = ExternalSchemaMockDriver()
        driver.externalSchemasToReturn = ["etl", "pennylane"]

        await tracker.load(connectionId: connectionId, database: "dev", driver: driver)

        #expect(tracker.isExternal(connectionId: connectionId, database: "dev", schema: "etl"))
        #expect(tracker.isExternal(connectionId: connectionId, database: "dev", schema: "pennylane"))
        #expect(!tracker.isExternal(connectionId: connectionId, database: "dev", schema: "public"))
        tracker.reset(connectionId: connectionId)
    }

    @Test("A second load for the same database does not refetch")
    func repeatLoadDoesNotRefetch() async {
        let connectionId = UUID()
        let tracker = freshTracker(connectionId: connectionId)
        let driver = ExternalSchemaMockDriver()
        driver.externalSchemasToReturn = ["etl"]

        await tracker.load(connectionId: connectionId, database: "dev", driver: driver)
        await tracker.load(connectionId: connectionId, database: "dev", driver: driver)

        #expect(driver.externalSchemaCallCount == 1)
        tracker.reset(connectionId: connectionId)
    }

    @Test("A failed load degrades to no external schemas instead of propagating")
    func failedLoadDegrades() async {
        struct ProbeFailure: Error {}
        let connectionId = UUID()
        let tracker = freshTracker(connectionId: connectionId)
        let driver = ExternalSchemaMockDriver()
        driver.externalSchemasError = ProbeFailure()

        await tracker.load(connectionId: connectionId, database: "dev", driver: driver)

        #expect(!tracker.isExternal(connectionId: connectionId, database: "dev", schema: "etl"))
        tracker.reset(connectionId: connectionId)
    }

    @Test("Classification is scoped per database")
    func classificationIsScopedPerDatabase() async {
        let connectionId = UUID()
        let tracker = freshTracker(connectionId: connectionId)
        let driver = ExternalSchemaMockDriver()
        driver.externalSchemasToReturn = ["etl"]

        await tracker.load(connectionId: connectionId, database: "dev", driver: driver)

        #expect(tracker.isExternal(connectionId: connectionId, database: "dev", schema: "etl"))
        #expect(!tracker.isExternal(connectionId: connectionId, database: "analytics", schema: "etl"))
        tracker.reset(connectionId: connectionId)
    }

    @Test("Reset clears the connection's classification")
    func resetClearsConnection() async {
        let connectionId = UUID()
        let tracker = freshTracker(connectionId: connectionId)
        let driver = ExternalSchemaMockDriver()
        driver.externalSchemasToReturn = ["etl"]

        await tracker.load(connectionId: connectionId, database: "dev", driver: driver)
        tracker.reset(connectionId: connectionId)

        #expect(!tracker.isExternal(connectionId: connectionId, database: "dev", schema: "etl"))
    }
}
