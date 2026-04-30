//
//  ConnectionStoragePersistenceTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

@Suite("ConnectionStorage Persistence")
@MainActor
struct ConnectionStoragePersistenceTests {
    private let storage: ConnectionStorage
    private let defaults: UserDefaults

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
}
