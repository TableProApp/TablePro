//
//  FoldTabOwnershipTests.swift
//  TableProTests
//

import Foundation
import Testing
@testable import TablePro

/// Collapsed regions belong to the tab they were made in.
///
/// They used to live in a window wide property that persistence read for whichever tab was selected, with the tab's
/// own copy cleared the first time its view appeared. Switching between two tabs that both had folds could then write
/// one tab's regions onto the other, and the guard against it compared document lengths.
@Suite("Fold tab ownership")
@MainActor
struct FoldTabOwnershipTests {
    private func makeCoordinator(tabManager: QueryTabManager) -> MainContentCoordinator {
        MainContentCoordinator(
            connection: TestFixtures.makeConnection(
                id: UUID(),
                name: "MySQL",
                database: "db",
                type: .mysql
            ),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
    }

    private func makeQueryTab(_ query: String) -> QueryTab {
        var tab = QueryTab(title: "Query", query: query)
        tab.tabType = .query
        return tab
    }

    @Test("Each tab keeps the regions folded in it")
    func foldsStayWithTheirTab() {
        let tabManager = QueryTabManager()
        let first = makeQueryTab("SELECT 1;")
        let second = makeQueryTab("SELECT 2;")
        tabManager.tabs = [first, second]
        let coordinator = makeCoordinator(tabManager: tabManager)
        defer { coordinator.teardown() }

        coordinator.recordFoldRanges([0..<5], for: first.id)
        coordinator.recordFoldRanges([2..<7], for: second.id)

        #expect(coordinator.foldRanges(for: first.id) == [0..<5])
        #expect(coordinator.foldRanges(for: second.id) == [2..<7])
    }

    @Test("Reading a tab's folds does not consume them")
    func readingDoesNotClear() {
        let tabManager = QueryTabManager()
        let tab = makeQueryTab("SELECT 1;")
        tabManager.tabs = [tab]
        let coordinator = makeCoordinator(tabManager: tabManager)
        defer { coordinator.teardown() }

        coordinator.recordFoldRanges([0..<5], for: tab.id)

        #expect(coordinator.foldRanges(for: tab.id) == [0..<5])
        #expect(coordinator.foldRanges(for: tab.id) == [0..<5], "Switching away and back must not lose them")
    }

    @Test("Unfolding everything clears the tab rather than leaving an empty list behind")
    func unfoldingClearsTheTab() {
        let tabManager = QueryTabManager()
        let tab = makeQueryTab("SELECT 1;")
        tabManager.tabs = [tab]
        let coordinator = makeCoordinator(tabManager: tabManager)
        defer { coordinator.teardown() }

        coordinator.recordFoldRanges([0..<5], for: tab.id)
        coordinator.recordFoldRanges([], for: tab.id)

        #expect(coordinator.foldRanges(for: tab.id) == nil)
    }

    @Test("A tab that is not a query tab has no folds to report")
    func nonQueryTabsHaveNoFolds() {
        let tabManager = QueryTabManager()
        var tab = makeQueryTab("SELECT 1;")
        tab.tabType = .table
        tabManager.tabs = [tab]
        let coordinator = makeCoordinator(tabManager: tabManager)
        defer { coordinator.teardown() }

        #expect(coordinator.foldRanges(for: tab.id) == nil)
    }
}
