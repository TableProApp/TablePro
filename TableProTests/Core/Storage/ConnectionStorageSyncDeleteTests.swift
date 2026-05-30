//
//  ConnectionStorageSyncDeleteTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("ConnectionStorage sync delete ordering")
@MainActor
struct ConnectionStorageSyncDeleteTests {
    private let storage: ConnectionStorage
    private let metadata: SyncMetadataStorage
    private let storageDirectory: URL

    init() {
        let unique = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("connections_\(unique).json")
        storageDirectory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "com.TablePro.tests.ConnectionStorage.\(unique)")!
        let syncDefaults = UserDefaults(suiteName: "com.TablePro.tests.Sync.\(unique)")!
        metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        storage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: defaults,
            syncTracker: SyncChangeTracker(metadataStorage: metadata)
        )
    }

    @Test("Deleting a connection records a sync tombstone after it is persisted")
    func deleteRecordsTombstoneAfterPersisting() {
        let connection = TestFixtures.makeConnection()
        storage.addConnection(connection)
        #expect(metadata.tombstones(for: .connection).isEmpty)

        storage.deleteConnection(connection)

        #expect(metadata.tombstones(for: .connection).contains { $0.id == connection.id.uuidString })
    }

    @Test("A delete that fails to persist records no tombstone (persist before notify)")
    func failedPersistenceRecordsNoTombstone() {
        let connection = TestFixtures.makeConnection()
        storage.addConnection(connection)
        try? FileManager.default.removeItem(at: storageDirectory)

        storage.deleteConnection(connection)

        #expect(metadata.tombstones(for: .connection).isEmpty)
    }
}
