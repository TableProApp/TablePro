//
//  DatabaseManagerSchemaChangeRoutingTests.swift
//  TableProTests
//
//  Pins the fix for #2015 and #2026: a table structure save runs its DDL on the scope
//  the editing tab owns, and moving the shared driver there is a mechanical detail no
//  UI reads. The save must not drag the sidebar, the toolbar or the saved default
//  database onto the edited tab's database. And it runs on a connection of its own
//  wherever the engine can pool one, so its BEGIN never joins a transaction a query tab
//  left open on the session driver.
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
    /// An engine that changes database on its live connection but cannot pool a second one,
    /// so a save has nowhere to run but the session driver and has to pin it.
    private static let singleConnectionTypeId = "SchemaRoutingSingleConnection"

    private static var singleConnectionType: DatabaseType {
        registerSingleConnectionTypeIfNeeded()
        return DatabaseType(rawValue: singleConnectionTypeId)
    }

    private static func registerSingleConnectionTypeIfNeeded() {
        guard PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: singleConnectionTypeId) == nil else {
            return
        }
        var capabilities = PluginMetadataSnapshot.CapabilityFlags.defaults
        capabilities.supportsConnectionPooling = false
        let snapshot = PluginMetadataSnapshot(
            displayName: singleConnectionTypeId, iconName: "cylinder", defaultPort: 1_234,
            requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
            isDownloadable: false, primaryUrlScheme: "schemaroutingsingle", parameterStyle: .questionMark,
            navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
            supportsHealthMonitor: false, urlSchemes: ["schemaroutingsingle"], postConnectActions: [],
            brandColorHex: "#000000", queryLanguageName: "SQL", editorLanguage: .sql,
            connectionMode: .network, supportsDatabaseSwitching: true,
            capabilities: capabilities, schema: .defaults, editor: .defaults, connection: .defaults
        )
        PluginMetadataRegistry.shared.register(snapshot: snapshot, forTypeId: singleConnectionTypeId)
    }

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

    /// Stands in for the connection the pool would open on the scope, which the pool puts on
    /// the scope's database and schema before handing it out.
    private static func seedPooledDriver(
        _ connection: DatabaseConnection,
        scope: DatabaseScope
    ) async throws -> SchemaRoutingDriver {
        let pluginDriver = SchemaRoutingDriver(currentSchema: scope.schema)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: pluginDriver)
        try await adapter.connect()
        MetadataConnectionPool.shared.injectEntry(adapter, scope: scope)
        return pluginDriver
    }

    private static func tearDown(_ connections: DatabaseConnection...) {
        for connection in connections {
            MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
            DatabaseManager.shared.removeSession(for: connection.id)
        }
    }

    private static func makeScope(
        _ connection: DatabaseConnection,
        database: String,
        schema: String? = nil
    ) -> DatabaseScope? {
        DatabaseScope(connectionId: connection.id, database: database, schema: schema)
    }

    @Test("A save takes a pooled connection wherever the engine can open one")
    func schemaChangeRouteIsPooledWhereverTheEngineCanPool() throws {
        let (pooling, _) = Self.makeSession(savedDatabase: "orders")
        let (single, _) = Self.makeSession(type: Self.singleConnectionType, savedDatabase: "orders")
        defer { Self.tearDown(pooling, single) }

        let poolingScope = try #require(Self.makeScope(pooling, database: "orders"))
        let singleScope = try #require(Self.makeScope(single, database: "orders"))
        let serverScope = try #require(Self.makeScope(pooling, database: ""))

        #expect(DatabaseManager.shared.schemaChangeRoute(for: poolingScope) == .pooled)
        #expect(DatabaseManager.shared.schemaChangeRoute(for: singleScope) == .sessionDriver)
        #expect(DatabaseManager.shared.schemaChangeRoute(for: serverScope) == .sessionDriver)
    }

    @Test("Schema changes run on the requested connection, not the last activated one")
    func schemaChangeUsesRequestedConnection() async throws {
        let (connectionA, driverA) = Self.makeSession(savedDatabase: "alpha")
        let (connectionB, driverB) = Self.makeSession(savedDatabase: "beta")
        DatabaseManager.shared.lastActiveSessionId = connectionA.id
        defer {
            Self.tearDown(connectionA, connectionB)
            DatabaseManager.shared.lastActiveSessionId = nil
        }

        let scope = try #require(Self.makeScope(connectionB, database: "beta"))
        let pooledB = try await Self.seedPooledDriver(connectionB, scope: scope)
        try await DatabaseManager.shared.executeSchemaChanges(
            tableName: "orders",
            changes: [Self.makeAddColumnChange()],
            databaseType: .mysql,
            scope: scope
        )

        #expect(pooledB.executedQueries.count == 1)
        #expect(pooledB.executedQueries.first?.contains("ADD COLUMN") == true)
        #expect(driverA.executedQueries.isEmpty)
        #expect(driverB.executedQueries.isEmpty)
    }

    /// The session driver holds whatever transaction a query tab left open. A save that ran
    /// there wrapped its DDL in a BEGIN that joined that transaction and a COMMIT that took the
    /// tab's uncommitted work with it, or a ROLLBACK that threw it away.
    @Test("A save runs on the tab's database on its own connection, leaving the session driver alone")
    func schemaChangeRunsOnItsOwnConnectionWithoutMovingTheBrowseCursor() async throws {
        let (connection, driver) = Self.makeSession(
            savedDatabase: "analytics",
            browseDatabase: "inventory"
        )
        defer { Self.tearDown(connection) }

        let scope = try #require(Self.makeScope(connection, database: "orders"))
        let pooled = try await Self.seedPooledDriver(connection, scope: scope)
        try await DatabaseManager.shared.executeSchemaChanges(
            tableName: "orders",
            changes: [Self.makeAddColumnChange()],
            databaseType: .mysql,
            scope: scope
        )

        #expect(pooled.executedQueries.count == 1)
        #expect(driver.executedQueries.isEmpty)
        #expect(driver.switchedDatabases.isEmpty)

        let session = DatabaseManager.shared.session(for: connection.id)
        #expect(session?.browseDatabase == "inventory")
        #expect(session?.connection.database == "analytics")
    }

    @Test("An engine with one connection pins the session driver to the target database")
    func singleConnectionEnginePinsItsTargetDatabase() async throws {
        let (connection, driver) = Self.makeSession(type: Self.singleConnectionType, savedDatabase: "orders")
        defer { Self.tearDown(connection) }

        let scope = try #require(Self.makeScope(connection, database: "orders"))
        try await DatabaseManager.shared.executeSchemaChanges(
            tableName: "orders",
            changes: [Self.makeAddColumnChange()],
            databaseType: Self.singleConnectionType,
            scope: scope
        )

        #expect(!driver.switchedDatabases.isEmpty)
        #expect(driver.switchedDatabases.allSatisfy { $0 == "orders" })
        #expect(driver.executedQueries.count == 1)
    }

    @Test("A failed database pin aborts the save before any DDL runs")
    func failedDatabasePinAbortsSave() async throws {
        let (connection, driver) = Self.makeSession(
            type: Self.singleConnectionType,
            savedDatabase: "orders",
            browseDatabase: "inventory"
        )
        driver.switchDatabaseError = DatabaseError.queryFailed("unknown database")
        defer { Self.tearDown(connection) }

        let scope = try #require(Self.makeScope(connection, database: "orders"))
        await #expect(throws: DatabaseError.self) {
            try await DatabaseManager.shared.executeSchemaChanges(
                tableName: "orders",
                changes: [Self.makeAddColumnChange()],
                databaseType: Self.singleConnectionType,
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
        defer { Self.tearDown(connection) }

        let scope = try #require(Self.makeScope(connection, database: "orders"))
        let pooled = try await Self.seedPooledDriver(connection, scope: scope)
        try await DatabaseManager.shared.executeSchemaChanges(
            tableName: "orders",
            changes: [Self.makeAddColumnChange()],
            databaseType: .postgresql,
            scope: scope
        )

        #expect(driver.switchedDatabases.isEmpty)
        #expect(driver.executedQueries.isEmpty)
        #expect(pooled.executedQueries.count == 1)
    }

    @Test("A schema-grouped engine qualifies the DDL with the edited table's schema")
    func schemaGroupedEngineKeepsTableSchema() async throws {
        let (connection, driver) = Self.makeSession(
            type: .mssql,
            savedDatabase: "orders",
            browseDatabase: "inventory",
            browseSchema: "dbo"
        )
        defer { Self.tearDown(connection) }

        let scope = try #require(Self.makeScope(connection, database: "orders", schema: "sales"))
        let pooled = try await Self.seedPooledDriver(connection, scope: scope)
        try await DatabaseManager.shared.executeSchemaChanges(
            tableName: "orders",
            changes: [Self.makeAddColumnChange()],
            databaseType: .mssql,
            scope: scope
        )

        #expect(pooled.executedQueries.first?.contains("`sales`.`orders`") == true)
        #expect(driver.currentSchema == "dbo")
        #expect(driver.executedQueries.isEmpty)
    }

    @Test("A save broadcasts a refresh scoped to the edited tab, not to the browse cursor")
    func schemaChangeBroadcastsTheEditedScope() async throws {
        let (connection, _) = Self.makeSession(
            savedDatabase: "analytics",
            browseDatabase: "inventory"
        )
        defer { Self.tearDown(connection) }

        let recorder = RefreshRequestRecorder()
        let cancellable = AppCommands.shared.refreshData.sink { request in
            recorder.record(request)
        }
        defer { cancellable.cancel() }

        let scope = try #require(Self.makeScope(connection, database: "orders"))
        _ = try await Self.seedPooledDriver(connection, scope: scope)
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
