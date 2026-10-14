//
//  TableScopedSettingsRegistryTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct TableScopedSettingsRegistryTests {
    @MainActor
    private final class RecordingStore: TableScopedSettingsStore {
        struct DroppedContainer: Equatable {
            let connectionId: UUID
            let database: String
            let schema: String?
        }

        private(set) var purgedConnectionIds: [Set<UUID>] = []
        private(set) var purgedTombstoneFlags: [Bool] = []
        private(set) var droppedTables: [TableScope] = []
        private(set) var droppedContainers: [DroppedContainer] = []

        func renameTable(from oldScope: TableScope, to newScope: TableScope) {}

        func renameContainer(
            connectionId: UUID,
            fromDatabase: String,
            fromSchema: String?,
            toDatabase: String,
            toSchema: String?
        ) {}

        func dropTable(_ scope: TableScope) {
            droppedTables.append(scope)
        }

        func dropContainer(connectionId: UUID, database: String, schema: String?) {
            droppedContainers.append(DroppedContainer(connectionId: connectionId, database: database, schema: schema))
        }

        func purgeConnections(_ connectionIds: Set<UUID>, leavesTombstones: Bool) {
            purgedConnectionIds.append(connectionIds)
            purgedTombstoneFlags.append(leavesTombstones)
        }
    }

    @Test("Deleting a connection purges every table-scoped store once with every id")
    func connectionPurgeReachesEveryStore() {
        let first = RecordingStore()
        let second = RecordingStore()
        let deleted: Set<UUID> = [UUID(), UUID()]

        ConnectionLocalState.purge(
            connectionIds: deleted,
            origin: .remote,
            tableScopedStores: [first, second],
            queryHistory: Self.isolatedQueryHistory()
        )

        #expect(first.purgedConnectionIds == [deleted])
        #expect(second.purgedConnectionIds == [deleted])
    }

    /// A synced store must not tombstone what another device already deleted, or it sends that
    /// device's own deletion back at it.
    @Test("A remote delete purges every store without leaving tombstones")
    func remotePurgeLeavesNoTombstones() {
        let store = RecordingStore()

        ConnectionLocalState.purge(
            connectionIds: [UUID()],
            origin: .remote,
            tableScopedStores: [store],
            queryHistory: Self.isolatedQueryHistory()
        )

        #expect(store.purgedTombstoneFlags == [false])
    }

    @Test("A local delete purges every store and leaves tombstones")
    func localPurgeLeavesTombstones() {
        let store = RecordingStore()

        ConnectionLocalState.purge(
            connectionIds: [UUID()],
            origin: .local,
            tableScopedStores: [store],
            queryHistory: Self.isolatedQueryHistory()
        )

        #expect(store.purgedTombstoneFlags == [true])
    }

    @Test("An empty delete purges nothing")
    func emptyPurgeReachesNoStore() {
        let store = RecordingStore()

        ConnectionLocalState.purge(
            connectionIds: [],
            origin: .remote,
            tableScopedStores: [store],
            queryHistory: Self.isolatedQueryHistory()
        )

        #expect(store.purgedConnectionIds.isEmpty)
    }

    /// `purge` fires its async stores, so a test that injects `tableScopedStores` to stay off the
    /// real ones has to inject this too, or the unstructured task opens the app's own history
    /// database and runs a delete against it while another test is using it.
    private static func isolatedQueryHistory() -> QueryHistoryManager {
        QueryHistoryManager(
            storage: QueryHistoryStorage(
                databaseURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("tablepro-tests")
                    .appendingPathComponent("registry_\(UUID().uuidString).db"),
                removeDatabaseOnDeinit: true
            ),
            isCapturePaused: { false }
        )
    }
}
