//
//  ConnectionStorageRemoveTagTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ConnectionStorage removeTagId")
@MainActor
struct ConnectionStorageRemoveTagTests {
    private let storage: ConnectionStorage

    init() {
        let unique = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("connections_\(unique).json")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let defaultsName = "com.TablePro.tests.ConnectionStorage.RemoveTag.\(unique)"
        let syncName = "com.TablePro.tests.Sync.RemoveTag.\(unique)"
        guard let defaults = UserDefaults(suiteName: defaultsName),
              let syncDefaults = UserDefaults(suiteName: syncName) else {
            fatalError("UserDefaults suite creation failed in test setup")
        }
        let metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        self.storage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: defaults,
            syncTracker: tracker
        )
    }

    private func connection(name: String, tagIds: [UUID]) -> DatabaseConnection {
        var connection = DatabaseConnection(name: name, type: .postgresql)
        connection.tagIds = tagIds
        return connection
    }

    @Test("removeTagId clears the tag from every connection that referenced it")
    func clearsFromAllConnections() {
        let shared = UUID()
        let other = UUID()
        let conn1 = connection(name: "A", tagIds: [shared, other])
        let conn2 = connection(name: "B", tagIds: [shared])
        let conn3 = connection(name: "C", tagIds: [other])
        storage.addConnection(conn1)
        storage.addConnection(conn2)
        storage.addConnection(conn3)

        storage.removeTagId(shared)

        let loaded = storage.loadConnections()
        #expect(loaded.first { $0.id == conn1.id }?.tagIds == [other])
        #expect(loaded.first { $0.id == conn2.id }?.tagIds.isEmpty == true)
        #expect(loaded.first { $0.id == conn3.id }?.tagIds == [other])
    }

    @Test("removeTagId is a no-op when no connection uses the tag")
    func noOpWhenUnused() {
        let conn = connection(name: "A", tagIds: [UUID()])
        storage.addConnection(conn)

        let result = storage.removeTagId(UUID())

        #expect(result)
        #expect(storage.loadConnections().first { $0.id == conn.id }?.tagIds.count == 1)
    }
}
