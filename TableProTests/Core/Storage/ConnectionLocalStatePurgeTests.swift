//
//  ConnectionLocalStatePurgeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSyncTransport
import Testing

/// The stores a deleted connection leaves behind that can only be reached with `await`.
struct ConnectionLocalStatePurgeTests {
    private func makeHistory() -> (QueryHistoryManager, QueryHistoryStorage) {
        let storage = QueryHistoryStorage(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tablepro-tests")
                .appendingPathComponent("purge_\(UUID().uuidString).db"),
            removeDatabaseOnDeinit: true
        )
        return (QueryHistoryManager(storage: storage, isCapturePaused: { false }), storage)
    }

    private func planIdentity(connectionId: UUID, subjectSQL: String) -> QueryPlanIdentity {
        QueryPlanIdentity(
            fingerprintHash: SQLQueryFingerprint.hash(subjectSQL, databaseType: .postgresql),
            scope: QueryPlanScope(
                connectionId: connectionId,
                databaseType: .postgresql,
                databaseName: "shop",
                schemaName: nil
            ),
            variantKey: .declared("explain"),
            format: .postgresJson
        )
    }

    private func entry(connectionId: UUID, query: String, id: UUID = UUID()) -> QueryHistoryEntry {
        QueryHistoryEntry(
            id: id,
            query: query,
            connectionId: connectionId,
            databaseName: "shop",
            databaseType: .postgresql,
            schemaName: nil,
            source: .editor,
            executionTime: 0.1,
            rowCount: 1,
            wasSuccessful: true
        )
    }

    private func recordedQueries(
        _ storage: QueryHistoryStorage,
        connectionId: UUID
    ) async -> [String] {
        await storage.fetch(
            QueryHistoryFilter(scope: .connection(connectionId)),
            after: nil,
            limit: 200
        ).entries.map(\.query)
    }

    @Test("Purging a connection clears its query history")
    func purgeClearsQueryHistory() async {
        let (manager, storage) = makeHistory()
        let deleted = UUID()
        _ = await storage.record(entry(connectionId: deleted, query: "SELECT secret FROM billing"))

        await ConnectionLocalState.purgeAsyncStores([deleted], origin: .local, queryHistory: manager)

        #expect(await recordedQueries(storage, connectionId: deleted).isEmpty)
    }

    @Test("Purging a connection leaves another connection's history alone")
    func purgeIsScopedToItsConnection() async {
        let (manager, storage) = makeHistory()
        let deleted = UUID()
        let kept = UUID()
        _ = await storage.record(entry(connectionId: deleted, query: "SELECT secret FROM billing"))
        _ = await storage.record(entry(connectionId: kept, query: "SELECT 1"))

        await ConnectionLocalState.purgeAsyncStores([deleted], origin: .local, queryHistory: manager)

        #expect(await recordedQueries(storage, connectionId: deleted).isEmpty)
        #expect(await recordedQueries(storage, connectionId: kept) == ["SELECT 1"])
    }

    @Test("Purging several connections clears every one of them")
    func purgeClearsEveryConnection() async {
        let (manager, storage) = makeHistory()
        let first = UUID()
        let second = UUID()
        _ = await storage.record(entry(connectionId: first, query: "SELECT 1"))
        _ = await storage.record(entry(connectionId: second, query: "SELECT 2"))

        await ConnectionLocalState.purgeAsyncStores([first, second], origin: .local, queryHistory: manager)

        #expect(await recordedQueries(storage, connectionId: first).isEmpty)
        #expect(await recordedQueries(storage, connectionId: second).isEmpty)
    }

    private func makeFavorites() -> (SQLFavoriteManager, SyncMetadataStorage) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("purge_favorites_\(UUID().uuidString).db")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let metadata = SyncMetadataStorage(
            userDefaults: UserDefaults(suiteName: "tablepro-purge-\(UUID().uuidString)") ?? .standard,
            prefix: "tests.\(UUID().uuidString)"
        )
        let manager = SQLFavoriteManager(
            storage: SQLFavoriteStorage(databaseURL: url, removeDatabaseOnDeinit: true),
            syncTracker: SyncChangeTracker(metadataStorage: metadata)
        )
        return (manager, metadata)
    }

    private func seedFavorite(_ manager: SQLFavoriteManager, connectionId: UUID) async -> SQLFavorite {
        let favorite = SQLFavorite(
            name: "Active users", query: "SELECT * FROM users", connectionId: connectionId
        )
        _ = await manager.addFavorite(favorite)
        return favorite
    }

    /// The device that deleted the connection already told CloudKit. A tombstone from here sends
    /// its own deletion back at it.
    @Test("A remote purge removes the SQL favorites without tombstoning them")
    func remotePurgeLeavesNoFavoriteTombstone() async {
        let (favorites, metadata) = makeFavorites()
        let (history, _) = makeHistory()
        let deleted = UUID()
        let favorite = await seedFavorite(favorites, connectionId: deleted)

        await ConnectionLocalState.purgeAsyncStores(
            [deleted], origin: .remote, sqlFavorites: favorites, queryHistory: history
        )

        #expect(await favorites.fetchFavorites(connectionId: deleted).isEmpty)
        #expect(!metadata.tombstones(for: .favorite).contains { $0.id == favorite.id.uuidString })
    }

    @Test("A local purge tombstones the SQL favorites it removes")
    func localPurgeTombstonesFavorites() async {
        let (favorites, metadata) = makeFavorites()
        let (history, _) = makeHistory()
        let deleted = UUID()
        let favorite = await seedFavorite(favorites, connectionId: deleted)

        await ConnectionLocalState.purgeAsyncStores(
            [deleted], origin: .local, sqlFavorites: favorites, queryHistory: history
        )

        #expect(await favorites.fetchFavorites(connectionId: deleted).isEmpty)
        #expect(metadata.tombstones(for: .favorite).contains { $0.id == favorite.id.uuidString })
    }

    /// A filtered clear deletes from `history` alone, and both snapshot tables keep their own copy
    /// of the statement: `plan_snapshots.subject_sql` and `raw_plan`. Their `history_id` is
    /// `ON DELETE SET NULL`, so the plan outlived the history row it came from.
    @Test("Purging a connection takes its saved query plans with the history")
    func purgeClearsPlanSnapshots() async {
        let (manager, storage) = makeHistory()
        let deleted = UUID()
        let identity = planIdentity(connectionId: deleted, subjectSQL: "SELECT card FROM billing")
        let historyId = UUID()
        _ = await storage.record(
            entry(connectionId: deleted, query: "EXPLAIN SELECT card FROM billing", id: historyId)
        )
        _ = await storage.recordPlanSnapshot(
            QueryPlanCapture(
                id: UUID(),
                identity: identity,
                subjectSQL: "SELECT card FROM billing",
                rawPlan: "Seq Scan on billing",
                executionTime: 0.1,
                capturedAt: Date(timeIntervalSince1970: 1),
                historyId: historyId
            )
        )
        #expect(!(await storage.planSnapshots(matching: identity, excluding: nil, limit: 10)).isEmpty)

        await ConnectionLocalState.purgeAsyncStores([deleted], origin: .local, queryHistory: manager)

        #expect((await storage.planSnapshots(matching: identity, excluding: nil, limit: 10)).isEmpty)
    }

    @Test("Purging a connection leaves another connection's saved plans alone")
    func purgeLeavesOtherConnectionsPlansAlone() async {
        let (manager, storage) = makeHistory()
        let deleted = UUID()
        let kept = UUID()
        let keptIdentity = planIdentity(connectionId: kept, subjectSQL: "SELECT 1")
        let historyId = UUID()
        _ = await storage.record(entry(connectionId: kept, query: "EXPLAIN SELECT 1", id: historyId))
        _ = await storage.recordPlanSnapshot(
            QueryPlanCapture(
                id: UUID(),
                identity: keptIdentity,
                subjectSQL: "SELECT 1",
                rawPlan: "Result",
                executionTime: 0.1,
                capturedAt: Date(timeIntervalSince1970: 1),
                historyId: historyId
            )
        )

        await ConnectionLocalState.purgeAsyncStores([deleted], origin: .local, queryHistory: manager)

        #expect(!(await storage.planSnapshots(matching: keptIdentity, excluding: nil, limit: 10)).isEmpty)
    }

    @Test("Purging a connection takes its trailing pane preferences with it")
    @MainActor
    func purgeClearsTrailingPaneKeys() throws {
        let suite = "tablepro-purge-pane-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let deleted = UUID()

        defaults.set(TrailingPaneSurface.assistant.rawValue, forKey: TrailingPaneState.surfaceKey(deleted))
        defaults.set(InspectorViewMode.json.rawValue, forKey: RowInspectorState.viewModeKey(deleted))

        ConnectionLocalState.purgeTrailingPaneKeys([deleted], defaults: defaults)

        #expect(defaults.string(forKey: TrailingPaneState.surfaceKey(deleted)) == nil)
        #expect(defaults.string(forKey: RowInspectorState.viewModeKey(deleted)) == nil)
    }

    /// A connection deleted on one device must not take another connection's pane with it, and the
    /// keys are per connection precisely so it cannot.
    @Test("Purging one connection leaves another connection's trailing pane alone")
    @MainActor
    func purgeLeavesOtherTrailingPanesAlone() throws {
        let suite = "tablepro-purge-pane-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let deleted = UUID()
        let kept = UUID()

        defaults.set(TrailingPaneSurface.assistant.rawValue, forKey: TrailingPaneState.surfaceKey(deleted))
        defaults.set(TrailingPaneSurface.assistant.rawValue, forKey: TrailingPaneState.surfaceKey(kept))
        defaults.set(InspectorViewMode.json.rawValue, forKey: RowInspectorState.viewModeKey(kept))

        ConnectionLocalState.purgeTrailingPaneKeys([deleted], defaults: defaults)

        #expect(defaults.string(forKey: TrailingPaneState.surfaceKey(deleted)) == nil)
        #expect(
            defaults.string(forKey: TrailingPaneState.surfaceKey(kept))
                == TrailingPaneSurface.assistant.rawValue
        )
        #expect(
            defaults.string(forKey: RowInspectorState.viewModeKey(kept)) == InspectorViewMode.json.rawValue
        )
    }
}
