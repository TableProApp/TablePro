//
//  CoordinatorColumnVisibilityTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("MainContentCoordinator column visibility helpers")
@MainActor
struct CoordinatorColumnVisibilityTests {
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        return (coordinator, tabManager)
    }

    private func addTableTab(
        to tabManager: QueryTabManager,
        tableName: String
    ) -> UUID {
        var tab = QueryTab(
            title: tableName,
            query: "SELECT * FROM \(tableName)",
            tabType: .table,
            tableName: tableName
        )
        tab.tableContext.isEditable = true
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return tab.id
    }

    @Test("hideColumn inserts into the active tab's hidden set")
    func hideColumn() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")

        coordinator.hideColumn("name")

        guard let index = tabManager.tabs.firstIndex(where: { $0.id == tabId }) else {
            Issue.record("Expected tab to exist")
            return
        }
        #expect(tabManager.tabs[index].columnLayout.hiddenColumns == ["name"])
    }

    @Test("showColumn removes from the active tab's hidden set")
    func showColumn() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager, tableName: "users")
        coordinator.hideColumn("name")
        coordinator.hideColumn("email")

        coordinator.showColumn("name")

        #expect(coordinator.selectedTabHiddenColumns == ["email"])
    }

    @Test("toggleColumnVisibility flips state")
    func toggleColumnVisibility() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager, tableName: "users")

        coordinator.toggleColumnVisibility("name")
        #expect(coordinator.selectedTabHiddenColumns.contains("name"))

        coordinator.toggleColumnVisibility("name")
        #expect(!coordinator.selectedTabHiddenColumns.contains("name"))
    }

    @Test("showAllColumns clears hidden set on the active tab")
    func showAllColumns() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager, tableName: "users")
        coordinator.hideAllColumns(["a", "b", "c"])

        coordinator.showAllColumns()
        #expect(coordinator.selectedTabHiddenColumns.isEmpty)
    }

    @Test("hideAllColumns replaces the hidden set with the supplied columns")
    func hideAllColumns() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager, tableName: "users")
        coordinator.hideColumn("legacy")

        coordinator.hideAllColumns(["one", "two"])
        #expect(coordinator.selectedTabHiddenColumns == ["one", "two"])
    }

    @Test("pruneHiddenColumns drops names not in the current set")
    func pruneHiddenColumns() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager, tableName: "users")
        coordinator.hideAllColumns(["a", "b", "c", "d"])

        coordinator.pruneHiddenColumns(currentColumns: ["b", "d", "e"])
        #expect(coordinator.selectedTabHiddenColumns == ["b", "d"])
    }

    @Test("hideColumn is idempotent")
    func hideColumnIdempotent() {
        let (coordinator, tabManager) = makeCoordinator()
        _ = addTableTab(to: tabManager, tableName: "users")

        coordinator.hideColumn("name")
        coordinator.hideColumn("name")
        #expect(coordinator.selectedTabHiddenColumns == ["name"])
    }

    @Test("hideColumn mirrors into the corresponding TabSession")
    func hideColumnMirrorsIntoSession() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addTableTab(to: tabManager, tableName: "users")

        coordinator.hideColumn("name")

        let session = coordinator.tabSessionRegistry.session(for: tabId)
        #expect(session?.columnLayout.hiddenColumns == ["name"])
    }
}
