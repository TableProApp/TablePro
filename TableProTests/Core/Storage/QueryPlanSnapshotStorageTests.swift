//
//  QueryPlanSnapshotStorageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Saved query plans")
struct QueryPlanSnapshotStorageTests {
    // MARK: - Identity

    /// The whole point of keying on the fingerprint: a user who reformats the statement, or runs it
    /// with a different literal, still sees the plan they ran before the index.
    @Test("A reformatted statement finds the earlier plan")
    func reformattedStatementFindsEarlierPlan() async {
        let store = TemporaryQueryHistoryStore()
        let first = await store.record(subjectSQL: "SELECT * FROM users WHERE id = 1", rawPlan: "old")
        let second = await store.identity(subjectSQL: "select *\n  from users\n where id = 2")

        let found = await store.storage.planSnapshots(matching: second, excluding: nil, limit: 10)
        #expect(found.map(\.id) == [first])
    }

    @Test("A different statement does not")
    func differentStatementDoesNotMatch() async {
        let store = TemporaryQueryHistoryStore()
        _ = await store.record(subjectSQL: "SELECT * FROM users", rawPlan: "old")
        let other = await store.identity(subjectSQL: "SELECT * FROM orders")

        let found = await store.storage.planSnapshots(matching: other, excluding: nil, limit: 10)
        #expect(found.isEmpty)
    }

    /// `EXPLAIN` and `EXPLAIN ANALYZE` describe the same statement but report different things, so
    /// one must never be offered as a baseline for the other.
    @Test("Switching EXPLAIN variant starts a separate chain")
    func variantsAreSeparateChains() async {
        let store = TemporaryQueryHistoryStore()
        _ = await store.record(subjectSQL: "SELECT 1", rawPlan: "plain", variantKey: .declared("explain"))
        let analyzed = await store.identity(subjectSQL: "SELECT 1", variantKey: .declared("analyze"))

        let found = await store.storage.planSnapshots(matching: analyzed, excluding: nil, limit: 10)
        #expect(found.isEmpty)
    }

    @Test("The run doing the asking is excluded from its own baselines")
    func excludesTheAskingRun() async {
        let store = TemporaryQueryHistoryStore()
        let older = await store.record(subjectSQL: "SELECT 1", rawPlan: "older")
        let newer = await store.record(subjectSQL: "SELECT 1", rawPlan: "newer")
        let identity = await store.identity(subjectSQL: "SELECT 1")

        let found = await store.storage.planSnapshots(matching: identity, excluding: newer, limit: 10)
        #expect(found.map(\.id) == [older])
    }

    @Test("Baselines come back newest first")
    func baselinesAreNewestFirst() async {
        let store = TemporaryQueryHistoryStore()
        let older = await store.record(subjectSQL: "SELECT 1", rawPlan: "a", capturedAt: Date(timeIntervalSince1970: 100))
        let newer = await store.record(subjectSQL: "SELECT 1", rawPlan: "b", capturedAt: Date(timeIntervalSince1970: 200))
        let identity = await store.identity(subjectSQL: "SELECT 1")

        let found = await store.storage.planSnapshots(matching: identity, excluding: nil, limit: 10)
        #expect(found.map(\.id) == [newer, older])
    }

    @Test("The plan text is loaded on demand, not with the list")
    func rawTextLoadsOnDemand() async {
        let store = TemporaryQueryHistoryStore()
        let id = await store.record(subjectSQL: "SELECT 1", rawPlan: "the whole plan")

        #expect(await store.storage.planSnapshotRawText(id: id) == "the whole plan")
        #expect(await store.storage.planSnapshotRawText(id: UUID()) == nil)
    }

    // MARK: - Lifetime

    /// A plan is an artifact the user keeps, not a child of a history row. History retention must
    /// not take it with it.
    @Test("Deleting the originating history row keeps the plan")
    func historyDeletionKeepsThePlan() async {
        let store = TemporaryQueryHistoryStore()
        let id = await store.record(subjectSQL: "SELECT 1", rawPlan: "kept")
        let historyId = await store.lastHistoryId

        #expect(await store.storage.delete(id: historyId))
        #expect(await store.storage.planSnapshotRawText(id: id) == "kept")
    }

    @Test("Clearing all history keeps the plans")
    func clearingHistoryKeepsThePlans() async {
        let store = TemporaryQueryHistoryStore()
        let id = await store.record(subjectSQL: "SELECT 1", rawPlan: "kept")

        #expect(await store.storage.clear(matching: QueryHistoryFilter(scope: .all)))
        #expect(await store.storage.planSnapshotRawText(id: id) == "kept")
    }

    @Test("Pruning drops the oldest plans first")
    func pruningDropsOldestFirst() async {
        let store = TemporaryQueryHistoryStore()
        let oldest = await store.record(
            subjectSQL: "SELECT 1", rawPlan: String(repeating: "a", count: 1_000),
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        let newest = await store.record(
            subjectSQL: "SELECT 1", rawPlan: String(repeating: "b", count: 1_000),
            capturedAt: Date(timeIntervalSince1970: 200)
        )

        #expect(await store.storage.prunePlanSnapshots(toByteLimit: 1_500))
        #expect(await store.storage.planSnapshotRawText(id: oldest) == nil)
        #expect(await store.storage.planSnapshotRawText(id: newest) != nil)
    }

    /// Pinning is the user saying the one thing retention exists to guess at.
    @Test("A pinned plan survives pruning that would otherwise remove it")
    func pinnedPlanSurvivesPruning() async {
        let store = TemporaryQueryHistoryStore()
        let pinned = await store.record(
            subjectSQL: "SELECT 1", rawPlan: String(repeating: "a", count: 1_000),
            capturedAt: Date(timeIntervalSince1970: 100)
        )
        _ = await store.record(
            subjectSQL: "SELECT 1", rawPlan: String(repeating: "b", count: 1_000),
            capturedAt: Date(timeIntervalSince1970: 200)
        )
        #expect(await store.storage.setPlanSnapshotPinned(id: pinned, isPinned: true))

        _ = await store.storage.prunePlanSnapshots(toByteLimit: 1)
        #expect(await store.storage.planSnapshotRawText(id: pinned) != nil)
    }

    @Test("A plan over the per-plan cap is never written")
    func oversizedPlanIsNeverWritten() async {
        let store = TemporaryQueryHistoryStore()
        let identity = await store.identity(subjectSQL: "SELECT 1")
        let capture = QueryPlanCapture(
            id: UUID(),
            identity: identity,
            subjectSQL: "SELECT 1",
            rawPlan: String(repeating: "x", count: QueryPlanStorageLimits.maximumPlanByteCount + 1),
            executionTime: 0,
            capturedAt: Date(),
            historyId: nil
        )

        #expect(await store.storage.recordPlanSnapshot(capture) == false)
        #expect(await store.storage.planSnapshotUsage().snapshotCount == 0)
    }

    @Test("Usage reports what the plans cost")
    func usageReportsCost() async {
        let store = TemporaryQueryHistoryStore()
        _ = await store.record(subjectSQL: "SELECT 1", rawPlan: String(repeating: "a", count: 500))
        _ = await store.record(subjectSQL: "SELECT 2", rawPlan: String(repeating: "b", count: 300))

        let usage = await store.storage.planSnapshotUsage()
        #expect(usage.snapshotCount == 2)
        #expect(usage.byteCount == 800)
    }
}

/// A store on a throwaway file, so every case starts from an empty database and nothing reaches the
/// developer's own history.
private final class TemporaryQueryHistoryStore {
    let storage: QueryHistoryStorage
    private let connectionId = UUID()
    private(set) var lastHistoryId = UUID()

    init() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("plan-snapshots-\(UUID().uuidString).db")
        storage = QueryHistoryStorage(databaseURL: url, removeDatabaseOnDeinit: true)
    }

    func identity(
        subjectSQL: String,
        variantKey: QueryPlanVariantKey = .declared("explain")
    ) async -> QueryPlanIdentity {
        QueryPlanIdentity(
            fingerprintHash: SQLQueryFingerprint.hash(subjectSQL, databaseType: .postgresql),
            scope: QueryPlanScope(
                connectionId: connectionId,
                databaseType: .postgresql,
                databaseName: "app",
                schemaName: "public"
            ),
            variantKey: variantKey,
            format: .postgresJson
        )
    }

    /// Writes the history row and the plan the way `QueryHistoryManager` does, so the foreign key
    /// and the ordering are exercised rather than bypassed.
    @discardableResult
    func record(
        subjectSQL: String,
        rawPlan: String,
        variantKey: QueryPlanVariantKey = .declared("explain"),
        capturedAt: Date = Date()
    ) async -> UUID {
        let historyId = UUID()
        lastHistoryId = historyId
        let entry = QueryHistoryEntry(
            id: historyId,
            query: "EXPLAIN \(subjectSQL)",
            connectionId: connectionId,
            databaseName: "app",
            databaseType: .postgresql,
            schemaName: "public",
            source: .explain,
            executedAt: capturedAt,
            executionTime: 0.1,
            rowCount: 1,
            wasSuccessful: true
        )
        _ = await storage.record(entry)

        let snapshotId = UUID()
        let capture = await QueryPlanCapture(
            id: snapshotId,
            identity: identity(subjectSQL: subjectSQL, variantKey: variantKey),
            subjectSQL: subjectSQL,
            rawPlan: rawPlan,
            executionTime: 0.1,
            capturedAt: capturedAt,
            historyId: historyId
        )
        _ = await storage.recordPlanSnapshot(capture)
        return snapshotId
    }
}
