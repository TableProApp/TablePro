//
//  RecentConnectionsRecorderTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
@Suite("Recent connections recorder")
struct RecentConnectionsRecorderTests {
    private let defaults: UserDefaults
    private let appEvents = AppEvents()
    private let storage: ConnectionStorage
    private let store: RecentConnectionsStore
    private let recorder: RecentConnectionsRecorder

    init() throws {
        let unique = UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.RecentConnections.\(unique)"))
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("recent-connections_\(unique).json")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        storage = ConnectionStorage(
            fileURL: fileURL,
            userDefaults: defaults,
            syncTracker: SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: defaults))
        )
        store = RecentConnectionsStore(defaults: defaults, appEvents: appEvents)
        recorder = RecentConnectionsRecorder(store: store, connectionStorage: storage, appEvents: appEvents)
    }

    @Test("A saved connection that connects is recorded")
    func recordsConnected() {
        let prod = DatabaseConnection(name: "Prod", type: .mysql)
        storage.addConnection(prod)

        recorder.handle(ConnectionStatusChange(connectionId: prod.id, status: .connected))

        #expect(store.lastConnected[prod.id] != nil)
    }

    @Test("A connect that has not finished, or a connection that is not saved, is not recorded")
    func ignoresOthers() {
        let prod = DatabaseConnection(name: "Prod", type: .mysql)
        storage.addConnection(prod)

        recorder.handle(ConnectionStatusChange(connectionId: prod.id, status: .connecting))
        recorder.handle(ConnectionStatusChange(connectionId: UUID(), status: .connected))

        #expect(store.lastConnected.isEmpty)
    }

    @Test("Started, the recorder follows the status events")
    func followsEvents() {
        let prod = DatabaseConnection(name: "Prod", type: .mysql)
        storage.addConnection(prod)
        recorder.start()

        appEvents.connectionStatusChanged.send(ConnectionStatusChange(connectionId: prod.id, status: .connected))

        #expect(store.lastConnected[prod.id] != nil)
    }

    @Test("Recent connections survive a relaunch and are kept on this Mac")
    func persists() {
        let id = UUID()
        store.record(id, at: Date(timeIntervalSince1970: 42))

        let relaunched = RecentConnectionsStore(defaults: defaults, appEvents: AppEvents())

        #expect(relaunched.lastConnected[id] == Date(timeIntervalSince1970: 42))
    }
}
