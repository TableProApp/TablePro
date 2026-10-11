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

        #expect(DatabaseManager.shared.resolvedSchemaName("audit", inDatabase: nil, for: connection.id) == "audit")
    }

    @Test("resolvedSchemaName falls back to the session's current schema")
    func resolvedSchemaNameFallsBackToSessionSchema() {
        let connection = TestFixtures.makeConnection()
        var session = ConnectionSession(connection: connection)
        session.browseSchema = "sales"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseManager.shared.resolvedSchemaName(nil, inDatabase: nil, for: connection.id) == "sales")
    }

    @Test("resolvedSchemaName stays nil without a session")
    func resolvedSchemaNameStaysNilWithoutSession() {
        #expect(DatabaseManager.shared.resolvedSchemaName(nil, inDatabase: nil, for: UUID()) == nil)
    }

    @Test("resolvedSchemaName stays nil for a schema-less session")
    func resolvedSchemaNameStaysNilForSchemaLessSession() {
        let connection = TestFixtures.makeConnection()
        DatabaseManager.shared.injectSession(ConnectionSession(connection: connection), for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseManager.shared.resolvedSchemaName(nil, inDatabase: nil, for: connection.id) == nil)
    }

    @Test("resolvedSchemaName treats a blank explicit schema as absent")
    func resolvedSchemaNameTreatsBlankExplicitSchemaAsAbsent() {
        let connection = TestFixtures.makeConnection()
        var session = ConnectionSession(connection: connection)
        session.browseSchema = "custom"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseManager.shared.resolvedSchemaName("", inDatabase: nil, for: connection.id) == "custom")
    }

    @Test("resolvedSchemaName returns nil rather than a blank session schema")
    func resolvedSchemaNameRejectsBlankSessionSchema() {
        let connection = TestFixtures.makeConnection()
        var session = ConnectionSession(connection: connection)
        session.browseSchema = ""
        DatabaseManager.shared.injectSession(session, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        #expect(DatabaseManager.shared.resolvedSchemaName(nil, inDatabase: nil, for: connection.id) == nil)
    }
}

@Suite("Interactive connection query timeout handoff", .serialized)
@MainActor
struct DatabaseManagerQueryTimeoutHandoffTests {
    @Test("Connection overrides reach the connected driver", arguments: [0, 17])
    func connectionOverrideReachesDriver(queryTimeoutSeconds: Int) async {
        await expectAppliedTimeout(configured: queryTimeoutSeconds, expected: queryTimeoutSeconds)
    }

    @Test("An inherited timeout reaches the connected driver")
    func inheritedTimeoutReachesDriver() async {
        let settings = AppSettingsManager.shared
        let previous = settings.general.queryTimeoutSeconds
        settings.general.queryTimeoutSeconds = 29
        defer { settings.general.queryTimeoutSeconds = previous }

        await expectAppliedTimeout(configured: nil, expected: 29)
    }

    @Test("A successful retry adopts the edited connection for later reconnects")
    func successfulRetryAdoptsEditedConnection() async throws {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        var oldConnection = TestFixtures.makeConnection(name: "Edited retry", type: .mssql)
        oldConnection.host = "old.example.com"
        oldConnection.username = "old-user"
        oldConnection.connectTimeoutSeconds = 1

        let failedDriver = MockDatabaseDriver(connection: oldConnection)
        var failedSession = ConnectionSession(connection: oldConnection, driver: failedDriver)
        failedSession.status = .error("Connection failed")
        failedSession.liveness = .unreachable(ConnectionFailureInfo(message: "Connection failed"))
        DatabaseManager.shared.injectSession(failedSession, for: oldConnection.id)

        var editedConnection = oldConnection
        editedConnection.host = "new.example.com"
        editedConnection.username = "new-user"
        editedConnection.connectTimeoutSeconds = 60
        FakeMSSQLPlugin.recordConfigurations(for: editedConnection.id)

        do {
            try await DatabaseManager.shared.ensureConnected(editedConnection)

            let adopted = try #require(DatabaseManager.shared.session(for: editedConnection.id)?.connection)
            #expect(adopted.host == "new.example.com")
            #expect(adopted.username == "new-user")
            #expect(adopted.connectTimeoutSeconds == 60)

            let reconnect = await DatabaseManager.shared.performHealthMonitorReconnect(
                connectionId: editedConnection.id
            )
            #expect(reconnect == .success)

            let configurations = FakeMSSQLPlugin.configurations(for: editedConnection.id)
            #expect(configurations.count == 2)
            if configurations.count == 2 {
                let retry = configurations[0]
                let laterReconnect = configurations[1]
                #expect(retry.host == "new.example.com")
                #expect(retry.username == "new-user")
                #expect(retry.connectTimeoutSeconds.map { 1...60 ~= $0 } == true)
                #expect(laterReconnect.host == "new.example.com")
                #expect(laterReconnect.username == "new-user")
                #expect(laterReconnect.connectTimeoutSeconds.map { 2...60 ~= $0 } == true)
            }
        } catch {
            await cleanUp(editedConnection.id)
            throw error
        }

        await cleanUp(editedConnection.id)
    }

    @Test("Connect success preserves fields reconciled while the driver was opening")
    func connectSuccessPreservesReconciledFields() async throws {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        let unique = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-session-adoption-\(unique).json")
        let suiteName = "com.TablePro.tests.SessionAdoption.\(unique)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let storage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: defaults,
            keychain: InMemoryKeychain()
        )
        let manager = DatabaseManager(connectionStorage: storage)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: fileURL)
        }

        let originalTag = UUID()
        let reconciledTag = UUID()
        var attempted = TestFixtures.makeConnection(name: "Before rename", type: .mssql)
        attempted.host = "attempted.example.com"
        attempted.color = .red
        attempted.iconName = "cylinder"
        attempted.tagIds = [originalTag]
        attempted.preferredSafeModeLevel = .silent
        attempted.localOnly = true
        storage.addConnection(attempted)

        let connectHold = FakeMSSQLPlugin.holdConnect(for: attempted.id)
        let connectTask = Task { @MainActor in
            try await manager.ensureConnected(attempted)
        }

        do {
            let didReachDriver = try #require(await BoundedCall.result(within: .seconds(2)) {
                await connectHold.waitUntilReached()
                return true
            })
            try #require(didReachDriver)

            var edited = try #require(storage.loadConnection(id: attempted.id))
            edited.name = "Renamed while connecting"
            edited.host = "stored-edit.example.com"
            edited.color = .purple
            edited.iconName = "server.rack"
            edited.tagIds = [reconciledTag]
            edited.preferredSafeModeLevel = .alert
            storage.updateConnection(edited)
            manager.reconcileStoredRecord(for: attempted.id)

            let whileConnecting = try #require(manager.session(for: attempted.id))
            #expect(whileConnecting.connection.name == "Renamed while connecting")
            #expect(whileConnecting.connection.host == "attempted.example.com")
            #expect(whileConnecting.connection.color == .purple)
            #expect(whileConnecting.connection.iconName == "server.rack")
            #expect(whileConnecting.connection.tagIds == [reconciledTag])
            #expect(whileConnecting.connection.preferredSafeModeLevel == .alert)
            #expect(whileConnecting.safeModeLevel == .alert)

            await connectHold.release()
            let didConnect = try #require(await BoundedCall.result(within: .seconds(2)) {
                do {
                    try await connectTask.value
                    return true
                } catch {
                    return false
                }
            })
            try #require(didConnect)

            let connected = try #require(manager.session(for: attempted.id))
            #expect(connected.connection.name == "Renamed while connecting")
            #expect(connected.connection.host == "attempted.example.com")
            #expect(connected.connection.color == .purple)
            #expect(connected.connection.iconName == "server.rack")
            #expect(connected.connection.tagIds == [reconciledTag])
            #expect(connected.connection.preferredSafeModeLevel == .alert)
            #expect(connected.safeModeLevel == .alert)
        } catch {
            await connectHold.release()
            connectTask.cancel()
            await cleanUp(attempted.id, manager: manager)
            throw error
        }

        await cleanUp(attempted.id, manager: manager)
    }

    private func expectAppliedTimeout(configured: Int?, expected: Int) async {
        FakeMSSQLPluginRegistration.registerIfNeeded()
        var connection = TestFixtures.makeConnection(name: "Timeout handoff", type: .mssql)
        connection.queryTimeoutSeconds = configured

        do {
            try await DatabaseManager.shared.ensureConnected(connection)
            if let adapter = DatabaseManager.shared.driver(for: connection.id) as? PluginDriverAdapter,
               let pluginDriver = adapter.schemaPluginDriver as? FakeMSSQLPluginDriver {
                #expect(pluginDriver.applyQueryTimeoutValues == [expected])
                #expect(DatabaseManager.shared.session(for: connection.id)?.effectiveQueryTimeoutSeconds == expected)
            } else {
                Issue.record("The interactive connection did not install the expected plugin driver")
            }
        } catch {
            Issue.record("The interactive connection failed: \(error.localizedDescription)")
        }

        await cleanUp(connection.id)
    }

    private func cleanUp(_ connectionId: UUID, manager: DatabaseManager = .shared) async {
        await manager.stopHealthMonitor(for: connectionId)
        manager.driver(for: connectionId)?.disconnect()
        manager.removeSession(for: connectionId)
        FakeMSSQLPlugin.clearConnectFailure(for: connectionId)
        FakeMSSQLPlugin.clearConnectHold(for: connectionId)
        FakeMSSQLPlugin.clearConfigurations(for: connectionId)
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
