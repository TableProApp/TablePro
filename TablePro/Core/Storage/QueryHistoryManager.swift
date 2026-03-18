//
//  QueryHistoryManager.swift
//  TablePro
//
//  Thread-safe coordinator for query history
//

import Foundation

/// Thread-safe manager for query history
/// NOT an ObservableObject - uses NotificationCenter for UI communication
final class QueryHistoryManager {
    static let shared = QueryHistoryManager()

    private let storage: QueryHistoryStorage

    /// Creates an isolated manager with its own storage. For testing only.
    init(isolatedStorage: QueryHistoryStorage) {
        self.storage = isolatedStorage
    }

    private init() {
        self.storage = QueryHistoryStorage.shared
    }

    /// Perform cleanup if auto-cleanup is enabled in settings
    /// Should be called from app startup (MainActor context)
    @MainActor
    func performStartupCleanup() {
        // Check if auto cleanup is enabled
        guard AppSettingsManager.shared.history.autoCleanup else { return }

        // Update the settings cache before cleanup
        storage.updateSettingsCache()

        // Perform cleanup
        storage.cleanup()
    }

    /// Apply settings changes directly (called by AppSettingsManager)
    @MainActor
    func applySettingsChange() {
        storage.updateSettingsCache()
        if AppSettingsManager.shared.history.autoCleanup {
            storage.cleanup()
        }
    }

    // MARK: - History Capture

    /// Record a query execution (fire-and-forget background write)
    func recordQuery(
        query: String,
        connectionId: UUID,
        databaseName: String,
        executionTime: TimeInterval,
        rowCount: Int,
        wasSuccessful: Bool,
        errorMessage: String? = nil
    ) {
        let entry = QueryHistoryEntry(
            query: query,
            connectionId: connectionId,
            databaseName: databaseName,
            executionTime: executionTime,
            rowCount: rowCount,
            wasSuccessful: wasSuccessful,
            errorMessage: errorMessage
        )

        Task {
            let success = await storage.addHistory(entry)
            if success {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .queryHistoryDidUpdate,
                        object: nil
                    )
                }
            }
        }
    }

    // MARK: - History Retrieval

    /// Fetch history entries asynchronously
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

    /// Search queries using FTS5 full-text search
    func searchQueries(_ text: String) async -> [QueryHistoryEntry] {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            return await fetchHistory()
        }
        return await storage.fetchHistory(searchText: text)
    }

    /// Delete a history entry asynchronously
    func deleteHistory(id: UUID) async -> Bool {
        let success = await storage.deleteHistory(id: id)
        if success {
            await MainActor.run {
                NotificationCenter.default.post(name: .queryHistoryDidUpdate, object: nil)
            }
        }
        return success
    }

    /// Get total history count asynchronously
    func getHistoryCount() async -> Int {
        await storage.getHistoryCount()
    }

    /// Clear all history entries asynchronously
    func clearAllHistory() async -> Bool {
        let success = await storage.clearAllHistory()
        if success {
            await MainActor.run {
                NotificationCenter.default.post(name: .queryHistoryDidUpdate, object: nil)
            }
        }
        return success
    }

    // MARK: - Cleanup

    /// Manually trigger cleanup (normally runs automatically)
    /// Must be called from MainActor context
    @MainActor
    func cleanup() {
        // Update settings cache before cleanup
        storage.updateSettingsCache()
        storage.cleanup()
    }
}
