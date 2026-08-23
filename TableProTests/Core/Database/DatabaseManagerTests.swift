//
//  DatabaseManagerTests.swift
//  TableProTests
//
//  Tests for DatabaseManager session-scoped accessors.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("DatabaseManager Session-Scoped Accessors")
@MainActor
struct DatabaseManagerSessionTests {
    @Test("driver(for:) returns nil for unknown connection ID")
    func driverReturnsNilForUnknown() {
        let unknownId = UUID()
        #expect(DatabaseManager.shared.driver(for: unknownId) == nil)
    }

    @Test("session(for:) returns nil for unknown connection ID")
    func sessionReturnsNilForUnknown() {
        let unknownId = UUID()
        #expect(DatabaseManager.shared.session(for: unknownId) == nil)
    }

    @Test("activeSessions is accessible and starts empty for unknown IDs")
    func activeSessionsAccessible() {
        let unknownId = UUID()
        let session = DatabaseManager.shared.activeSessions[unknownId]
        #expect(session == nil)
    }

    @Test("resolvedSchemaName keeps an explicit schema over the session's current schema")
    func resolvedSchemaNameKeepsExplicitSchema() {
        let connection = TestFixtures.makeConnection()
        var session = ConnectionSession(connection: connection)
        session.browseSchema = "sales"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseManager.shared.resolvedSchemaName("audit", for: connection.id) == "audit")
    }

    @Test("resolvedSchemaName falls back to the session's current schema")
    func resolvedSchemaNameFallsBackToSessionSchema() {
        let connection = TestFixtures.makeConnection()
        var session = ConnectionSession(connection: connection)
        session.browseSchema = "sales"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseManager.shared.resolvedSchemaName(nil, for: connection.id) == "sales")
    }

    @Test("resolvedSchemaName stays nil without a session")
    func resolvedSchemaNameStaysNilWithoutSession() {
        #expect(DatabaseManager.shared.resolvedSchemaName(nil, for: UUID()) == nil)
    }

    @Test("resolvedSchemaName stays nil for a schema-less session")
    func resolvedSchemaNameStaysNilForSchemaLessSession() {
        let connection = TestFixtures.makeConnection()
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseManager.shared.resolvedSchemaName(nil, for: connection.id) == nil)
    }

    @Test("resolvedSchemaName treats a blank explicit schema as absent")
    func resolvedSchemaNameTreatsBlankExplicitSchemaAsAbsent() {
        let connection = TestFixtures.makeConnection()
        var session = ConnectionSession(connection: connection)
        session.browseSchema = "custom"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseManager.shared.resolvedSchemaName("", for: connection.id) == "custom")
    }

    @Test("resolvedSchemaName returns nil rather than a blank session schema")
    func resolvedSchemaNameRejectsBlankSessionSchema() {
        let connection = TestFixtures.makeConnection()
        var session = ConnectionSession(connection: connection)
        session.browseSchema = ""
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseManager.shared.resolvedSchemaName(nil, for: connection.id) == nil)
    }
}

private class DatabaseSwitchBaseDriver {
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

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

private final class DatabaseSwitchingDriver: DatabaseSwitchBaseDriver, PluginDatabaseDriver, @unchecked Sendable {
    private(set) var switchedDatabases: [String] = []
    private var schema: String?

    override var currentSchema: String? { schema }

    init(currentSchema: String? = nil) {
        self.schema = currentSchema
        super.init()
    }

    func switchDatabase(to database: String) async throws {
        switchedDatabases.append(database)
    }

    func switchSchema(to schema: String) async throws {
        self.schema = schema
    }
}

@Suite("DatabaseManager database switch")
@MainActor
struct DatabaseManagerDatabaseSwitchTests {
    @Test("bySchema engines move the driver to the plugin default and record what it is using")
    func bySchemaSwitchResetsSchemaToDefault() async throws {
        let connection = TestFixtures.makeConnection(type: .mssql)
        let pluginDriver = DatabaseSwitchingDriver(currentSchema: "sales")
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: pluginDriver)
        var session = ConnectionSession(connection: connection, driver: adapter)
        session.browseSchema = "sales"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try await DatabaseManager.shared.switchDatabase(to: "other_db", for: connection.id, persist: false)

        let updated = DatabaseManager.shared.session(for: connection.id)
        #expect(pluginDriver.switchedDatabases == ["other_db"])
        #expect(updated?.browseDatabase == "other_db")
        #expect(updated?.browseSchema == "dbo")
        #expect(pluginDriver.currentSchema == "dbo")
    }

    @Test("A database switch never leaves the session and the driver on different schemas")
    func sessionSchemaMatchesDriverAfterSwitch() async throws {
        let connection = TestFixtures.makeConnection(type: .mssql)
        let pluginDriver = DatabaseSwitchingDriver(currentSchema: "custom")
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: pluginDriver)
        var session = ConnectionSession(connection: connection, driver: adapter)
        session.browseSchema = "custom"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try await DatabaseManager.shared.switchDatabase(to: "other_db", for: connection.id, persist: false)

        #expect(DatabaseManager.shared.session(for: connection.id)?.browseSchema == adapter.currentSchema)
    }
}
