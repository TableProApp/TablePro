//
//  HistoryPanelFilterStateStore.swift
//  TablePro
//

import Foundation

struct HistoryPanelFilterStateStore {
    private static let dateFilterKey = "HistoryPanel.dateFilter"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() -> UIDateFilter {
        guard userDefaults.object(forKey: Self.dateFilterKey) != nil else { return .all }
        let rawValue = userDefaults.integer(forKey: Self.dateFilterKey)
        return UIDateFilter(rawValue: rawValue) ?? .all
    }

    func save(_ dateFilter: UIDateFilter) {
        userDefaults.set(dateFilter.rawValue, forKey: Self.dateFilterKey)
    }
}
