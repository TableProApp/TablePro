//
//  SchemaServiceRoutinesTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

private final class RoutineMockDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

    var tablesToReturn: [TableInfo] = []
    var proceduresToReturn: [RoutineInfo] = []
    var functionsToReturn: [RoutineInfo] = []

    var proceduresCallCount = 0
    var functionsCallCount = 0
    var tablesCallCount = 0

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
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [Any?]?) async throws -> QueryResult {
        QueryResult(columns: [], columnTypes: [], rows: [], rowsAffected: 0, executionTime: 0, error: nil)
    }

    func fetchTables() async throws -> [TableInfo] {
        tablesCallCount += 1
        return tablesToReturn
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

    func fetchProcedures(schema: String?) async throws -> [RoutineInfo] {
        proceduresCallCount += 1
        return proceduresToReturn
    }

    func fetchFunctions(schema: String?) async throws -> [RoutineInfo] {
        functionsCallCount += 1
        return functionsToReturn
    }
}

private final class FailingRoutineDriver: DatabaseDriver, @unchecked Sendable {
    let connection: DatabaseConnection
    var status: ConnectionStatus = .connected
    var serverVersion: String? { nil }

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

    func fetchProcedures(schema: String?) async throws -> [RoutineInfo] {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
    }

    func fetchFunctions(schema: String?) async throws -> [RoutineInfo] {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
    }
}

@Suite("SchemaService routines")
@MainActor
struct SchemaServiceRoutinesTests {
    @Test("load caches procedures and functions alongside tables")
    func loadCachesRoutines() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RoutineMockDriver(connection: connection)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "users")]
        driver.proceduresToReturn = [
            RoutineInfo(name: "add_user", schema: "public", kind: .procedure, signature: nil)
        ]
        driver.functionsToReturn = [
            RoutineInfo(name: "user_count", schema: "public", kind: .function, signature: "int")
        ]

        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        #expect(service.tables(for: connectionId).map(\.name) == ["users"])
        #expect(service.procedures(for: connectionId).map(\.name) == ["add_user"])
        #expect(service.functions(for: connectionId).map(\.name) == ["user_count"])
        #expect(driver.tablesCallCount == 1)
        #expect(driver.proceduresCallCount == 1)
        #expect(driver.functionsCallCount == 1)
    }

    @Test("routines() concatenates procedures then functions")
    func routinesConcatenation() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RoutineMockDriver(connection: connection)
        driver.proceduresToReturn = [
            RoutineInfo(name: "p1", schema: nil, kind: .procedure, signature: nil)
        ]
        driver.functionsToReturn = [
            RoutineInfo(name: "f1", schema: nil, kind: .function, signature: nil)
        ]

        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        let combined = service.routines(for: connectionId)
        #expect(combined.map(\.name) == ["p1", "f1"])
        #expect(combined.map(\.kind) == [.procedure, .function])
    }

    @Test("failing routine fetches leave tables loaded and routines empty")
    func failingRoutinesDoNotBlockTables() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = FailingRoutineDriver(connection: connection)

        await service.load(connectionId: connectionId, driver: driver, connection: connection)

        #expect(service.tables(for: connectionId).map(\.name) == ["users"])
        #expect(service.procedures(for: connectionId).isEmpty)
        #expect(service.functions(for: connectionId).isEmpty)
        if case .loaded = service.state(for: connectionId) {
            // success: state is loaded even though routines failed
        } else {
            Issue.record("expected loaded state when only routine fetches fail")
        }
    }

    @Test("invalidate clears tables and routine caches")
    func invalidateClearsAll() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RoutineMockDriver(connection: connection)
        driver.tablesToReturn = [TestFixtures.makeTableInfo(name: "t")]
        driver.proceduresToReturn = [
            RoutineInfo(name: "p", schema: nil, kind: .procedure, signature: nil)
        ]

        await service.load(connectionId: connectionId, driver: driver, connection: connection)
        #expect(!service.procedures(for: connectionId).isEmpty)

        await service.invalidate(connectionId: connectionId)

        #expect(service.tables(for: connectionId).isEmpty)
        #expect(service.procedures(for: connectionId).isEmpty)
        #expect(service.functions(for: connectionId).isEmpty)
    }

    @Test("reloadProcedures refreshes only procedures")
    func reloadProceduresOnly() async {
        let service = SchemaService()
        let connectionId = UUID()
        let connection = TestFixtures.makeConnection(id: connectionId, type: .postgresql)
        let driver = RoutineMockDriver(connection: connection)
        driver.proceduresToReturn = [
            RoutineInfo(name: "p1", schema: nil, kind: .procedure, signature: nil)
        ]
        await service.load(connectionId: connectionId, driver: driver, connection: connection)
        let firstProcCount = driver.proceduresCallCount
        let firstFuncCount = driver.functionsCallCount

        driver.proceduresToReturn = [
            RoutineInfo(name: "p1", schema: nil, kind: .procedure, signature: nil),
            RoutineInfo(name: "p2", schema: nil, kind: .procedure, signature: nil)
        ]
        await service.reloadProcedures(connectionId: connectionId, driver: driver)

        #expect(driver.proceduresCallCount == firstProcCount + 1)
        #expect(driver.functionsCallCount == firstFuncCount)
        #expect(service.procedures(for: connectionId).map(\.name) == ["p1", "p2"])
    }
}
