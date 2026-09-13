//
//  SwitchDatabasePooledConnectionTests.swift
//  TableProTests
//
//  A database switch on an engine that reconnects to perform one used to close every pooled
//  connection the connection held. A table tab on another database that was dialing one lost its
//  open and showed nothing, and idle pooled connections to other databases were closed for a switch
//  that never touched them.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Switch database and pooled connections", .serialized)
@MainActor
struct SwitchDatabasePooledConnectionTests {
    /// Reopens its connection to change database and has no driver plugin registered, so every switch
    /// reaches the reconnect and fails there with no network and no waiting.
    private static let typeId = "PooledSwitchReconnectFake"

    private func registerTypeIfNeeded() {
        guard PluginMetadataRegistry.shared.snapshot(forRegisteredTypeId: Self.typeId) == nil else { return }
        let defaults = PluginMetadataSnapshot.CapabilityFlags.defaults
        let capabilities = PluginMetadataSnapshot.CapabilityFlags(
            supportsSchemaSwitching: true,
            supportsImport: defaults.supportsImport,
            supportsExport: defaults.supportsExport,
            supportsSSH: defaults.supportsSSH,
            supportsSSL: defaults.supportsSSL,
            supportsCascadeDrop: defaults.supportsCascadeDrop,
            supportsForeignKeyDisable: defaults.supportsForeignKeyDisable,
            supportsReadOnlyMode: defaults.supportsReadOnlyMode,
            supportsQueryProgress: defaults.supportsQueryProgress,
            requiresReconnectForDatabaseSwitch: true,
            supportsDropDatabase: defaults.supportsDropDatabase
        )
        let snapshot = PluginMetadataSnapshot(
            displayName: Self.typeId, iconName: "cylinder", defaultPort: 1_234,
            requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
            isDownloadable: false, primaryUrlScheme: "pooledswitchfake", parameterStyle: .questionMark,
            navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
            supportsHealthMonitor: false, urlSchemes: ["pooledswitchfake"], postConnectActions: [],
            brandColorHex: "#000000", queryLanguageName: "SQL", editorLanguage: .sql,
            connectionMode: .network, supportsDatabaseSwitching: true,
            capabilities: capabilities, schema: .defaults, editor: .defaults, connection: .defaults
        )
        PluginMetadataRegistry.shared.register(snapshot: snapshot, forTypeId: Self.typeId)
    }

    /// A direct connection, with no tunnel of any kind, browsing `app`.
    private func makeSession(stoppedAnswering: Bool = false) -> DatabaseConnection {
        registerTypeIfNeeded()
        var connection = TestFixtures.makeConnection(database: "app")
        connection.type = DatabaseType(rawValue: Self.typeId)
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        session.browseDatabase = "app"
        if stoppedAnswering {
            session.liveness = .unreachable(nil)
        }
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection
    }

    /// Stands in for the pooled connection a table tab on `reports` opened.
    private func seedPooledConnection(for connectionId: UUID) -> MockDatabaseDriver {
        let pooled = MockDatabaseDriver()
        MetadataConnectionPool.shared.injectEntry(
            pooled,
            scope: DatabaseScope(connectionId: connectionId, database: "reports", schema: nil)
        )
        return pooled
    }

    private func cleanUp(_ connectionId: UUID) {
        MetadataConnectionPool.shared.closeAll(connectionId: connectionId)
        DatabaseManager.shared.removeSession(for: connectionId)
        AppSettingsStorage.shared.saveLastDatabase(nil, for: connectionId)
        AppSettingsStorage.shared.saveLastSchema(nil, for: connectionId)
        PluginMetadataRegistry.shared.unregister(typeId: Self.typeId)
    }

    @Test("A switch over a direct connection leaves the pooled connection to another database open")
    func switchLeavesOtherDatabasesPooled() async {
        let connection = makeSession()
        defer { cleanUp(connection.id) }
        let pooled = seedPooledConnection(for: connection.id)

        try? await DatabaseManager.shared.switchDatabase(to: "unreachable", for: connection.id, persist: false)

        /// Only the reconnect branch moves the session off `.connected`, so this proves it ran.
        #expect(DatabaseManager.shared.session(for: connection.id)?.status != .connected)
        #expect(MetadataConnectionPool.shared.pooledDriverCount(for: connection.id) == 1)
        #expect(pooled.disconnectCallCount == 0)
        #expect(!MetadataConnectionPool.shared.isReplacingTransport(for: connection.id))
    }

    /// A session that had stopped answering has most likely lost its pooled connections too, so a
    /// switch that reconnects it is a recovery and still clears them, and releases the pool again when
    /// the reconnect fails.
    @Test("A switch that reconnects a connection that stopped answering closes its pooled connections")
    func recoveringSwitchClosesThePool() async {
        let connection = makeSession(stoppedAnswering: true)
        defer { cleanUp(connection.id) }
        let pooled = seedPooledConnection(for: connection.id)

        try? await DatabaseManager.shared.switchDatabase(to: "unreachable", for: connection.id, persist: false)

        #expect(DatabaseManager.shared.session(for: connection.id)?.status != .connected)
        #expect(MetadataConnectionPool.shared.pooledDriverCount(for: connection.id) == 0)
        #expect(pooled.disconnectCallCount == 1)
        #expect(!MetadataConnectionPool.shared.isReplacingTransport(for: connection.id))
    }

    @Test("A background reconnect closes the pooled connections and releases the pool when it is done")
    func healthReconnectClosesThePool() async {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        var connection = TestFixtures.makeConnection(name: "Prod")
        connection.type = DatabaseType(rawValue: FakeMSSQLPlugin.databaseTypeId)
        var session = ConnectionSession(connection: connection)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let pooled = seedPooledConnection(for: connection.id)

        _ = await DatabaseManager.shared.performHealthMonitorReconnect(connectionId: connection.id)

        #expect(MetadataConnectionPool.shared.pooledDriverCount(for: connection.id) == 0)
        #expect(pooled.disconnectCallCount == 1)
        #expect(!MetadataConnectionPool.shared.isReplacingTransport(for: connection.id))
        MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
        await SchemaService.shared.invalidate(connectionId: connection.id)
    }

    @Test("The sidebar's reconnect handling leaves pooled connections to the transport's owner")
    func treeReconnectLeavesThePool() async {
        let connectionId = UUID()
        let pooled = seedPooledConnection(for: connectionId)
        defer { MetadataConnectionPool.shared.closeAll(connectionId: connectionId) }

        await DatabaseTreeMetadataService.shared.handleReconnect(connectionId: connectionId)

        #expect(MetadataConnectionPool.shared.pooledDriverCount(for: connectionId) == 1)
        #expect(pooled.disconnectCallCount == 0)
    }
}
