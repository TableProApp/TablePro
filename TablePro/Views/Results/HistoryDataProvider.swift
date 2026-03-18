//
//  HistoryDataProvider.swift
//  TablePro
//
//  Data provider for query history entries and date filter model.
//  Used by HistoryPanelView for data loading, searching, and deletion.
//

import Foundation

// MARK: - UI Date Filter

/// Date range filter for history panel
enum UIDateFilter: Int, CaseIterable {
    case today = 0
    case week = 1
    case month = 2
    case all = 3

    var title: String {
        switch self {
        case .today: return String(localized: "Today")
        case .week: return String(localized: "This Week")
        case .month: return String(localized: "This Month")
        case .all: return String(localized: "All Time")
        }
    }

    var toDateFilter: DateFilter {
        switch self {
        case .today: return .today
        case .week: return .thisWeek
        case .month: return .thisMonth
        case .all: return .all
        }
    }
}

/// Data provider for query history entries
final class HistoryDataProvider {
    // MARK: - Properties

    private(set) var historyEntries: [QueryHistoryEntry] = []

    var dateFilter: UIDateFilter = .all
    var searchText: String = ""

    private var searchTask: Task<Void, Never>?

    /// Callback when data changes
    var onDataChanged: (() -> Void)?

    // MARK: - Computed Properties

    var count: Int {
        historyEntries.count
    }

    var isEmpty: Bool {
        historyEntries.isEmpty
    }

    // MARK: - Data Loading

    /// Load data asynchronously
    func loadData() async {
        let entries = await QueryHistoryManager.shared.fetchHistory(
            limit: 500,
            offset: 0,
            connectionId: nil,
            searchText: searchText.isEmpty ? nil : searchText,
            dateFilter: dateFilter.toDateFilter
        )
        historyEntries = entries
        onDataChanged?()
    }

    // MARK: - Search

    func scheduleSearch(completion: @escaping () -> Void) {
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            await self.loadData()
            completion()
        }
    }

    // MARK: - Item Access

    func historyEntry(at index: Int) -> QueryHistoryEntry? {
        guard index >= 0 && index < historyEntries.count else { return nil }
        return historyEntries[index]
    }

    func query(at index: Int) -> String? {
        historyEntry(at: index)?.query
    }

    // MARK: - Deletion

    func deleteItem(at index: Int) async -> Bool {
        guard let entry = historyEntry(at: index) else {
            return false
        }
        return await deleteEntry(id: entry.id)
    }

    func deleteEntry(id: UUID) async -> Bool {
        let success = await QueryHistoryStorage.shared.deleteHistory(id: id)
        if success {
            await loadData()
        }
        return success
    }

    func clearAll() async -> Bool {
        let success = await QueryHistoryStorage.shared.clearAllHistory()
        if success {
            await loadData()
        }
        return success
    }
}
