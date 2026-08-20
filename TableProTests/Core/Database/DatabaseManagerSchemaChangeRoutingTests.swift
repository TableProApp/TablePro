//
//  DatabaseManagerSchemaChangeRoutingTests.swift
//  TableProTests
//
//  Pins the fix for #2015 and #2026: a table structure save runs its DDL on the scope
//  the editing tab owns, and moving the shared driver there is a mechanical detail no
//  UI reads. The save must not drag the sidebar, the toolbar or the saved default
//  database onto the edited tab's database.
//

import Combine
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

private final class SchemaRoutingDriver: SchemaRoutingBaseDriver, PluginDatabaseDriver, @unchecked Sendable {
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

    /// `savedDatabase` is the connection's persisted default, `browseDatabase` is where the
    /// sidebar currently points. The tab's scope is passed separately at every call site so
    /// all three can be distinguished.
    private static func makeSession(
        type: DatabaseType = .mysql,
        savedDatabase: String = "testdb",
        browseDatabase: String? = nil,
        browseSchema: String? = nil
    ) -> (DatabaseConnection, SchemaRoutingDriver) {
        let connection = TestFixtures.makeConnection(database: savedDatabase, type: type)
        let pluginDriver = SchemaRoutingDriver(currentSchema: browseSchema)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: pluginDriver)
        var session = ConnectionSession(connection: connection, driver: adapter)
        session.browseDatabase = browseDatabase ?? savedDatabase
        session.browseSchema = browseSchema
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, pluginDriver)
    }

    private static func makeScope(
        _ connection: DatabaseConnection,
        database: String,
        schema: String? = nil
    ) -> DatabaseScope? {
        DatabaseScope(connectionId: connection.id, database: database, schema: schema)
    }

    @Test("Schema changes run on the requested connection, not the last activated one")
    func schemaChangeUsesRequestedConnection() async throws {
        let (connectionA, driverA) = Self.makeSession(savedDatabase: "alpha")
        let (connectionB, driverB) = Self.makeSession(savedDatabase: "beta")
        DatabaseManager.shared.lastActiveSessionId = connectionA.id
        defer {
            DatabaseManager.shared.removeSession(for: connectionA.id)
            DatabaseManager.shared.removeSession(for: connectionB.id)
            DatabaseManager.shared.lastActiveSessionId = nil
        }

        let scope = try #require(Self.makeScope(connectionB, database: "beta"))
        try await DatabaseManager.shared.executeSchemaChanges(
            tableName: "orders",
            changes: [Self.makeAddColumnChange()],
            databaseType: .mysql,
            scope: scope
        )

        #expect(driverB.executedQueries.count == 1)
        #expect(driverB.executedQueries.first?.contains("ADD COLUMN") == true)
        #expect(driverA.executedQueries.isEmpty)
    }

    @Test("A save runs on the tab's database without moving the browse cursor")
    func schemaChangeRunsOnTheTabsDatabaseWithoutMovingTheBrowseCursor() async throws {
        let (connection, driver) = Self.makeSession(
            savedDatabase: "analytics",
            browseDatabase: "inventory"
        )
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let scope = try #require(Self.makeScope(connection, database: "orders"))
        try await DatabaseManager.shared.executeSchemaChanges(
            tableName: "orders",
            changes: [Self.makeAddColumnChange()],
            databaseType: .mysql,
            scope: scope
        )

        #expect(driver.switchedDatabases.allSatisfy { $0 == "orders" })
        #expect(!driver.switchedDatabases.isEmpty)
        #expect(driver.executedQueries.count == 1)

        let session = DatabaseManager.shared.session(for: connection.id)
        #expect(session?.browseDatabase == "inventory")
        #expect(session?.connection.database == "analytics")
    }

    @Test("A save always pins its target database because nothing tracks where the driver is")
    func schemaChangeAlwaysPinsItsTargetDatabase() async throws {
        let (connection, driver) = Self.makeSession(savedDatabase: "orders")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let scope = try #require(Self.makeScope(connection, database: "orders"))
        try await DatabaseManager.shared.executeSchemaChanges(
            tableName: "orders",
            changes: [Self.makeAddColumnChange()],
            databaseType: .mysql,
            scope: scope
        )

        #expect(!driver.switchedDatabases.isEmpty)
        #expect(driver.switchedDatabases.allSatisfy { $0 == "orders" })
        #expect(driver.executedQueries.count == 1)
    }

    @Test("A failed database pin aborts the save before any DDL runs")
    func failedDatabasePinAbortsSave() async throws {
        let (connection, driver) = Self.makeSession(
            savedDatabase: "orders",
            browseDatabase: "inventory"
        )
        driver.switchDatabaseError = DatabaseError.queryFailed("unknown database")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let scope = try #require(Self.makeScope(connection, database: "orders"))
        await #expect(throws: DatabaseError.self) {
            try await DatabaseManager.shared.executeSchemaChanges(
                tableName: "orders",
                changes: [Self.makeAddColumnChange()],
                databaseType: .mysql,
                scope: scope
            )
        }

        #expect(driver.executedQueries.isEmpty)
    }

    @Test("Engines that need a reconnect to switch database are never switched mid-save")
    func reconnectRequiredEngineIsNotSwitched() async throws {
        let (connection, driver) = Self.makeSession(
            type: .postgresql,
            savedDatabase: "orders"
        )
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let scope = try #require(Self.makeScope(connection, database: "orders"))
        try await DatabaseManager.shared.executeSchemaChanges(
            tableName: "orders",
            changes: [Self.makeAddColumnChange()],
            databaseType: .postgresql,
            scope: scope
        )

        #expect(driver.switchedDatabases.isEmpty)
        #expect(driver.executedQueries.count == 1)
    }

    @Test("A schema-grouped engine keeps the edited table's schema across the database pin")
    func schemaGroupedEngineKeepsTableSchema() async throws {
        let (connection, driver) = Self.makeSession(
            type: .mssql,
            savedDatabase: "orders",
            browseDatabase: "inventory",
            browseSchema: "sales"
        )
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let scope = try #require(Self.makeScope(connection, database: "orders", schema: "sales"))
        try await DatabaseManager.shared.executeSchemaChanges(
            tableName: "orders",
            changes: [Self.makeAddColumnChange()],
            databaseType: .mssql,
            scope: scope
        )

        #expect(!driver.switchedDatabases.isEmpty)
        #expect(driver.switchedDatabases.allSatisfy { $0 == "orders" })
        #expect(driver.currentSchema == "sales")
        #expect(driver.executedQueries.first?.contains("`sales`.`orders`") == true)
    }

    @Test("A save broadcasts a refresh scoped to the edited tab, not to the browse cursor")
    func schemaChangeBroadcastsTheEditedScope() async throws {
        let (connection, _) = Self.makeSession(
            savedDatabase: "analytics",
            browseDatabase: "inventory"
        )
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let recorder = RefreshRequestRecorder()
        let cancellable = AppCommands.shared.refreshData.sink { request in
            recorder.record(request)
        }
        defer { cancellable.cancel() }

        let scope = try #require(Self.makeScope(connection, database: "orders"))
        try await DatabaseManager.shared.executeSchemaChanges(
            tableName: "orders",
            changes: [Self.makeAddColumnChange()],
            databaseType: .mysql,
            scope: scope
        )

        let broadcast = recorder.requests.filter { $0.connectionId == connection.id }
        #expect(broadcast.count == 1)
        #expect(broadcast.first?.scope == scope)
        #expect(broadcast.first?.scope?.database == "orders")
    }
}

@MainActor
private final class RefreshRequestRecorder {
    private(set) var requests: [DataRefreshRequest] = []

    func record(_ request: DataRefreshRequest) {
        requests.append(request)
    }
}
