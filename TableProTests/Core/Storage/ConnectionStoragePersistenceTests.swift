//
//  ConnectionStoragePersistenceTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
@testable import TablePro

@Suite("ConnectionStorage Persistence")
@MainActor
struct ConnectionStoragePersistenceTests {
    private let storage: ConnectionStorage
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
        self.defaults = UserDefaults(suiteName: suiteName)!
        let syncDefaults = UserDefaults(suiteName: "com.TablePro.tests.Sync.\(unique)")!
        let metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        self.storage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: defaults,
            syncTracker: tracker
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

    @Test("round-trip save and load preserves connections")
    func roundTripSaveLoad() {
        let connection = DatabaseConnection(
            name: "Round Trip Test",
            host: "127.0.0.1",
            port: 5432,
            type: .postgresql
        )

        storage.saveConnections([connection])
        let loaded = storage.loadConnections()

        #expect(loaded.count == 1)
        #expect(loaded.first?.id == connection.id)
        #expect(loaded.first?.name == "Round Trip Test")
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
