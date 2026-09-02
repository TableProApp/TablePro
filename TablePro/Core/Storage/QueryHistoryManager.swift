import Combine
import Foundation
import TableProPluginKit

final class QueryHistoryManager: QueryHistoryRecording, QueryHistoryReading, QueryPlanSnapshotReading, Sendable {
    static let shared = QueryHistoryManager()

    /// Not private: the rewind snapshot API lives in its own extension file rather than growing
    /// this one, and an extension in another file cannot reach a private stored property.
    internal let storage: QueryHistoryStorage
    private let isCapturePaused: @Sendable () -> Bool

    init(
        storage: QueryHistoryStorage = QueryHistoryStorage(),
        isCapturePaused: @escaping @Sendable () -> Bool = { QueryHistoryCaptureStore.isPaused }
    ) {
        self.storage = storage
        self.isCapturePaused = isCapturePaused
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

    func delete(id: UUID) async -> Bool {
        let success = await storage.delete(id: id)
        if success {
            await MainActor.run {
                AppEvents.shared.queryHistoryDidUpdate.send(nil)
            }
        }
        return success
    }

    func clear(matching filter: QueryHistoryFilter) async -> Bool {
        let success = await storage.clear(matching: filter)
        if success {
            await MainActor.run {
                AppEvents.shared.queryHistoryDidUpdate.send(nil)
            }
        }
        return success
    }

    // MARK: - Retention

    @MainActor
    func performStartupCleanup() async {
        await applyRetentionSettings()
        guard AppSettingsManager.shared.history.autoCleanup else { return }
        await runCleanup()
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
