//
//  ConnectionStoragePersistenceTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("ConnectionStorage Persistence")
@MainActor
struct ConnectionStoragePersistenceTests {
    private let storage: ConnectionStorage
    private let syncTracker: SyncChangeTracker
    private let fileURL: URL
    private let defaults: UserDefaults

    init() {
        let unique = UUID().uuidString
        self.fileURL = FileManager.default.temporaryDirectory
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
        self.syncTracker = SyncChangeTracker(metadataStorage: metadata)
        self.storage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: defaults,
            syncTracker: syncTracker,
            keychain: InMemoryKeychain()
        )
    }

    @Test("loading empty storage does not write back")
    func loadEmptyDoesNotWrite() {
        let loaded = storage.loadConnections()
        #expect(loaded.isEmpty)

        let connection = DatabaseConnection(name: "Persistence Test")
        storage.addConnection(connection)

        let reloaded = storage.loadConnections()
        #expect(reloaded.contains { $0.id == connection.id })
    }

    @Test("updateSafeModeLevel writes the new level through to disk")
    func updateSafeModeLevelWritesThrough() {
        let connection = DatabaseConnection(
            name: "Write Through",
            host: "127.0.0.1",
            port: 3_306,
            type: .mysql,
            safeModeLevel: .silent
        )

        storage.addConnection(connection)
        storage.invalidateCache()
        #expect(storage.loadConnections().first { $0.id == connection.id }?.safeModeLevel == .silent)

        let updated = storage.updateSafeModeLevel(.readOnly, for: connection.id)
        #expect(updated)

        storage.invalidateCache()
        let reloaded = storage.loadConnections().first { $0.id == connection.id }
        #expect(reloaded?.safeModeLevel == .readOnly)
    }

    @Test("round-trip save and load preserves connections")
    func roundTripSaveLoad() {
        let connection = DatabaseConnection(
            name: "Round Trip Test",
            host: "127.0.0.1",
            port: 5_432,
            type: .postgresql
        )

        storage.saveConnections([connection])
        let loaded = storage.loadConnections()

        #expect(loaded.count == 1)
        #expect(loaded.first?.id == connection.id)
        #expect(loaded.first?.name == "Round Trip Test")
    }

    @Test("duplicating a connection preserves its password source")
    func duplicatePreservesPasswordSource() {
        var connection = DatabaseConnection(name: "Source", type: .postgresql)
        connection.passwordSource = .file(path: "~/.config/tablepro/db.pw")
        storage.addConnection(connection)

        let duplicate = storage.duplicateConnection(connection)
        #expect(duplicate.id != connection.id)
        #expect(duplicate.passwordSource == .file(path: "~/.config/tablepro/db.pw"))

        let reloaded = storage.loadConnections().first { $0.id == duplicate.id }
        #expect(reloaded?.passwordSource == .file(path: "~/.config/tablepro/db.pw"))
    }

    @Test("connections default to not favorited")
    func defaultsToNotFavorited() {
        let connection = DatabaseConnection(name: "Plain Test")
        storage.saveConnections([connection])
        let loaded = storage.loadConnections()

        #expect(loaded.first?.isFavorite == false)
    }

    @Test("round-trip preserves the isFavorite flag")
    func roundTripPreservesFavorite() {
        var connection = DatabaseConnection(
            name: "Favorite Test",
            host: "127.0.0.1",
            port: 5_432,
            type: .postgresql
        )
        connection.isFavorite = true

        storage.saveConnections([connection])
        let loaded = storage.loadConnections()

        #expect(loaded.first?.isFavorite == true)
    }

    @Test("updateConnections writes batched changes and marks each dirty for sync")
    func updateConnectionsBatchesAndMarksDirty() {
        var first = DatabaseConnection(name: "First", type: .postgresql)
        var second = DatabaseConnection(name: "Second", type: .mysql)
        let untouched = DatabaseConnection(name: "Untouched", type: .sqlite)
        storage.saveConnections([first, second, untouched])

        first.isFavorite = true
        second.name = "Renamed"

        let result = storage.updateConnections([first, second])
        #expect(result == true)

        let loaded = storage.loadConnections()
        #expect(loaded.first(where: { $0.id == first.id })?.isFavorite == true)
        #expect(loaded.first(where: { $0.id == second.id })?.name == "Renamed")
        #expect(loaded.first(where: { $0.id == untouched.id })?.name == "Untouched")

        let dirty = syncTracker.dirtyRecords(for: .connection)
        #expect(dirty.contains(first.id.uuidString))
        #expect(dirty.contains(second.id.uuidString))
        #expect(!dirty.contains(untouched.id.uuidString))
    }

    @Test("updateConnections returns false when no ids match the stored file")
    func updateConnectionsNoMatch() {
        let stored = DatabaseConnection(name: "Stored", type: .postgresql)
        storage.saveConnections([stored])

        let ghost = DatabaseConnection(name: "Ghost", type: .mysql)
        let result = storage.updateConnections([ghost])

        #expect(result == false)
        let loaded = storage.loadConnections()
        #expect(loaded.count == 1)
        #expect(loaded.first?.id == stored.id)
    }

    @Test("updateConnections tolerates duplicate ids in the input batch")
    func updateConnectionsHandlesDuplicateIds() {
        let original = DatabaseConnection(name: "Original", type: .postgresql)
        storage.saveConnections([original])

        var firstCopy = original
        firstCopy.name = "First Edit"
        var secondCopy = original
        secondCopy.name = "Second Edit"

        let result = storage.updateConnections([firstCopy, secondCopy])
        #expect(result == true)

        let loaded = storage.loadConnections()
        #expect(loaded.first?.name == "Second Edit")
    }

    @Test("updateConnections does not mark localOnly or sample connections dirty")
    func updateConnectionsSkipsLocalAndSample() {
        var localOnly = DatabaseConnection(name: "Local", type: .postgresql)
        localOnly.localOnly = true
        var sample = DatabaseConnection(name: "Sample", type: .mysql)
        sample.isSample = true
        var synced = DatabaseConnection(name: "Synced", type: .sqlite)
        storage.saveConnections([localOnly, sample, synced])

        localOnly.isFavorite = true
        sample.isFavorite = true
        synced.isFavorite = true

        let result = storage.updateConnections([localOnly, sample, synced])
        #expect(result == true)

        let dirty = syncTracker.dirtyRecords(for: .connection)
        #expect(dirty.contains(synced.id.uuidString))
        #expect(!dirty.contains(localOnly.id.uuidString))
        #expect(!dirty.contains(sample.id.uuidString))
    }

    @Test("legacy connections.json without isFavorite key decodes as not favorited")
    func decodesLegacyFileWithoutFavoriteKey() throws {
        let legacyJSON = """
        [{
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Legacy Connection",
            "host": "localhost",
            "port": 3306,
            "database": "",
            "username": "root",
            "type": "MySQL",
            "sshEnabled": false,
            "sshHost": "",
            "sshUsername": "",
            "sshAuthMethod": "password",
            "sshPrivateKeyPath": ""
        }]
        """
        try Data(legacyJSON.utf8).write(to: fileURL, options: .atomic)
        storage.invalidateCache()

        let loaded = storage.loadConnections()

        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "Legacy Connection")
        #expect(loaded.first?.isFavorite == false)
    }
}
