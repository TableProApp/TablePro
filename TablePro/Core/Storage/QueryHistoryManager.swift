import Combine
import Foundation

final class QueryHistoryManager: QueryHistoryRecording, QueryHistoryReading, Sendable {
    static let shared = QueryHistoryManager()

    private let storage: QueryHistoryStorage
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
        guard !isCapturePaused() else { return false }

        let planContext = request.explainPlan?.context
        let entry = QueryHistoryEntry(
            id: planContext?.historyId ?? UUID(),
            query: request.query,
            connectionId: request.connectionId,
            databaseName: request.databaseName,
            databaseType: request.databaseType,
            schemaName: request.schemaName,
            source: request.source,
            executedAt: planContext?.capturedAt ?? Date(),
            executionTime: request.executionTime,
            rowCount: request.rowCount,
            wasSuccessful: request.wasSuccessful,
            errorMessage: request.errorMessage
        )
        let explainPlan = request.explainPlan.flatMap { $0.isWithinStorageLimit ? $0 : nil }
        return await storeAndPublish(entry, explainPlan: explainPlan)
    }

    /// The single writer, so pausing here covers every source: the editor, the grid, structure
    /// changes, imports and MCP alike.
    @discardableResult
    func record(_ entry: QueryHistoryEntry) async -> Bool {
        guard !isCapturePaused() else { return false }

        return await storeAndPublish(entry, explainPlan: nil)
    }

    private func storeAndPublish(
        _ entry: QueryHistoryEntry,
        explainPlan: ExplainPlanHistoryRecord?
    ) async -> Bool {
        let success = await storage.record(entry, explainPlan: explainPlan)
        if success {
            let updatedConnectionId: UUID? = explainPlan == nil ? entry.connectionId : nil
            await MainActor.run {
                AppEvents.shared.queryHistoryDidUpdate.send(updatedConnectionId)
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

    func explainPlanHistory(
        matching context: ExplainPlanHistoryContext,
        limit: Int
    ) async -> [ExplainPlanHistorySnapshot] {
        await storage.explainPlanHistory(matching: context, limit: limit)
    }

    func explainPlanRawText(historyId: UUID) async -> String? {
        await storage.explainPlanRawText(historyId: historyId)
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
