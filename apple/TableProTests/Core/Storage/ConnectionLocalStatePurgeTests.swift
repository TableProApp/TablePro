//
//  ConnectionLocalStatePurgeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSyncTransport
import TableProTestSupport
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

        await ConnectionLocalState.purgeAsyncStores([deleted], queryHistory: manager)

        #expect(await recordedQueries(storage, connectionId: deleted).isEmpty)
    }

    @Test("Purging a connection leaves another connection's history alone")
    func purgeIsScopedToItsConnection() async {
        let (manager, storage) = makeHistory()
        let deleted = UUID()
        let kept = UUID()
        _ = await storage.record(entry(connectionId: deleted, query: "SELECT secret FROM billing"))
        _ = await storage.record(entry(connectionId: kept, query: "SELECT 1"))

        await ConnectionLocalState.purgeAsyncStores([deleted], queryHistory: manager)

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

        await ConnectionLocalState.purgeAsyncStores([first, second], queryHistory: manager)

        #expect(await recordedQueries(storage, connectionId: first).isEmpty)
        #expect(await recordedQueries(storage, connectionId: second).isEmpty)
    }

    @MainActor
    private func makeFavorites() -> (SQLFavoriteManager, SyncJournalRecorder) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("purge_favorites_\(UUID().uuidString).db")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let journal = SyncJournalRecorder()
        let manager = SQLFavoriteManager(
            storage: SQLFavoriteStorage(databaseURL: url, removeDatabaseOnDeinit: true),
            syncJournal: journal.journal
        )
        return (manager, journal)
    }

    private func seedFavorite(_ manager: SQLFavoriteManager, connectionId: UUID) async -> SQLFavorite {
        let favorite = SQLFavorite(
            name: "Active users", query: "SELECT * FROM users", connectionId: connectionId
        )
        _ = await manager.addFavorite(favorite)
        return favorite
    }

    @Test("A purge journals the SQL favorites it removes")
    @MainActor
    func purgeJournalsFavorites() async throws {
        let (favorites, journal) = makeFavorites()
        let (history, _) = makeHistory()
        let deleted = UUID()
        let favorite = await seedFavorite(favorites, connectionId: deleted)

        await ConnectionLocalState.purgeAsyncStores(
            [deleted], sqlFavorites: favorites, queryHistory: history
        )

        #expect(await favorites.fetchFavorites(connectionId: deleted).isEmpty)
        #expect(journal.tombstonedIds(for: .favorite).contains(favorite.id.uuidString))
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

        await ConnectionLocalState.purgeAsyncStores([deleted], queryHistory: manager)

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

        await ConnectionLocalState.purgeAsyncStores([deleted], queryHistory: manager)

        #expect(!(await storage.planSnapshots(matching: keptIdentity, excluding: nil, limit: 10)).isEmpty)
    }

    @Test("Purging a connection takes its trailing pane preferences with it")
    @MainActor
    func purgeClearsTrailingPaneKeys() throws {
        let suite = try EphemeralDefaults()
        let defaults = suite.defaults
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
        let suite = try EphemeralDefaults()
        let defaults = suite.defaults
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

    @Test("Purging a connection removes its query tabs' versions and leaves another's")
    func purgeClearsQueryTabVersions() async {
        let (history, _) = makeHistory()
        let versions = QueryTabVersionStorage(
            databaseURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tablepro-tests")
                .appendingPathComponent("purge_tab_versions_\(UUID().uuidString).db"),
            announce: { _ in },
            removeDatabaseOnDeinit: true
        )
        let deleted = UUID()
        let kept = UUID()
        let deletedTab = UUID()
        let keptTab = UUID()
        await versions.record(tabId: deletedTab, connectionId: deleted, text: "SELECT secret", reason: .run)
        await versions.record(tabId: keptTab, connectionId: kept, text: "SELECT 1", reason: .run)

        await ConnectionLocalState.purgeAsyncStores(
            [deleted], queryHistory: history, queryTabVersions: versions
        )

        #expect(versions.summaries(tabId: deletedTab).isEmpty)
        #expect(versions.summaries(tabId: keptTab).count == 1)
    }

    private static func agentRecord(connectionId: UUID, conversationId: UUID?) -> AgentSessionRecord {
        AgentSessionRecord(
            id: UUID(),
            connectionId: connectionId,
            conversationId: conversationId,
            status: .stopped,
            title: "Earlier work",
            startedAt: Date(timeIntervalSince1970: 1_000),
            lastActiveAt: Date(timeIntervalSince1970: 2_000)
        )
    }

    private static func conversation(connectionId: UUID) -> AIConversation {
        AIConversation(
            messages: [ChatTurnWire(role: .user, blocks: [.text("Which orders shipped late?")])],
            connectionId: connectionId
        )
    }

    // D21: a deleted connection's sessions could never be opened again, and loaded on every launch.
    @Test("Purging a connection deletes its agent sessions and their conversations, and leaves another's")
    @MainActor
    func purgeRemovesAgentSessions() async throws {
        let suite = try EphemeralDefaults()
        let (history, _) = makeHistory()
        let deleted = UUID()
        let kept = UUID()
        let deletedConversation = Self.conversation(connectionId: deleted)
        let keptConversation = Self.conversation(connectionId: kept)
        await AIChatStorage.shared.save(deletedConversation)
        await AIChatStorage.shared.save(keptConversation)
        let store = AgentSessionStore(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("ConnectionLocalStatePurgeTests-\(UUID().uuidString)", isDirectory: true)
        )
        let keptRecord = Self.agentRecord(connectionId: kept, conversationId: keptConversation.id)
        store.save([
            Self.agentRecord(connectionId: deleted, conversationId: deletedConversation.id),
            Self.agentRecord(connectionId: deleted, conversationId: nil),
            keptRecord
        ])
        let registry = AgentSessionRegistry(store: store)
        let purged = registry.sessions(for: deleted)

        ConnectionLocalState.purge(
            connectionIds: [deleted],
            tableScopedStores: [],
            queryHistory: history,
            defaults: suite.defaults,
            agentSessions: registry
        )
        registry.persistNow()

        let keptIds = registry.sessions(for: kept).map { $0.id }
        let storedOwners = store.load().map { $0.connectionId }
        let built = purged.filter { $0.viewModelIfLoaded != nil }
        #expect(purged.count == 2)
        #expect(registry.sessions(for: deleted).isEmpty)
        #expect(keptIds == [keptRecord.id])
        #expect(storedOwners == [kept])
        #expect(built.isEmpty)
        try await waitUntil { await AIChatStorage.shared.load(id: deletedConversation.id) == nil }
        #expect(await AIChatStorage.shared.load(id: keptConversation.id) != nil)

        await AIChatStorage.shared.delete(keptConversation.id)
    }
}
