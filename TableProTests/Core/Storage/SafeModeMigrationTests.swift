//
//  SafeModeMigrationTests.swift
//  TableProTests
//
//  Tests for safeModeLevel persistence and migration from old isReadOnly format.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

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

    // MARK: - Default Level

    @Test("New connection defaults to silent safe mode level")
    func defaultLevel() {
        let connection = TestFixtures.makeConnection()
        #expect(connection.safeModeLevel == .silent)
    }
}
