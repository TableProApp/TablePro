import Combine
import Foundation
import TableProFFI
import TableProPluginKit

final class QueryHistoryManager: QueryHistoryRecording, QueryHistoryReading, QueryPlanSnapshotReading, Sendable {
    static let shared: QueryHistoryManager = {
        let storage = QueryHistoryStorage(onSetAside: { DamagedStoreNotice.queryHistorySetAside($0) })
        let mirror = QueryHistoryCoreMirror(
            storage: storage,
            database: .shared,
            connectionNames: { ids in
                await MainActor.run {
                    let named = ConnectionStorage.shared.loadConnections().filter { ids.contains($0.id) }
                    return Dictionary(named.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
                }
            },
            changed: {
                await MainActor.run { AppEvents.shared.queryHistoryDidUpdate.send(nil) }
            }
        )
        return QueryHistoryManager(storage: storage, coreMirror: mirror)
    }()

    // Not private: QueryHistoryManager+Rewind reaches it from another file.
    internal let storage: QueryHistoryStorage
    let rewindAvailability: RewindAvailabilityCache
    private let isCapturePaused: @Sendable () -> Bool
    // Nil keeps the history out of the core, for a store nothing else reads.
    internal let coreMirror: QueryHistoryCoreMirror?

    init(
        storage: QueryHistoryStorage = QueryHistoryStorage(),
        isCapturePaused: @escaping @Sendable () -> Bool = { QueryHistoryCaptureStore.isPaused },
        coreMirror: QueryHistoryCoreMirror? = nil
    ) {
        self.storage = storage
        self.rewindAvailability = RewindAvailabilityCache(storage: storage)
        self.isCapturePaused = isCapturePaused
        self.coreMirror = coreMirror
    }

    // MARK: - Recording

    @discardableResult
    func record(_ request: QueryHistoryRecordRequest) async -> Bool {
        let entry = QueryHistoryEntry(
            id: request.id,
            query: request.query,
            connectionId: request.connectionId,
            databaseName: request.databaseName,
            databaseType: request.databaseType,
            schemaName: request.schemaName,
            source: request.source,
            executionTime: request.executionTime,
            rowCount: request.rowCount,
            wasSuccessful: request.wasSuccessful,
            errorMessage: request.errorMessage,
            firstRowTime: request.timing?.firstRow,
            serverTime: request.timing?.server
        )
        let stored = await record(entry)

        /// Written after the history row rather than with it: `plan_snapshots.history_id` is a
        /// foreign key, so the row it points at has to exist first, and a plan that fails to store
        /// must not take the history entry down with it.
        if stored, let capture = request.planCapture {
            await storage.recordPlanSnapshot(capture)
        }
        return stored
    }

    /// The single writer, so pausing here covers every source: the editor, the grid, structure
    /// changes, imports and MCP alike.
    @discardableResult
    func record(_ entry: QueryHistoryEntry) async -> Bool {
        guard !isCapturePaused() else { return false }

        let success = await storage.record(entry)
        if success {
            coreMirror?.scheduleRecorded(entry.id)
            await MainActor.run {
                AppEvents.shared.queryHistoryDidUpdate.send(entry.connectionId)
            }
        }
        return success
    }

    // MARK: - Reading

    func isStoreAvailable() async -> Bool {
        await storage.isStoreAvailable()
    }

    // The core's history, other devices' runs included, and this store's only while the core's cannot be read. A page
    // goes on in the store its cursor came from.
    func fetch(_ filter: QueryHistoryFilter, after cursor: QueryHistoryCursor?, limit: Int) async -> QueryHistoryPage {
        if let coreMirror, cursor.map(Self.isCore) ?? true,
           let page = await coreMirror.search(filter, after: cursor, limit: limit) {
            return page
        }
        if let cursor, Self.isCore(cursor) {
            return .empty
        }
        return await storage.fetch(filter, after: cursor, limit: limit)
    }

    private static func isCore(_ cursor: QueryHistoryCursor) -> Bool {
        if case .core = cursor { return true }
        return false
    }

    func count(scope: QueryHistoryScope) async -> Int {
        await storage.count(scope: scope)
    }

    // MARK: - Plan snapshots

    func planSnapshots(
        matching identity: QueryPlanIdentity,
        excluding excludedId: UUID?,
        limit: Int
    ) async -> [QueryPlanSnapshotSummary] {
        await storage.planSnapshots(matching: identity, excluding: excludedId, limit: limit)
    }

    func planSnapshotRawText(id: UUID) async -> String? {
        await storage.planSnapshotRawText(id: id)
    }

    func planSnapshotUsage() async -> QueryPlanStorageUsage {
        await storage.planSnapshotUsage()
    }

    @discardableResult
    func setPlanSnapshotPinned(id: UUID, isPinned: Bool) async -> Bool {
        await storage.setPlanSnapshotPinned(id: id, isPinned: isPinned)
    }

    @discardableResult
    func deletePlanSnapshot(id: UUID) async -> Bool {
        await storage.deletePlanSnapshot(id: id)
    }

    @discardableResult
    func clearPlanSnapshots() async -> Bool {
        await storage.clearPlanSnapshots()
    }

    func insights(
        _ request: QueryInsightsRequest,
        slowestRanking: QueryInsightsSlowestRanking
    ) async -> QueryInsightsSnapshot {
        await storage.insights(request, slowestRanking: slowestRanking)
    }

    // MARK: - Deleting

    // Each reports a failure while the core still holds what went, so nobody is told SQL is gone that is not. The run
    // may be another device's, which only the core held.
    func delete(id: UUID) async -> Bool {
        let storage = storage
        let deleted: Bool
        if let coreMirror {
            deleted = await coreMirror.deleted([id]) { await storage.delete(id: id) }
        } else {
            deleted = await storage.delete(id: id)
        }
        await MainActor.run {
            AppEvents.shared.queryHistoryDidUpdate.send(nil)
        }
        return deleted
    }

    /// Used when the connection itself is gone, so it takes the plan and rewind snapshots with the
    /// history rather than unlinking them the way a filtered clear does.
    @discardableResult
    func deleteEverything(forConnection connectionId: UUID) async -> Bool {
        let storage = storage
        let deleted: Bool
        if let coreMirror {
            let ids = await storage.ids(matching: QueryHistoryFilter(scope: .connection(connectionId))) ?? []
            deleted = await coreMirror.cleared(connectionId: connectionId, ids: ids) {
                await storage.deleteEverything(forConnection: connectionId)
            }
        } else {
            deleted = await storage.deleteEverything(forConnection: connectionId)
        }
        await MainActor.run {
            AppEvents.shared.queryHistoryDidUpdate.send(nil)
        }
        return deleted
    }

    // What the pane shows: the core's runs the filter matches, other devices' included, and this store's.
    func clear(matching filter: QueryHistoryFilter) async -> Bool {
        let storage = storage
        let cleared: Bool
        if let coreMirror, QueryHistoryStorage.coversEveryRow(filter) {
            let ids = await storage.entryIds() ?? []
            cleared = await coreMirror.cleared(connectionId: nil, ids: ids) { await storage.clear(matching: filter) }
        } else if let coreMirror {
            let ids = await storage.ids(matching: filter) ?? []
            cleared = await coreMirror.cleared(matching: filter, localIds: ids) { matched in
                await storage.deleteRuns(matched)
            }
        } else {
            cleared = await storage.clear(matching: filter)
        }
        await MainActor.run {
            AppEvents.shared.queryHistoryDidUpdate.send(nil)
        }
        return cleared
    }

    // MARK: - Retention

    // Then the core takes in the runs it lacks, the previous stable's included.
    @MainActor
    func performStartupCleanup() async {
        await applyRetentionSettings()
        if AppSettingsManager.shared.history.autoCleanup {
            await runCleanup()
        }
        await coreMirror?.push()
        await coreMirror?.fillFingerprints()
    }

    @MainActor
    func applySettingsChange() async {
        await applyRetentionSettings()
        guard AppSettingsManager.shared.history.autoCleanup else { return }
        await runCleanup()
    }

    @MainActor
    func cleanup() async {
        await applyRetentionSettings()
        await runCleanup()
    }

    private func runCleanup() async {
        guard await storage.cleanup() else { return }
        coreMirror?.schedulePush()
        await MainActor.run {
            AppEvents.shared.queryHistoryDidUpdate.send(nil)
        }
    }

    @MainActor
    private func applyRetentionSettings() async {
        let settings = AppSettingsManager.shared.history
        await storage.updateSettingsCache(
            maxEntries: settings.maxEntries,
            maxDays: settings.maxDays,
            autoCleanup: settings.autoCleanup
        )
    }
}

// After each finished pass of the sync service: the runs it pulled come down into `query_history.db` and get their
// shape, the ones another device deleted leave it, and the pane reads again.
@MainActor
final class QueryHistoryPassFollower {
    static let shared = QueryHistoryPassFollower()

    private var subscription: AnyCancellable?
    private var passSeen: Int64?

    func start(host: SyncEngineHost) {
        start(changes: host.statusChanges.eraseToAnyPublisher(), lastPass: { [weak host] in
            host?.openedEngine(for: .off)?.status().lastPassMs
        }) {
            await QueryHistoryManager.shared.coreMirror?.pushSoon()
            await QueryHistoryManager.shared.coreMirror?.fillFingerprints()
        }
    }

    func start(
        changes: AnyPublisher<Void, Never>,
        lastPass: @escaping @MainActor () -> Int64?,
        onPass: @escaping @MainActor () async -> Void
    ) {
        guard subscription == nil else { return }
        subscription = changes.sink { [weak self] in
            guard let self, let pass = lastPass(), pass != passSeen else { return }
            passSeen = pass
            Task { await onPass() }
        }
    }
}
