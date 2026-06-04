//
//  HistoryPanelFilterStateStoreTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

private let dateFilterKey = "HistoryPanel.dateFilter"

private func makeHistoryPanelDefaults() -> (UserDefaults, String) {
    let suiteName = "TablePro.HistoryPanelFilterStateStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

@Suite("HistoryPanelFilterStateStore")
struct HistoryPanelFilterStateStoreTests {
    @Test("loads all when no date filter is stored")
    func loadsDefaultFilter() {
        let (defaults, suiteName) = makeHistoryPanelDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HistoryPanelFilterStateStore(userDefaults: defaults)

        #expect(store.load() == .all)
    }

    @Test("loads saved date filter")
    func loadsSavedFilter() {
        let (defaults, suiteName) = makeHistoryPanelDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(UIDateFilter.week.rawValue, forKey: dateFilterKey)
        let store = HistoryPanelFilterStateStore(userDefaults: defaults)

        #expect(store.load() == .week)
    }

    @Test("saves date filter")
    func savesFilter() {
        let (defaults, suiteName) = makeHistoryPanelDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = HistoryPanelFilterStateStore(userDefaults: defaults)
        store.save(.month)

        #expect(defaults.integer(forKey: dateFilterKey) == UIDateFilter.month.rawValue)
    }
}
