//
//  TabPersistenceClearGuardTests.swift
//  TableProTests
//
//  A window left over from a disconnect holds no tabs, and its empty tab list is not the user saying
//  they closed everything. Reading it that way deleted the tabs the disconnect had just saved.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Tab persistence clear guard", .serialized)
@MainActor
struct TabPersistenceClearGuardTests {
    @Test("A coordinator that never held a tab does not clear saved state")
    func neverHeldTabsWithholdsClear() {
        let persistence = TabPersistenceCoordinator(connectionId: UUID())

        #expect(!persistence.hasObservedTabs)

        persistence.saveOrClearAggregatedSync()

        #expect(!persistence.hasObservedTabs)
    }

    @Test("Saving a non-empty tab set earns the right to clear later")
    func savingTabsMarksThemObserved() {
        let persistence = TabPersistenceCoordinator(connectionId: UUID())
        let tab = QueryTab(id: UUID(), title: "Scratch", query: "SELECT 1", tabType: .table)

        persistence.saveNowSync(tabs: [tab], selectedTabId: tab.id)

        #expect(persistence.hasObservedTabs)
    }

    @Test("An empty save neither writes nor earns the right to clear")
    func emptySaveIsInert() {
        let persistence = TabPersistenceCoordinator(connectionId: UUID())

        persistence.saveNowSync(tabs: [], selectedTabId: nil)

        #expect(!persistence.hasObservedTabs)
    }
}
