//
//  SchemaServiceUserDefinedTypesTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

private final class TypeMockDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var typesToReturn: [UserDefinedTypeInfo] = []
    var typesCallCount = 0
    var typesShouldFail = false

    init(connection: DatabaseConnection) {
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
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func fetchTables() async throws -> [TableInfo] {
        [TestFixtures.makeTableInfo(name: "users")]
    }

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

    func fetchUserDefinedTypes(schema: String?) async throws -> [UserDefinedTypeInfo] {
        typesCallCount += 1
        if typesShouldFail {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        }
        return typesToReturn
    }
}

@Suite("SchemaService user-defined types")
@MainActor
struct SchemaServiceUserDefinedTypesTests {
    private let mood = UserDefinedTypeInfo(name: "mood", kind: .enumeration, schema: "public", enumLabels: ["sad", "ok"])

    @Test("load caches the types of an engine that declares them")
    func loadCachesTypes() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = TypeMockDriver(connection: connection)
        driver.typesToReturn = [mood]

        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        #expect(service.userDefinedTypes(for: connectionId) == [mood])
        #expect(service.userDefinedTypes(for: connectionId).first?.enumLabels == ["sad", "ok"])
        #expect(driver.typesCallCount == 1)
    }

    /// The capability gates the query, never the display. An engine with no named types must not
    /// pay a catalog read that can only answer empty.
    @Test("load never asks an engine that declares no types")
    func loadSkipsUndeclaredEngines() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .mysql)
        let driver = TypeMockDriver(connection: connection)
        driver.typesToReturn = [mood]

        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        #expect(service.userDefinedTypes(for: connectionId).isEmpty)
        #expect(driver.typesCallCount == 0)
    }

    @Test("A failed type fetch leaves tables loaded and types empty")
    func failingTypesDoNotBlockTables() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = TypeMockDriver(connection: connection)
        driver.typesShouldFail = true

        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        #expect(service.tables(for: connectionId).map(\.name) == ["users"])
        #expect(service.userDefinedTypes(for: connectionId).isEmpty)
        guard case .loaded = service.state(for: connectionId) else {
            Issue.record("expected loaded state when only the type fetch fails")
            return
        }
    }

    @Test("A reload replaces the cached types and reports success")
    func reloadReplacesTypes() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = TypeMockDriver(connection: connection)
        driver.typesToReturn = [mood]
        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        let status = UserDefinedTypeInfo(name: "status", kind: .domain, schema: "public", baseType: "text")
        driver.typesToReturn = [mood, status]
        let reloaded = await service.reloadUserDefinedTypes(connectionId: connectionId, driver: driver)

        #expect(reloaded)
        #expect(service.userDefinedTypes(for: connectionId).map(\.name) == ["mood", "status"])
    }

    /// A refresh never clears the cache it is refreshing.
    @Test("A failed reload keeps the previous types and reports failure")
    func failedReloadKeepsTypes() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = TypeMockDriver(connection: connection)
        driver.typesToReturn = [mood]
        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        driver.typesShouldFail = true
        let reloaded = await service.reloadUserDefinedTypes(connectionId: connectionId, driver: driver)

        #expect(!reloaded)
        #expect(service.userDefinedTypes(for: connectionId) == [mood])
    }

    @Test("invalidate drops the cached types with everything else")
    func invalidateDropsTypes() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = TypeMockDriver(connection: connection)
        driver.typesToReturn = [mood]
        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        await service.invalidate(connectionId: connectionId)

        #expect(service.userDefinedTypes(for: connectionId).isEmpty)
    }
}
