//
//  SafeModeMigrationTests.swift
//  TableProTests
//
//  Tests for safeModeLevel persistence and migration from old isReadOnly format.
//

import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing
import TableProSyncTransport

@Suite("SafeModeMigration")
@MainActor
struct SafeModeMigrationTests {
    private let storage: ConnectionStorage
    private let defaults: UserDefaults
    private let tracker: SyncChangeTracker

    init() {
        let unique = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("connections_\(unique).json")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let suiteName = "com.TablePro.tests.ConnectionStorage.\(unique)"
        guard let defaults = UserDefaults(suiteName: suiteName),
              let syncDefaults = UserDefaults(suiteName: "com.TablePro.tests.Sync.\(unique)")
        else {
            fatalError("Failed to create isolated test user defaults")
        }
        self.defaults = defaults
        let metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        self.tracker = SyncChangeTracker(metadataStorage: metadata)
        self.storage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: defaults,
            syncTracker: tracker,
            keychain: InMemoryKeychain()
        )
    }

    // MARK: - Round-Trip Through ConnectionStorage API

    @Test("DatabaseConnection with silent level survives save and load cycle")
    func roundTripSilent() throws {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id, name: "Silent Test", host: "127.0.0.1", port: 3_306,
            database: "test", username: "root", type: .mysql,
            safeModeLevel: .silent
        )

        storage.addConnection(connection)

        let found = storage.loadConnections().first { $0.id == id }
        #expect(found?.safeModeLevel == .silent)
    }

    @Test("DatabaseConnection with alert level survives save and load cycle")
    func roundTripAlert() throws {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id, name: "Alert Test", host: "127.0.0.1", port: 5_432,
            database: "test", username: "postgres", type: .postgresql,
            safeModeLevel: .alert
        )

        storage.addConnection(connection)

        let found = storage.loadConnections().first { $0.id == id }
        #expect(found?.safeModeLevel == .alert)
    }

    @Test("DatabaseConnection with alertFull level survives save and load cycle")
    func roundTripAlertFull() throws {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id, name: "AlertFull Test", host: "127.0.0.1", port: 3_306,
            database: "test", username: "root", type: .mysql,
            safeModeLevel: .alertFull
        )

        storage.addConnection(connection)

        let found = storage.loadConnections().first { $0.id == id }
        #expect(found?.safeModeLevel == .alertFull)
    }

    @Test("DatabaseConnection with safeMode level survives save and load cycle")
    func roundTripSafeMode() throws {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id, name: "SafeMode Test", host: "127.0.0.1", port: 3_306,
            database: "test", username: "root", type: .mysql,
            safeModeLevel: .safeMode
        )

        storage.addConnection(connection)

        let found = storage.loadConnections().first { $0.id == id }
        #expect(found?.safeModeLevel == .safeMode)
    }

    @Test("DatabaseConnection with safeModeFull level survives save and load cycle")
    func roundTripSafeModeFull() throws {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id, name: "SafeModeFull Test", host: "127.0.0.1", port: 3_306,
            database: "test", username: "root", type: .mysql,
            safeModeLevel: .safeModeFull
        )

        storage.addConnection(connection)

        let found = storage.loadConnections().first { $0.id == id }
        #expect(found?.safeModeLevel == .safeModeFull)
    }

    @Test("DatabaseConnection with readOnly level survives save and load cycle")
    func roundTripReadOnly() throws {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id, name: "ReadOnly Test", host: "127.0.0.1", port: 3_306,
            database: "test", username: "root", type: .mysql,
            safeModeLevel: .readOnly
        )

        storage.addConnection(connection)

        let found = storage.loadConnections().first { $0.id == id }
        #expect(found?.safeModeLevel == .readOnly)
    }

    @Test("setSafeModeLevel updates the active session and saved connection default")
    func setSafeModeLevelPersistsUpdatedDefault() {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id,
            name: "Persisted Safe Mode",
            host: "127.0.0.1",
            port: 3_306,
            database: "test",
            username: "root",
            type: .mysql,
            safeModeLevel: .silent
        )

        storage.addConnection(connection)
        tracker.clearDirty(.connection, id: id.uuidString)

        let manager = DatabaseManager(connectionStorage: storage)
        manager.injectSession(ConnectionSession(connection: connection), for: id)
        defer { manager.removeSession(for: id) }

        manager.setSafeModeLevel(.readOnly, for: id)

        let session = manager.session(for: id)
        let saved = storage.loadConnections().first { $0.id == id }

        #expect(session?.safeModeLevel == .readOnly)
        #expect(session?.connection.safeModeLevel == .readOnly)
        #expect(saved?.safeModeLevel == .readOnly)
        #expect(tracker.dirtyRecords(for: .connection).contains(id.uuidString))
    }

    @Test("resolvedConnectionDefinition prefers the persisted safe mode over a stale caller copy")
    func resolvedConnectionDefinitionUsesPersistedSafeMode() {
        let id = UUID()
        let staleConnection = DatabaseConnection(
            id: id,
            name: "Stale Safe Mode",
            host: "127.0.0.1",
            port: 3_306,
            database: "test",
            username: "root",
            type: .mysql,
            safeModeLevel: .silent
        )

        storage.addConnection(staleConnection)

        let manager = DatabaseManager(connectionStorage: storage)
        manager.injectSession(ConnectionSession(connection: staleConnection), for: id)
        manager.setSafeModeLevel(.alertFull, for: id)
        manager.removeSession(for: id)

        let resolved = manager.resolvedConnectionDefinition(for: staleConnection)

        #expect(staleConnection.safeModeLevel == .silent)
        #expect(resolved.safeModeLevel == .alertFull)
    }

    @Test("resolvedConnectionDefinition keeps in-session connection edits and only refreshes safe mode")
    func resolvedConnectionDefinitionPreservesInSessionEdits() {
        let id = UUID()
        let stored = DatabaseConnection(
            id: id,
            name: "Switched Database",
            host: "127.0.0.1",
            port: 5_432,
            database: "original",
            username: "postgres",
            type: .postgresql,
            safeModeLevel: .silent
        )

        storage.addConnection(stored)

        let manager = DatabaseManager(connectionStorage: storage)
        manager.injectSession(ConnectionSession(connection: stored), for: id)
        manager.setSafeModeLevel(.alertFull, for: id)
        manager.removeSession(for: id)

        var inSession = stored
        inSession.database = "switched"

        let resolved = manager.resolvedConnectionDefinition(for: inSession)

        #expect(resolved.database == "switched")
        #expect(resolved.safeModeLevel == .alertFull)
    }

    @Test("A fresh session seeds from the persisted safe mode after disconnect")
    func freshSessionSeedsFromPersistedSafeMode() {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id,
            name: "Reconnect Safe Mode",
            host: "127.0.0.1",
            port: 5_432,
            database: "test",
            username: "postgres",
            type: .postgresql,
            safeModeLevel: .silent
        )

        storage.addConnection(connection)

        let manager = DatabaseManager(connectionStorage: storage)
        manager.injectSession(ConnectionSession(connection: connection), for: id)
        manager.setSafeModeLevel(.alertFull, for: id)
        manager.removeSession(for: id)

        let reloaded = storage.loadConnections().first { $0.id == id }
        let reseededSession = reloaded.map { ConnectionSession(connection: $0) }

        #expect(reloaded?.safeModeLevel == .alertFull)
        #expect(reseededSession?.safeModeLevel == .alertFull)
    }

    @Test("updateSafeModeLevel preserves the saved password and marks sync dirty")
    func updateSafeModeLevelPreservesPasswordAndMarksDirty() {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id,
            name: "Password Preservation",
            host: "127.0.0.1",
            port: 3_306,
            database: "test",
            username: "root",
            type: .mysql,
            safeModeLevel: .silent
        )

        storage.addConnection(connection, password: "secret")
        tracker.clearDirty(.connection, id: id.uuidString)
        defer { storage.deletePassword(for: id) }

        let updated = storage.updateSafeModeLevel(.safeModeFull, for: id)

        #expect(updated)
        #expect(storage.loadPassword(for: id) == "secret")
        #expect(storage.loadConnection(id: id)?.safeModeLevel == .safeModeFull)
        #expect(tracker.dirtyRecords(for: .connection).contains(id.uuidString))
    }

    @Test("updateSafeModeLevel skips sync dirtiness for local-only connections")
    func updateSafeModeLevelSkipsSyncForLocalOnlyConnections() {
        let id = UUID()
        let connection = DatabaseConnection(
            id: id,
            name: "Local Safe Mode",
            host: "127.0.0.1",
            port: 3_306,
            database: "test",
            username: "root",
            type: .mysql,
            safeModeLevel: .silent,
            localOnly: true
        )

        storage.addConnection(connection)
        tracker.clearDirty(.connection, id: id.uuidString)

        let updated = storage.updateSafeModeLevel(.readOnly, for: id)

        #expect(updated)
        #expect(storage.loadConnection(id: id)?.safeModeLevel == .readOnly)
        #expect(!tracker.dirtyRecords(for: .connection).contains(id.uuidString))
    }

    // MARK: - Live Session Reconciliation

    private func makeConnection(id: UUID, name: String, safeModeLevel: SafeModeLevel) -> DatabaseConnection {
        DatabaseConnection(
            id: id,
            name: name,
            host: "127.0.0.1",
            port: 3_306,
            database: "test",
            username: "root",
            type: .mysql,
            safeModeLevel: safeModeLevel
        )
    }

    /// The reconcile used to copy `safeModeLevel` alone, so every other field on a live session
    /// stayed at whatever it was when the connection was opened. `WorkspaceRailStore.resolve` reads
    /// `session.connection` for any live session, so a rename or a recolour was invisible in the
    /// rail until the next reconnect (#2398).
    @Test("A colour picked while the connection is open reaches the open session")
    func reconcileAppliesColorToLiveSession() {
        let id = UUID()
        let connection = makeConnection(id: id, name: "Production", safeModeLevel: .silent)
        storage.addConnection(connection)

        let manager = DatabaseManager(connectionStorage: storage)
        manager.injectSession(ConnectionSession(connection: connection), for: id)
        defer { manager.removeSession(for: id) }

        var edited = connection
        edited.color = .red
        edited.name = "Production (renamed)"
        storage.updateConnection(edited)

        #expect(manager.session(for: id)?.connection.identityColor == nil)

        manager.reconcileStoredRecord(for: id)

        #expect(manager.session(for: id)?.connection.identityColor == .red)
        #expect(manager.session(for: id)?.connection.name == "Production (renamed)")
    }

    /// `reconnectOntoDatabase` builds its reconnect from `session.connection`, so a host, port or
    /// username edit that reached a live session would let the health monitor silently reconnect an
    /// open window to a different server. The reconcile carries display fields only; the connect
    /// target belongs to the next connect the user asks for.
    @Test("The reconcile never moves a live session's connect target")
    func reconcileKeepsConnectTarget() {
        let id = UUID()
        let connection = makeConnection(id: id, name: "Production", safeModeLevel: .silent)
        storage.addConnection(connection)

        let manager = DatabaseManager(connectionStorage: storage)
        var live = connection
        live.database = "analytics"
        manager.injectSession(ConnectionSession(connection: live), for: id)
        defer { manager.removeSession(for: id) }

        var edited = connection
        edited.color = .blue
        edited.host = "production.example.com"
        edited.port = 5_432
        edited.username = "someone_else"
        storage.updateConnection(edited)

        manager.reconcileStoredRecord(for: id)

        let session = manager.session(for: id)
        #expect(session?.connection.identityColor == .blue)
        #expect(session?.connection.host == "127.0.0.1")
        #expect(session?.connection.port == 3_306)
        #expect(session?.connection.username == "root")
        #expect(session?.connection.database == "analytics")
    }

    @Test("An edit saved from the connection form reaches the open session")
    func reconcileAppliesConnectionFormEditToLiveSession() {
        let id = UUID()
        let connection = makeConnection(id: id, name: "Form Edit", safeModeLevel: .readOnly)
        storage.addConnection(connection)

        let manager = DatabaseManager(connectionStorage: storage)
        manager.injectSession(ConnectionSession(connection: connection), for: id)
        defer { manager.removeSession(for: id) }

        var edited = connection
        edited.safeModeLevel = .safeMode
        storage.updateConnection(edited)

        #expect(manager.session(for: id)?.safeModeLevel == .readOnly)

        manager.reconcileStoredRecord(for: id)

        #expect(manager.session(for: id)?.safeModeLevel == .safeMode)
        #expect(manager.session(for: id)?.connection.safeModeLevel == .safeMode)
    }

    @Test("A bulk update with no connection id reconciles every open session")
    func reconcileWithoutIdCoversEveryActiveSession() {
        let firstId = UUID()
        let secondId = UUID()
        let first = makeConnection(id: firstId, name: "First", safeModeLevel: .readOnly)
        let second = makeConnection(id: secondId, name: "Second", safeModeLevel: .readOnly)
        storage.addConnection(first)
        storage.addConnection(second)

        let manager = DatabaseManager(connectionStorage: storage)
        manager.injectSession(ConnectionSession(connection: first), for: firstId)
        manager.injectSession(ConnectionSession(connection: second), for: secondId)
        defer {
            manager.removeSession(for: firstId)
            manager.removeSession(for: secondId)
        }

        var editedFirst = first
        editedFirst.safeModeLevel = .silent
        var editedSecond = second
        editedSecond.safeModeLevel = .alert
        storage.updateConnection(editedFirst)
        storage.updateConnection(editedSecond)

        manager.reconcileStoredRecord(for: nil)

        #expect(manager.session(for: firstId)?.safeModeLevel == .silent)
        #expect(manager.session(for: secondId)?.safeModeLevel == .alert)
    }

    @Test("Reconciling a connection with no open session changes nothing")
    func reconcileIgnoresConnectionsWithoutSession() {
        let id = UUID()
        let connection = makeConnection(id: id, name: "Not Connected", safeModeLevel: .readOnly)
        storage.addConnection(connection)

        let manager = DatabaseManager(connectionStorage: storage)
        manager.reconcileStoredRecord(for: id)

        #expect(manager.session(for: id) == nil)
        #expect(storage.loadConnection(id: id)?.safeModeLevel == .readOnly)
    }

    @Test("A connectionUpdated event reconciles the open session")
    func connectionUpdatedEventReconcilesLiveSession() async {
        let id = UUID()
        let connection = makeConnection(id: id, name: "Event Driven", safeModeLevel: .readOnly)
        storage.addConnection(connection)

        let manager = DatabaseManager(connectionStorage: storage)
        manager.injectSession(ConnectionSession(connection: connection), for: id)
        defer { manager.removeSession(for: id) }

        var edited = connection
        edited.safeModeLevel = .silent
        storage.updateConnection(edited)

        AppEvents.shared.connectionUpdated.send(id)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, manager.session(for: id)?.safeModeLevel != .silent {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(manager.session(for: id)?.safeModeLevel == .silent)
    }

    // MARK: - Default Level

    @Test("New connection defaults to silent safe mode level")
    func defaultLevel() {
        let connection = TestFixtures.makeConnection()
        #expect(connection.safeModeLevel == .silent)
    }
}
