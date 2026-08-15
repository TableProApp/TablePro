import Combine
import Foundation

final class QueryHistoryManager: QueryHistoryRecording, QueryHistoryReading {
    static let shared = QueryHistoryManager()

    private let storage: QueryHistoryStorage

    init(storage: QueryHistoryStorage = QueryHistoryStorage()) {
        self.storage = storage
    }

    // MARK: - Recording

    @discardableResult
    func record(_ request: QueryHistoryRecordRequest) async -> Bool {
        let entry = QueryHistoryEntry(
            query: request.query,
            connectionId: request.connectionId,
            databaseName: request.databaseName,
            databaseType: request.databaseType,
            schemaName: request.schemaName,
            source: request.source,
            executionTime: request.executionTime,
            rowCount: request.rowCount,
            wasSuccessful: request.wasSuccessful,
            errorMessage: request.errorMessage
        )
        return await record(entry)
    }

    @discardableResult
    func record(_ entry: QueryHistoryEntry) async -> Bool {
        let success = await storage.record(entry)
        if success {
            await MainActor.run {
                AppEvents.shared.queryHistoryDidUpdate.send(entry.connectionId)
            }
        }
        return success
    }

    // MARK: - Reading

    func fetch(_ filter: QueryHistoryFilter, after cursor: QueryHistoryCursor?, limit: Int) async -> QueryHistoryPage {
        await storage.fetch(filter, after: cursor, limit: limit)
    }

    func count(scope: QueryHistoryScope) async -> Int {
        await storage.count(scope: scope)
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
        await storage.cleanup()
    }

    @MainActor
    func applySettingsChange() async {
        await applyRetentionSettings()
        guard AppSettingsManager.shared.history.autoCleanup else { return }
        await storage.cleanup()
    }

    @MainActor
    func cleanup() async {
        await applyRetentionSettings()
        await storage.cleanup()
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
