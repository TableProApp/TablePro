import Combine
import Foundation

final class QueryHistoryManager {
    static let shared = QueryHistoryManager()

    private let storage: QueryHistoryStorage

    init(storage: QueryHistoryStorage = .shared) {
        self.storage = storage
    }

    @MainActor
    func performStartupCleanup() async {
        guard AppSettingsManager.shared.history.autoCleanup else { return }

        let settings = AppSettingsManager.shared.history
        await storage.updateSettingsCache(maxEntries: settings.maxEntries, maxDays: settings.maxDays)
        await storage.cleanup()
    }

    @MainActor
    func applySettingsChange() async {
        let settings = AppSettingsManager.shared.history
        await storage.updateSettingsCache(maxEntries: settings.maxEntries, maxDays: settings.maxDays)
        if AppSettingsManager.shared.history.autoCleanup {
            await storage.cleanup()
        }
    }

    // MARK: - History Capture

    func recordQuery(
        query: String,
        connectionId: UUID,
        databaseName: String,
        executionTime: TimeInterval,
        rowCount: Int,
        wasSuccessful: Bool,
        errorMessage: String? = nil,
        parameterValues: [QueryParameter]? = nil
    ) {
        var encodedParams: String?
        if let parameterValues, !parameterValues.isEmpty {
            encodedParams = try? String(data: JSONEncoder().encode(parameterValues), encoding: .utf8)
        }

        let entry = QueryHistoryEntry(
            query: query,
            connectionId: connectionId,
            databaseName: databaseName,
            executionTime: executionTime,
            rowCount: rowCount,
            wasSuccessful: wasSuccessful,
            errorMessage: errorMessage,
            parameterValues: encodedParams
        )

        Task {
            let success = await storage.addHistory(entry)
            if success {
                await MainActor.run {
                    AppEvents.shared.queryHistoryDidUpdate.send(entry.connectionId)
                }
            }
        }
    }

    // MARK: - History Retrieval

    func fetchHistory(
        limit: Int = 100,
        offset: Int = 0,
        connectionId: UUID? = nil,
        searchText: String? = nil,
        dateFilter: DateFilter = .all
    ) async -> [QueryHistoryEntry] {
        await storage.fetchHistory(
            limit: limit,
            offset: offset,
            connectionId: connectionId,
            searchText: searchText,
            dateFilter: dateFilter
        )
    }

    func searchQueries(_ text: String) async -> [QueryHistoryEntry] {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            return await fetchHistory()
        }
        return await storage.fetchHistory(searchText: text)
    }

    func deleteHistory(id: UUID) async -> Bool {
        let success = await storage.deleteHistory(id: id)
        if success {
            await MainActor.run {
                AppEvents.shared.queryHistoryDidUpdate.send(nil)
            }
        }
        return success
    }

    func getHistoryCount() async -> Int {
        await storage.getHistoryCount()
    }

    func clearAllHistory() async -> Bool {
        let success = await storage.clearAllHistory()
        if success {
            await MainActor.run {
                AppEvents.shared.queryHistoryDidUpdate.send(nil)
            }
        }
        return success
    }

    // MARK: - Cleanup

    @MainActor
    func cleanup() async {
        let settings = AppSettingsManager.shared.history
        await storage.updateSettingsCache(maxEntries: settings.maxEntries, maxDays: settings.maxDays)
        await storage.cleanup()
    }
}
