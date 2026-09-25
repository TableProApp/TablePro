//
//  GridReloadViewportTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class NoopReloadLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
struct GridReloadViewportTests {
    private struct Fixture {
        let coordinator: MainContentCoordinator
        let tabId: UUID
        let delegate: DataTabGridDelegate
        let grid: TableViewCoordinator
        let tableView: NSTableView
    }

    private static func rows(ids: [Int]) -> TableRows {
        TableRows.from(
            queryRows: ids.map { [.text("\($0)"), .text("name-\($0)")] },
            columns: ["id", "name"],
            columnTypes: [.text(rawType: "INTEGER"), .text(rawType: "TEXT")],
            hasAuthoritativeSchema: true
        )
    }

    private func makeFixture(tabType: TabType = .table, mode: ResultsViewMode = .data) -> Fixture {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        var tab = QueryTab(title: "users", query: "SELECT * FROM users", tabType: tabType, tableName: "users")
        tab.tableContext.primaryKeyColumns = ["id"]
        tab.display.resultsViewMode = mode
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id

        let delegate = DataTabGridDelegate()
        let tableView = NSTableView()
        let grid = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: NoopReloadLayoutPersister()
        )
        grid.tableView = tableView
        delegate.dataGridAttach(tableViewCoordinator: grid)
        coordinator.dataTabDelegate = delegate

        coordinator.setActiveTableRows(Self.rows(ids: Array(1 ... 10)), for: tab.id)
        _ = coordinator.takeViewportPlacement(forTab: tab.id)
        return Fixture(coordinator: coordinator, tabId: tab.id, delegate: delegate, grid: grid, tableView: tableView)
    }

    @Test("A table tab's grid on screen is handed its placement once")
    func mountedGridTakesItsPlacementOnce() {
        let fixture = makeFixture()
        defer { fixture.coordinator.teardown() }

        fixture.coordinator.setActiveTableRows(Self.rows(ids: Array(1 ... 10)), for: fixture.tabId)

        #expect(fixture.coordinator.takeViewportPlacement(forTab: fixture.tabId) == .firstRow)
        #expect(fixture.coordinator.takeViewportPlacement(forTab: fixture.tabId) == nil)
        withExtendedLifetime(fixture) {}
    }

    @Test("A grid that is not on screen is handed no placement")
    func unmountedGridStagesNothing() {
        let fixture = makeFixture(mode: .json)
        defer { fixture.coordinator.teardown() }

        fixture.coordinator.setActiveTableRows(Self.rows(ids: Array(0 ... 10)), for: fixture.tabId, viewport: .keepPlace)

        #expect(fixture.coordinator.takeViewportPlacement(forTab: fixture.tabId) == nil)
        withExtendedLifetime(fixture) {}
    }

    @Test("A query tab's result keeps the grid where AppKit leaves it")
    func queryTabStagesNothing() {
        let fixture = makeFixture(tabType: .query)
        defer { fixture.coordinator.teardown() }

        fixture.coordinator.setActiveTableRows(Self.rows(ids: Array(0 ... 10)), for: fixture.tabId, viewport: .firstRow)

        #expect(fixture.coordinator.takeViewportPlacement(forTab: fixture.tabId) == nil)
        withExtendedLifetime(fixture) {}
    }

    @Test("A placement staged for rows that were replaced since is never applied")
    func placementForReplacedRowsIsDropped() {
        let fixture = makeFixture()
        defer { fixture.coordinator.teardown() }
        fixture.coordinator.setActiveTableRows(Self.rows(ids: Array(1 ... 10)), for: fixture.tabId)

        fixture.coordinator.tabSessionRegistry.setTableRows(Self.rows(ids: [42]), for: fixture.tabId)

        #expect(fixture.coordinator.takeViewportPlacement(forTab: fixture.tabId) == nil)
        withExtendedLifetime(fixture) {}
    }

    @Test("Switching results in a query tab stages no placement")
    func resultSwitchStagesNothing() {
        let fixture = makeFixture(tabType: .query)
        defer { fixture.coordinator.teardown() }
        let first = ResultSet(label: "first", tableRows: Self.rows(ids: Array(1 ... 5)))
        let second = ResultSet(label: "second", tableRows: Self.rows(ids: Array(6 ... 9)))
        fixture.coordinator.tabManager.mutate(tabId: fixture.tabId) { tab in
            tab.display.resultSets = [first, second]
            tab.display.activeResultSetId = first.id
        }

        fixture.coordinator.applyResultSetSwitch(to: second.id, in: fixture.tabId)

        #expect(fixture.coordinator.takeViewportPlacement(forTab: fixture.tabId) == nil)
        withExtendedLifetime(fixture) {}
    }
}
