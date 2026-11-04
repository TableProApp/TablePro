//
//  RewindAvailabilityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

struct RewindAvailabilityTests {
    private let connectionId = UUID()
    private let cipher = RewindCipher(keychain: InMemoryKeychain())

    private func makeStorage() -> QueryHistoryStorage {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rewind-availability-\(UUID().uuidString).db")
        return QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
    }

    private func makeRecord(
        table: String = "users",
        historyId: UUID? = nil,
        capturedAt: Date = Date()
    ) -> RewindRecord {
        let target = DataWriteTarget(database: "shop", schema: nil, table: table)
        return RewindRecord(
            id: UUID(),
            historyId: historyId,
            connectionId: connectionId,
            databaseType: .sqlite,
            target: target,
            capturedAt: capturedAt,
            generatedColumns: [],
            identityColumns: [],
            operations: [
                RowWriteOperation(
                    kind: .update,
                    target: target,
                    columns: ["id", "name"],
                    primaryKeyColumns: ["id"],
                    preImage: ["7", "Ada"],
                    postImage: ["7", "Grace"],
                    writtenColumns: ["name"],
                    refusal: nil
                ),
            ]
        )
    }

    private func target(_ table: String = "users") -> RewindAvailability.Target {
        RewindAvailability.Target(connectionId: connectionId, database: "shop", schema: nil, table: table)
    }

    @Test("A kept save is known by its table and its history row, without reading the payload")
    func availabilityListsTargetAndHistoryRow() async {
        let storage = makeStorage()
        let historyId = UUID()
        #expect(await storage.record(TestFixtures.makeHistoryEntry(
            id: historyId, connectionId: connectionId, databaseName: "shop", source: .rowEdit
        )))
        #expect(await storage.recordRewindSnapshot(makeRecord(historyId: historyId), cipher: cipher))

        let availability = await storage.rewindAvailability()
        #expect(availability.targets == [target()])
        #expect(availability.historyIds == [historyId])
    }

    @Test("A subscriber hears the current state, then every write, delete and clear after it commits")
    func updatesFollowEveryChange() async throws {
        let storage = makeStorage()
        var updates = await storage.rewindAvailabilityUpdates().makeAsyncIterator()
        let initial = try #require(await updates.next())
        #expect(initial.targets.isEmpty)

        let record = makeRecord()
        await storage.recordRewindSnapshot(record, cipher: cipher)
        let written = try #require(await updates.next())
        #expect(written.targets == [target()])
        #expect(written.revision > initial.revision)

        await storage.recordRewindSnapshot(makeRecord(table: "orders"), cipher: cipher)
        _ = await updates.next()
        await storage.deleteRewindSnapshot(id: record.id)
        let deleted = try #require(await updates.next())
        #expect(deleted.targets == [target("orders")])

        await storage.clearRewindSnapshots()
        let cleared = try #require(await updates.next())
        #expect(cleared.targets.isEmpty)
    }

    @Test("Retention pruning a save publishes that it is gone")
    func pruningPublishes() async throws {
        let storage = makeStorage()
        let now = Date()
        await storage.recordRewindSnapshot(
            makeRecord(capturedAt: now.addingTimeInterval(-30 * 24 * 60 * 60)), cipher: cipher
        )
        var updates = await storage.rewindAvailabilityUpdates().makeAsyncIterator()
        let kept = try #require(await updates.next())
        #expect(kept.targets == [target()])

        await storage.pruneRewindSnapshots(now: now)
        let pruned = try #require(await updates.next())
        #expect(pruned.targets.isEmpty)
    }

    @Test("Deleting a connection's history publishes that its saves are gone")
    func deletingTheConnectionPublishes() async throws {
        let storage = makeStorage()
        await storage.recordRewindSnapshot(makeRecord(), cipher: cipher)
        var updates = await storage.rewindAvailabilityUpdates().makeAsyncIterator()
        let kept = try #require(await updates.next())
        #expect(kept.targets == [target()])

        await storage.deleteEverything(forConnection: connectionId)
        let deleted = try #require(await updates.next())
        #expect(deleted.targets.isEmpty)
    }

    @Test("A save written after its history row is picked up without the drawer reloading")
    @MainActor
    func snapshotWrittenAfterHistoryRowIsPickedUp() async throws {
        let storage = makeStorage()
        let manager = QueryHistoryManager(storage: storage, isCapturePaused: { false })
        let cache = manager.rewindAvailability
        let historyId = UUID()

        #expect(await manager.record(TestFixtures.makeHistoryEntry(
            id: historyId, connectionId: connectionId, databaseName: "shop", source: .rowEdit
        )))
        try await waitUntil { cache.availability.revision >= 0 }
        #expect(!cache.hasSnapshot(forHistoryId: historyId))

        await storage.recordRewindSnapshot(makeRecord(historyId: historyId), cipher: cipher)
        try await waitUntil { cache.hasSnapshot(forHistoryId: historyId) }
        #expect(cache.hasSnapshot(for: target()))
    }

    @Test("An older reading never replaces a newer one")
    @MainActor
    func olderReadingIsIgnored() {
        let cache = RewindAvailabilityCache(storage: makeStorage())
        cache.adopt(RewindAvailability(revision: 5, targets: [target()], historyIds: []))
        cache.adopt(RewindAvailability(revision: 4, targets: [], historyIds: []))
        #expect(cache.hasSnapshot(for: target()))
    }
}
