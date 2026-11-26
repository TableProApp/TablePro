import Combine
import Foundation
import TableProPluginKit

final class QueryHistoryManager: QueryHistoryRecording, QueryHistoryReading, QueryPlanSnapshotReading, Sendable {
    static let shared: QueryHistoryManager = {
        let storage = QueryHistoryStorage(onSetAside: { DamagedStoreNotice.queryHistorySetAside($0) })
        let mirror = QueryHistoryCoreMirror(storage: storage, database: .shared) { ids in
            await MainActor.run {
                let named = ConnectionStorage.shared.loadConnections().filter { ids.contains($0.id) }
                return Dictionary(named.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            }
        }
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

    func fetch(_ filter: QueryHistoryFilter, after cursor: QueryHistoryCursor?, limit: Int) async -> QueryHistoryPage {
        await storage.fetch(filter, after: cursor, limit: limit)
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

    // Each reports a failure while the core still holds what went, so nobody is told SQL is gone that is not.
    func delete(id: UUID) async -> Bool {
        let success = await storage.delete(id: id)
        guard success else { return false }
        let mirrored = await coreMirror?.dropped([id]) ?? true
        await MainActor.run {
            AppEvents.shared.queryHistoryDidUpdate.send(nil)
        }
        return mirrored
    }

    /// Used when the connection itself is gone, so it takes the plan and rewind snapshots with the
    /// history rather than unlinking them the way a filtered clear does.
    @discardableResult
    func deleteEverything(forConnection connectionId: UUID) async -> Bool {
        let success = await storage.deleteEverything(forConnection: connectionId)
        guard success else { return false }
        let mirrored = await coreMirror?.cleared(connectionId: connectionId) ?? true
        await MainActor.run {
            AppEvents.shared.queryHistoryDidUpdate.send(nil)
        }
        return mirrored
    }

    func clear(matching filter: QueryHistoryFilter) async -> Bool {
        let everyRow = QueryHistoryStorage.coversEveryRow(filter)
        var before: Set<UUID>?
        if coreMirror != nil, !everyRow {
            before = await storage.entryIds()
        }
        let success = await storage.clear(matching: filter)
        guard success else { return false }
        let mirrored: Bool
        if everyRow {
            mirrored = await coreMirror?.cleared(connectionId: nil) ?? true
        } else if let before, let after = await storage.entryIds() {
            mirrored = await coreMirror?.dropped(before.subtracting(after)) ?? true
        } else {
            mirrored = await coreMirror?.push() ?? true
        }
        await MainActor.run {
            AppEvents.shared.queryHistoryDidUpdate.send(nil)
        }
        return mirrored
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
