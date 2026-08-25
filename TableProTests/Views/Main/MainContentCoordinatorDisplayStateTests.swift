//
//  MainContentCoordinatorDisplayStateTests.swift
//  TableProTests
//

import AppKit
import CodeEditSourceEditor
import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("MainContentCoordinator retained grid display state")
@MainActor
struct MainContentCoordinatorDisplayStateTests {
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

    private func addTableTab(to tabManager: QueryTabManager, tableName: String) -> QueryTab {
        var tab = QueryTab(
            title: tableName,
            query: "SELECT * FROM \(tableName)",
            tabType: .table,
            tableName: tableName
        )
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return tab
    }

    private func seedRows(
        _ coordinator: MainContentCoordinator,
        for tabId: UUID,
        columns: [String] = ["id", "name"]
    ) {
        let rows = (0..<3).map { i in columns.map { PluginCellValue.text("\($0)_\(i)") } }
        let tableRows = TableRows.from(
            queryRows: rows,
            columns: columns,
            columnTypes: Array(repeating: .text(rawType: nil), count: columns.count)
        )
        coordinator.setActiveTableRows(tableRows, for: tabId)
    }

    @Test("Two tabs keep their own formatted text, and a switch between them reuses both")
    func alternatingTabsReuseTheirOwnState() {
        let (coordinator, tabManager) = makeCoordinator()
        let first = addTableTab(to: tabManager, tableName: "orders")
        let second = addTableTab(to: tabManager, tableName: "customers")
        seedRows(coordinator, for: first.id)
        seedRows(coordinator, for: second.id)

        let firstState = coordinator.displayState(for: tabManager.tabs[0])
        let secondState = coordinator.displayState(for: tabManager.tabs[1])
        #expect(firstState !== secondState)

        #expect(coordinator.displayState(for: tabManager.tabs[0]) === firstState)
        #expect(coordinator.displayState(for: tabManager.tabs[1]) === secondState)
        #expect(coordinator.displayState(for: tabManager.tabs[0]) === firstState)
    }

    @Test("Replacing a tab's rows replaces its formatted text")
    func newRowsReplaceTheState() {
        let (coordinator, tabManager) = makeCoordinator()
        let tab = addTableTab(to: tabManager, tableName: "orders")
        seedRows(coordinator, for: tab.id)
        let before = coordinator.displayState(for: tabManager.tabs[0])

        seedRows(coordinator, for: tab.id)
        #expect(coordinator.displayState(for: tabManager.tabs[0]) !== before)
    }

    @Test("An in-place edit keeps the text formatted for the rest of the page")
    func inPlaceEditKeepsTheState() {
        let (coordinator, tabManager) = makeCoordinator()
        let tab = addTableTab(to: tabManager, tableName: "orders")
        seedRows(coordinator, for: tab.id)
        let before = coordinator.displayState(for: tabManager.tabs[0])

        coordinator.tabSessionRegistry.updateTableRows(for: tab.id) { _ in }
        #expect(coordinator.displayState(for: tabManager.tabs[0]) === before)
    }

    @Test("A different set of columns replaces the formatted text")
    func newColumnsReplaceTheState() {
        let (coordinator, tabManager) = makeCoordinator()
        let tab = addTableTab(to: tabManager, tableName: "orders")
        seedRows(coordinator, for: tab.id, columns: ["id", "name"])
        let before = coordinator.displayState(for: tabManager.tabs[0])

        coordinator.tabSessionRegistry.setTableRows(
            TableRows.from(
                queryRows: [[.text("1")]],
                columns: ["id"],
                columnTypes: [.text(rawType: nil)]
            ),
            for: tab.id
        )
        #expect(coordinator.displayState(for: tabManager.tabs[0]) !== before)
    }

    @Test("Evicting a tab's rows drops the text formatted from them")
    func evictionDropsTheState() {
        let (coordinator, tabManager) = makeCoordinator()
        let first = addTableTab(to: tabManager, tableName: "orders")
        let second = addTableTab(to: tabManager, tableName: "customers")
        seedRows(coordinator, for: first.id)
        seedRows(coordinator, for: second.id)
        _ = coordinator.displayState(for: tabManager.tabs[0])
        #expect(coordinator.displayStateCache[first.id] != nil)

        #expect(coordinator.evictReloadableTableRows(for: first.id))
        #expect(coordinator.displayStateCache[first.id] == nil)
    }

    @Test("Closed tabs take their formatted text with them")
    func closingATabPrunesTheState() {
        let (coordinator, tabManager) = makeCoordinator()
        let first = addTableTab(to: tabManager, tableName: "orders")
        let second = addTableTab(to: tabManager, tableName: "customers")
        seedRows(coordinator, for: first.id)
        seedRows(coordinator, for: second.id)
        _ = coordinator.displayState(for: tabManager.tabs[0])
        _ = coordinator.displayState(for: tabManager.tabs[1])

        coordinator.cleanupTabCaches(openTabIds: [second.id])
        #expect(coordinator.displayStateCache[first.id] == nil)
        #expect(coordinator.displayStateCache[second.id] != nil)
    }

    @Test("A tab switch is not a content change")
    func switchingDoesNotReportAContentChange() {
        let (coordinator, tabManager) = makeCoordinator()
        let first = addTableTab(to: tabManager, tableName: "orders")
        let second = addTableTab(to: tabManager, tableName: "customers")
        seedRows(coordinator, for: first.id)
        seedRows(coordinator, for: second.id)

        let before = coordinator.changeManager.reloadVersion
        tabManager.selectedTabId = first.id
        coordinator.handleTabChange(from: second.id, to: first.id, tabs: tabManager.tabs)
        #expect(coordinator.changeManager.reloadVersion == before)
    }
}
