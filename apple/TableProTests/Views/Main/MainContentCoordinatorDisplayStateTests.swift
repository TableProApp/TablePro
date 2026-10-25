//
//  MainContentCoordinatorDisplayStateTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
struct MainContentCoordinatorDisplayStateTests {
    private let fixtures = CoordinatorFixtures()

    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let fixture = fixtures.make()
        let tabManager = fixture.tabManager
        let coordinator = fixture.coordinator
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

    private func cache(_ coordinator: MainContentCoordinator, _ tabId: UUID, rows: [Int]) -> RowDisplayCache {
        let cache = coordinator.gridModel(forTab: tabId).display.cache
        for row in rows {
            cache.setBox(RowDisplayBox(["formatted \(row)", nil]), forID: .existing(row))
        }
        return cache
    }

    @Test("Two tabs keep their own model and formatted text, and a switch between them reuses both")
    func alternatingTabsReuseTheirOwnState() {
        let (coordinator, tabManager) = makeCoordinator()
        let first = addTableTab(to: tabManager, tableName: "orders")
        let second = addTableTab(to: tabManager, tableName: "customers")
        seedRows(coordinator, for: first.id)
        seedRows(coordinator, for: second.id)

        let firstModel = coordinator.gridModel(forTab: first.id)
        let secondModel = coordinator.gridModel(forTab: second.id)
        #expect(firstModel !== secondModel)
        #expect(firstModel.display !== secondModel.display)
        let firstCache = cache(coordinator, first.id, rows: [0])

        coordinator.handleTabChange(from: second.id, to: first.id, tabs: tabManager.tabs)
        coordinator.handleTabChange(from: first.id, to: second.id, tabs: tabManager.tabs)

        #expect(coordinator.gridModel(forTab: first.id) === firstModel)
        #expect(coordinator.gridModel(forTab: second.id) === secondModel)
        #expect(firstCache.box(forID: .existing(0)) != nil)
    }

    @Test("Replacing a tab's rows drops its formatted text")
    func newRowsReplaceTheState() {
        let (coordinator, tabManager) = makeCoordinator()
        let tab = addTableTab(to: tabManager, tableName: "orders")
        seedRows(coordinator, for: tab.id)
        let formatted = cache(coordinator, tab.id, rows: [0, 1])

        seedRows(coordinator, for: tab.id)

        #expect(formatted.box(forID: .existing(0)) == nil)
        #expect(formatted.box(forID: .existing(1)) == nil)
    }

    @Test("An in-place edit keeps the text formatted for the rest of the page")
    func inPlaceEditKeepsTheState() {
        let (coordinator, tabManager) = makeCoordinator()
        let tab = addTableTab(to: tabManager, tableName: "orders")
        seedRows(coordinator, for: tab.id)
        let formatted = cache(coordinator, tab.id, rows: [0, 1])

        coordinator.mutateActiveTableRows(for: tab.id) { rows in
            rows.edit(row: 0, column: 1, value: .text("edited"))
        }

        let editedRow = formatted.box(forID: .existing(0))?.values ?? []
        #expect(editedRow.compactMap { $0 }.isEmpty)
        #expect(formatted.box(forID: .existing(1))?.values.first == "formatted 1")
    }

    @Test("A different set of columns replaces the model's columns and its formatted text")
    func newColumnsReplaceTheState() {
        let (coordinator, tabManager) = makeCoordinator()
        let tab = addTableTab(to: tabManager, tableName: "orders")
        seedRows(coordinator, for: tab.id, columns: ["id", "name"])
        let formatted = cache(coordinator, tab.id, rows: [0])

        seedRows(coordinator, for: tab.id, columns: ["id"])

        #expect(coordinator.gridModel(forTab: tab.id).columns.count == 1)
        #expect(formatted.box(forID: .existing(0)) == nil)
    }

    @Test("Evicting a tab's rows drops the text formatted from them")
    func evictionDropsTheState() {
        let (coordinator, tabManager) = makeCoordinator()
        let first = addTableTab(to: tabManager, tableName: "orders")
        let second = addTableTab(to: tabManager, tableName: "customers")
        seedRows(coordinator, for: first.id)
        seedRows(coordinator, for: second.id)
        let formatted = cache(coordinator, first.id, rows: [0])

        #expect(coordinator.evictReloadableTableRows(for: first.id))
        #expect(formatted.box(forID: .existing(0)) == nil)
        #expect(coordinator.gridModel(forTab: first.id).rowCount == 0)
    }

    @Test("Closed tabs take their grid model with them")
    func closingATabPrunesTheState() {
        let (coordinator, tabManager) = makeCoordinator()
        let first = addTableTab(to: tabManager, tableName: "orders")
        let second = addTableTab(to: tabManager, tableName: "customers")
        seedRows(coordinator, for: first.id)
        seedRows(coordinator, for: second.id)
        _ = coordinator.gridModel(forTab: first.id)
        _ = coordinator.gridModel(forTab: second.id)

        coordinator.cleanupTabCaches(openTabIds: [second.id])

        #expect(coordinator.existingGridModel(forTab: first.id) == nil)
        #expect(coordinator.existingGridModel(forTab: second.id) != nil)
    }

    // Formatted text an unmounted model kept goes stale once the settings it was formatted with move.
    @Test("A model whose display inputs moved drops its formatted text before it is shown again")
    func staleDisplayInputsDropTheState() {
        let (coordinator, tabManager) = makeCoordinator()
        let tab = addTableTab(to: tabManager, tableName: "orders")
        seedRows(coordinator, for: tab.id)
        let formatted = cache(coordinator, tab.id, rows: [0])

        coordinator.prepareGridModelForDisplay(forTab: tab.id)
        #expect(formatted.box(forID: .existing(0)) != nil)

        coordinator.dataGridEntries[tab.id]?.displayInputs = nil
        coordinator.prepareGridModelForDisplay(forTab: tab.id)
        #expect(formatted.box(forID: .existing(0)) == nil)
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
