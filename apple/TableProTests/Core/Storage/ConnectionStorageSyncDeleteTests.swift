//
//  ConnectionStorageSyncDeleteTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing
import TableProSyncTransport

@testable import TablePro

@MainActor
struct ConnectionStorageSyncDeleteTests {
    private let pool = EphemeralDefaultsPool()
    private let storage: ConnectionStorage
    private let journal = SyncJournalRecorder()
    private let storageDirectory: URL

    init() throws {
        let unique = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent(unique)
            .appendingPathComponent("connections.json")
        storageDirectory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        let defaults = try pool.make().defaults
        storage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: defaults,
            syncJournal: journal.journal
        )
    }

    @Test("Deleting a connection journals its deletion after it is persisted")
    func deleteRecordsTombstoneAfterPersisting() {
        let connection = TestFixtures.makeConnection()
        storage.addConnection(connection)
        #expect(journal.tombstones(for: .connection).isEmpty)

        storage.deleteConnection(connection)

        #expect(journal.tombstones(for: .connection).contains { $0.id == connection.id.uuidString })
    }

    @Test("A delete that fails to persist journals nothing")
    func failedPersistenceRecordsNoTombstone() throws {
        let connection = TestFixtures.makeConnection()
        storage.addConnection(connection)
        try LibraryWriteRefusal.set(true, in: storageDirectory)
        defer { try? LibraryWriteRefusal.set(false, in: storageDirectory) }

        storage.deleteConnection(connection)

        #expect(journal.tombstones(for: .connection).isEmpty)
    }
}
