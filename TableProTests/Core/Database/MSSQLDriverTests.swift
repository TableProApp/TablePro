//
//  MSSQLDriverTests.swift
//  TableProTests
//
//  Tests for MSSQL driver plugin — parts that don't require a live connection.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

// MARK: - Mock MSSQL Plugin Driver

private final class MockMSSQLPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private var schema: String?
    var cancelQueryCallCount = 0
    var applyQueryTimeoutValues: [Int] = []
    var executedQueries: [String] = []
    var shouldFailExecute = true

    init(initialSchema: String?) {
        schema = initialSchema
    }

    var currentSchema: String? { schema }
    var supportsSchemas: Bool { true }

    func switchSchema(to schema: String) async throws {
        self.schema = schema
    }

    func connect() async throws {}
    func disconnect() {}

    func cancelQuery() throws {
        cancelQueryCallCount += 1
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        applyQueryTimeoutValues.append(seconds)
        executedQueries.append("SET LOCK_TIMEOUT \(seconds * 1_000)")
    }

    func execute(query: String) async throws -> PluginQueryResult {
        executedQueries.append(query)
        if shouldFailExecute {
            throw NSError(
                domain: "MockMSSQLPluginDriver",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Not connected"]
            )
        }
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
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

@MainActor
@Suite("MSSQL Driver")
struct MSSQLDriverTests {
    // MARK: - Helpers

    private func makeConnection(mssqlSchema: String? = nil) -> DatabaseConnection {
        var conn = TestFixtures.makeConnection(type: .mssql)
        conn.mssqlSchema = mssqlSchema
        return conn
    }

    private func makeAdapter(mssqlSchema: String? = nil) -> PluginDriverAdapter {
        let (adapter, _) = makeAdapterWithMock(mssqlSchema: mssqlSchema)
        return adapter
    }

    private func makeAdapterWithMock(mssqlSchema: String? = nil) -> (PluginDriverAdapter, MockMSSQLPluginDriver) {
        let conn = makeConnection(mssqlSchema: mssqlSchema)
        let effectiveSchema: String? = if let s = mssqlSchema, !s.isEmpty { s } else { "dbo" }
        let mock = MockMSSQLPluginDriver(initialSchema: effectiveSchema)
        let adapter = PluginDriverAdapter(connection: conn, pluginDriver: mock)
        return (adapter, mock)
    }

    // MARK: - Initialization Tests

    @Test("Init sets currentSchema to dbo when mssqlSchema is nil")
    func initDefaultSchemaNil() {
        let adapter = makeAdapter(mssqlSchema: nil)
        #expect(adapter.currentSchema == "dbo")
    }

    @Test("Init sets currentSchema to dbo when mssqlSchema is empty string")
    func initDefaultSchemaEmpty() {
        let adapter = makeAdapter(mssqlSchema: "")
        #expect(adapter.currentSchema == "dbo")
    }

    @Test("Init uses mssqlSchema when provided and non-empty")
    func initCustomSchema() {
        let adapter = makeAdapter(mssqlSchema: "sales")
        #expect(adapter.currentSchema == "sales")
    }

    // MARK: - escapedSchema Tests

    @Test("escapedSchema returns schema unchanged when no single quotes")
    func escapedSchemaNoQuotes() {
        let adapter = makeAdapter(mssqlSchema: "sales")
        #expect(adapter.escapedSchema == "sales")
    }

    @Test("escapedSchema doubles single quote in schema name")
    func escapedSchemaDoublesSingleQuote() {
        let adapter = makeAdapter(mssqlSchema: "O'Brien")
        #expect(adapter.escapedSchema == "O''Brien")
    }

    @Test("escapedSchema doubles multiple single quotes")
    func escapedSchemaMultipleQuotes() {
        let adapter = makeAdapter(mssqlSchema: "O'Bri'en")
        #expect(adapter.escapedSchema == "O''Bri''en")
    }

    // MARK: - switchSchema Tests

    @Test("switchSchema updates currentSchema")
    func switchSchemaUpdatesCurrentSchema() async throws {
        let adapter = makeAdapter()
        try await adapter.switchSchema(to: "hr")
        #expect(adapter.currentSchema == "hr")
    }

    @Test("switchSchema updates escapedSchema accordingly")
    func switchSchemaUpdatesEscapedSchema() async throws {
        let adapter = makeAdapter()
        try await adapter.switchSchema(to: "O'Connor")
        #expect(adapter.escapedSchema == "O''Connor")
    }

    // MARK: - Status Tests

    @Test("Status starts as disconnected")
    func statusStartsDisconnected() {
        let adapter = makeAdapter()
        if case .disconnected = adapter.status {
            #expect(true)
        } else {
            Issue.record("Expected .disconnected status, got \(adapter.status)")
        }
    }

    // MARK: - Execute Tests

    @Test("Execute throws when not connected")
    func executeThrowsWhenNotConnected() async throws {
        let adapter = makeAdapter()
        await #expect(throws: (any Error).self) {
            _ = try await adapter.execute(query: "SELECT 1")
        }
    }

    // MARK: - cancelQuery Tests

    @Test("cancelQuery delegates to plugin driver")
    func cancelQueryDelegatesToPlugin() throws {
        let (adapter, mock) = makeAdapterWithMock()
        try adapter.cancelQuery()
        #expect(mock.cancelQueryCallCount == 1)
    }

    @Test("cancelQuery can be called multiple times")
    func cancelQueryMultipleCalls() throws {
        let (adapter, mock) = makeAdapterWithMock()
        try adapter.cancelQuery()
        try adapter.cancelQuery()
        try adapter.cancelQuery()
        #expect(mock.cancelQueryCallCount == 3)
    }

    // MARK: - applyQueryTimeout Tests

    @Test("applyQueryTimeout delegates to plugin driver with correct value")
    func applyQueryTimeoutDelegates() async throws {
        let (adapter, mock) = makeAdapterWithMock()
        mock.shouldFailExecute = false
        try await adapter.applyQueryTimeout(30)
        #expect(mock.applyQueryTimeoutValues == [30])
    }

    @Test("applyQueryTimeout with zero is handled by plugin")
    func applyQueryTimeoutZero() async throws {
        let (adapter, mock) = makeAdapterWithMock()
        mock.shouldFailExecute = false
        try await adapter.applyQueryTimeout(0)
        #expect(mock.applyQueryTimeoutValues == [0])
    }

    @Test("applyQueryTimeout with different values records each call")
    func applyQueryTimeoutMultipleCalls() async throws {
        let (adapter, mock) = makeAdapterWithMock()
        mock.shouldFailExecute = false
        try await adapter.applyQueryTimeout(10)
        try await adapter.applyQueryTimeout(60)
        #expect(mock.applyQueryTimeoutValues == [10, 60])
    }
}
