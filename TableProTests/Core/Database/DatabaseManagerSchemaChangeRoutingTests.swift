//
//  DatabaseManagerSchemaChangeRoutingTests.swift
//  TableProTests
//
//  Pins the fix for #2015: a table structure save must run its DDL on the connection
//  and database the editing tab owns, never on whichever session was activated last.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private class SchemaRoutingBaseDriver {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

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

private final class SchemaRoutingDriver: SchemaRoutingBaseDriver, PluginDatabaseDriver {
    private(set) var executedQueries: [String] = []
    private(set) var switchedDatabases: [String] = []
    var switchDatabaseError: Error?
    private var schema: String?

    override var supportsSchemas: Bool { true }
    override var currentSchema: String? { schema }

    init(currentSchema: String? = nil) {
        self.schema = currentSchema
        super.init()
    }

    func execute(query: String) async throws -> PluginQueryResult {
        executedQueries.append(query)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func switchDatabase(to database: String) async throws {
        if let switchDatabaseError {
            throw switchDatabaseError
        }
        switchedDatabases.append(database)
    }

    func switchSchema(to schema: String) async throws {
        self.schema = schema
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(qualified(table)) ADD COLUMN `\(column.name)` \(column.dataType)"
    }

    private func qualified(_ table: String) -> String {
        guard let schema, !schema.isEmpty else { return "`\(table)`" }
        return "`\(schema)`.`\(table)`"
    }
}

@Suite("DatabaseManager schema change routing", .serialized)
@MainActor
struct DatabaseManagerSchemaChangeRoutingTests {
    private static func makeAddColumnChange(named name: String = "notes") -> SchemaChange {
        var column = EditableColumnDefinition.placeholder()
        column.name = name
        column.dataType = "TEXT"
        return .addColumn(column)
    }

    private static func makeSession(
        type: DatabaseType = .mysql,
        database: String = "testdb",
        currentDatabase: String? = nil,
        currentSchema: String? = nil
    ) -> (DatabaseConnection, SchemaRoutingDriver) {
        let connection = TestFixtures.makeConnection(database: database, type: type)
        let pluginDriver = SchemaRoutingDriver(currentSchema: currentSchema)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: pluginDriver)
        var session = ConnectionSession(connection: connection, driver: adapter)
        session.currentDatabase = currentDatabase ?? database
        session.currentSchema = currentSchema
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, pluginDriver)
    }

    @Test("Schema changes run on the requested connection, not the last activated one")
    func schemaChangeUsesRequestedConnection() async throws {
        let (connectionA, driverA) = Self.makeSession(database: "alpha")
        let (connectionB, driverB) = Self.makeSession(database: "beta")
        DatabaseManager.shared.lastActiveSessionId = connectionA.id
        defer {
            DatabaseManager.shared.removeSession(for: connectionA.id)
            DatabaseManager.shared.removeSession(for: connectionB.id)
            DatabaseManager.shared.lastActiveSessionId = nil
        }

        try await DatabaseManager.shared.executeSchemaChanges(
            tableName: "orders",
            changes: [Self.makeAddColumnChange()],
            databaseType: .mysql,
            databaseName: "beta",
            schemaName: nil,
            connectionId: connectionB.id
        )

        #expect(driverB.executedQueries.count == 1)
        #expect(driverB.executedQueries.first?.contains("ADD COLUMN") == true)
        #expect(driverA.executedQueries.isEmpty)
    }

    @Test("Schema changes pin the editing tab's database before running any DDL")
    func schemaChangePinsDatabaseFirst() async throws {
        let (connection, driver) = Self.makeSession(database: "orders", currentDatabase: "inventory")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try await DatabaseManager.shared.executeSchemaChanges(
            tableName: "orders",
            changes: [Self.makeAddColumnChange()],
            databaseType: .mysql,
            databaseName: "orders",
            schemaName: nil,
            connectionId: connection.id
        )

        #expect(driver.switchedDatabases == ["orders"])
        #expect(DatabaseManager.shared.session(for: connection.id)?.currentDatabase == "orders")
        #expect(driver.executedQueries.count == 1)
    }

    @Test("Schema changes skip the switch when the session is already on the tab's database")
    func schemaChangeSkipsRedundantSwitch() async throws {
        let (connection, driver) = Self.makeSession(database: "orders")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try await DatabaseManager.shared.executeSchemaChanges(
            tableName: "orders",
            changes: [Self.makeAddColumnChange()],
            databaseType: .mysql,
            databaseName: "orders",
            schemaName: nil,
            connectionId: connection.id
        )

        #expect(driver.switchedDatabases.isEmpty)
        #expect(driver.executedQueries.count == 1)
    }

    @Test("A failed database pin aborts the save before any DDL runs")
    func failedDatabasePinAbortsSave() async throws {
        let (connection, driver) = Self.makeSession(database: "orders", currentDatabase: "inventory")
        driver.switchDatabaseError = DatabaseError.queryFailed("unknown database")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        await #expect(throws: DatabaseError.self) {
            try await DatabaseManager.shared.executeSchemaChanges(
                tableName: "orders",
                changes: [Self.makeAddColumnChange()],
                databaseType: .mysql,
                databaseName: "orders",
                schemaName: nil,
                connectionId: connection.id
            )
        }

        #expect(driver.executedQueries.isEmpty)
    }

    @Test("Engines that need a reconnect to switch database are never switched mid-save")
    func reconnectRequiredEngineIsNotSwitched() async throws {
        let (connection, driver) = Self.makeSession(
            type: .postgresql,
            database: "orders",
            currentDatabase: "inventory"
        )
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try await DatabaseManager.shared.executeSchemaChanges(
            tableName: "orders",
            changes: [Self.makeAddColumnChange()],
            databaseType: .postgresql,
            databaseName: "orders",
            schemaName: nil,
            connectionId: connection.id
        )

        #expect(driver.switchedDatabases.isEmpty)
        #expect(driver.executedQueries.count == 1)
    }

    @Test("A schema-grouped engine keeps the edited table's schema across the database pin")
    func schemaGroupedEngineKeepsTableSchema() async throws {
        let (connection, driver) = Self.makeSession(
            type: .mssql,
            database: "orders",
            currentDatabase: "inventory",
            currentSchema: "sales"
        )
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        try await DatabaseManager.shared.executeSchemaChanges(
            tableName: "orders",
            changes: [Self.makeAddColumnChange()],
            databaseType: .mssql,
            databaseName: "orders",
            schemaName: "sales",
            connectionId: connection.id
        )

        #expect(driver.switchedDatabases == ["orders"])
        #expect(driver.currentSchema == "sales")
        #expect(driver.executedQueries.first?.contains("`sales`.`orders`") == true)
    }
}
