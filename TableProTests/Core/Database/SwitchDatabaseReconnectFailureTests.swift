//
//  SwitchDatabaseReconnectFailureTests.swift
//  TableProTests
//
//  An engine that reopens its connection to change database used to report a failed switch as a
//  success: the reconnect swallowed every error into session status, so the caller persisted the
//  unreachable database as the connection's default and the window showed no error at all.
//

import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Switch database reconnect failure", .serialized)
@MainActor
struct SwitchDatabaseReconnectFailureTests {
    /// A type that reopens its connection to change database, and whose driver plugin is not
    /// registered, so the reconnect fails on its first step with no network and no waiting.
    private static let typeId = "ReconnectSwitchFake"

    private func registerTypeIfNeeded() {
        guard PluginMetadataRegistry.shared.snapshot(forTypeId: Self.typeId) == nil else { return }
        var capabilities = PluginMetadataSnapshot.CapabilityFlags.defaults
        capabilities = PluginMetadataSnapshot.CapabilityFlags(
            supportsSchemaSwitching: true,
            supportsImport: capabilities.supportsImport,
            supportsExport: capabilities.supportsExport,
            supportsSSH: capabilities.supportsSSH,
            supportsSSL: capabilities.supportsSSL,
            supportsCascadeDrop: capabilities.supportsCascadeDrop,
            supportsForeignKeyDisable: capabilities.supportsForeignKeyDisable,
            supportsReadOnlyMode: capabilities.supportsReadOnlyMode,
            supportsQueryProgress: capabilities.supportsQueryProgress,
            requiresReconnectForDatabaseSwitch: true,
            supportsDropDatabase: capabilities.supportsDropDatabase
        )
        let snapshot = PluginMetadataSnapshot(
            displayName: Self.typeId, iconName: "cylinder", defaultPort: 1_234,
            requiresAuthentication: true, supportsForeignKeys: true, supportsSchemaEditing: true,
            isDownloadable: false, primaryUrlScheme: "reconnectswitchfake", parameterStyle: .questionMark,
            navigationModel: .standard, explainVariants: [], pathFieldRole: .database,
            supportsHealthMonitor: false, urlSchemes: ["reconnectswitchfake"], postConnectActions: [],
            brandColorHex: "#000000", queryLanguageName: "SQL", editorLanguage: .sql,
            connectionMode: .network, supportsDatabaseSwitching: true,
            supportsColumnReorder: false,
            capabilities: capabilities, schema: .defaults, editor: .defaults, connection: .defaults
        )
        PluginMetadataRegistry.shared.register(snapshot: snapshot, forTypeId: Self.typeId)
    }

    /// The session carries a driver on purpose. Without one `switchDatabase` refuses at its
    /// `notConnected` guard and never reaches the reconnect branch, so every assertion below
    /// would pass against the unfixed code while proving nothing.
    private func makeSession() -> DatabaseConnection {
        registerTypeIfNeeded()
        var connection = TestFixtures.makeConnection(database: "app")
        connection.type = DatabaseType(rawValue: Self.typeId)
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        session.browseDatabase = "app"
        session.browseSchema = "reporting"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        AppSettingsStorage.shared.saveLastSchema("reporting", for: connection.id)
        return connection
    }

    /// The fake type lives in the process-global registry, so it is withdrawn here rather than
    /// left for whatever runs next in the same process.
    private func cleanUp(_ connectionId: UUID) {
        DatabaseManager.shared.removeSession(for: connectionId)
        AppSettingsStorage.shared.saveLastDatabase(nil, for: connectionId)
        AppSettingsStorage.shared.saveLastSchema(nil, for: connectionId)
        PluginMetadataRegistry.shared.unregister(typeId: Self.typeId)
    }

    /// Proves the reconnect branch is the one under test: the guard the previous version of this
    /// suite tripped over would have thrown before any of it ran.
    @Test("The failing switch really reaches the reconnect branch")
    func reachesTheReconnectBranch() async {
        let connection = makeSession()
        defer { cleanUp(connection.id) }

        try? await DatabaseManager.shared.switchDatabase(
            to: "unreachable", for: connection.id, persist: false
        )

        /// Only the reconnect branch invalidates the schema cache and moves the session off
        /// `.connected`, so a status that moved is proof the branch ran.
        #expect(DatabaseManager.shared.session(for: connection.id)?.status != .connected)
    }

    // MARK: - The switch is reported as a failure

    @Test("A database switch whose reconnect fails throws instead of reporting success")
    func failedReconnectThrows() async {
        let connection = makeSession()
        defer { cleanUp(connection.id) }

        await #expect(throws: (any Error).self) {
            try await DatabaseManager.shared.switchDatabase(
                to: "unreachable", for: connection.id, persist: false
            )
        }
    }

    @Test("A failed switch never announces a container change")
    func failedSwitchAnnouncesNothing() async {
        let connection = makeSession()
        defer { cleanUp(connection.id) }

        var announced: [UUID] = []
        let cancellable = AppEvents.shared.browseContainerChanged.sink { announced.append($0) }
        defer { cancellable.cancel() }

        try? await DatabaseManager.shared.switchDatabase(
            to: "unreachable", for: connection.id, persist: false
        )

        #expect(announced.isEmpty)
    }

    // MARK: - The session is left describing the database it still has

    /// Without the rollback the connection stays pinned to the database it could not open, so the
    /// next reconnect and the next launch both aim at it again.
    @Test("A failed switch leaves the connection on the database it came from")
    func failedSwitchRestoresTheConnectionDatabase() async {
        let connection = makeSession()
        defer { cleanUp(connection.id) }

        try? await DatabaseManager.shared.switchDatabase(
            to: "unreachable", for: connection.id, persist: false
        )

        let session = DatabaseManager.shared.session(for: connection.id)
        #expect(session?.connection.database == "app")
        #expect(session?.browseDatabase == "app")
        #expect(session?.browseSchema == "reporting")
        #expect(AppSettingsStorage.shared.loadLastSchema(for: connection.id) == "reporting")
    }

    @Test("A failed switch does not save the unreachable database as the default")
    func failedSwitchDoesNotPersist() async {
        let connection = makeSession()
        defer { cleanUp(connection.id) }

        try? await DatabaseManager.shared.switchDatabase(
            to: "unreachable", for: connection.id, persist: true
        )

        #expect(AppSettingsStorage.shared.loadLastDatabase(for: connection.id) != "unreachable")
    }
}
