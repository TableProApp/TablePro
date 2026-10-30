//
//  TableTabRowRetentionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProUtilities
import Testing

@MainActor
struct TableTabRowRetentionTests {
    private let fixtures = CoordinatorFixtures()
    private static let rowCount = 10

    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let fixture = fixtures.make()
        return (fixture.coordinator, fixture.tabManager)
    }

    private func addLoadedTableTab(
        _ coordinator: MainContentCoordinator,
        _ tabManager: QueryTabManager,
        tableName: String
    ) -> UUID {
        var tab = QueryTab(title: tableName, query: "SELECT * FROM \(tableName)", tabType: .table, tableName: tableName)
        tab.execution.lastExecutedAt = Date()
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        let rows = (0..<Self.rowCount).map { [PluginCellValue.text("\($0)"), PluginCellValue.text("row \($0)")] }
        let tableRows = TableRows.from(
            queryRows: rows,
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: nil), .text(rawType: nil)]
        )
        coordinator.setActiveTableRows(tableRows, for: tab.id)
        return tab.id
    }

    private func tab(_ id: UUID, in tabManager: QueryTabManager) throws -> QueryTab {
        try #require(tabManager.tabs.first { $0.id == id })
    }

    // A contract test: the old budget eviction ran a tick after the switch, which only a fixed sleep could observe.
    @Test("Switching through more table tabs than the cache budget keeps every tab's rows")
    func switchingKeepsEveryTabsRows() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let ids = (0..<(GridDisplayCacheBudget.unmountedGrids() + 3)).map {
            addLoadedTableTab(coordinator, tabManager, tableName: "table_\($0)")
        }

        var outgoing = tabManager.selectedTabId
        for incoming in ids {
            tabManager.selectedTabId = incoming
            coordinator.handleTabChange(from: outgoing, to: incoming, tabs: tabManager.tabs)
            _ = coordinator.displayState(for: try tab(incoming, in: tabManager))
            outgoing = incoming
        }

        #expect(coordinator.displayStateCache[ids[0]] == nil)
        for id in ids {
            let current = try tab(id, in: tabManager)
            #expect(coordinator.tabSessionRegistry.tableRows(for: id).rows.count == Self.rowCount)
            #expect(coordinator.canAutoLoadTableTab(current) == false)
        }
    }

    @Test("The display cache gives back only the formatted text used longest ago")
    func pruneReleasesOnlyTheOldestText() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let ids = (0..<(GridDisplayCacheBudget.unmountedGrids() + 2)).map {
            addLoadedTableTab(coordinator, tabManager, tableName: "table_\($0)")
        }

        for id in ids {
            _ = coordinator.displayState(for: try tab(id, in: tabManager))
        }

        #expect(coordinator.displayStateCache[ids[0]] == nil)
        for id in ids.dropFirst() {
            #expect(coordinator.displayStateCache[id] != nil)
        }
        for id in ids {
            #expect(coordinator.tabSessionRegistry.tableRows(for: id).rows.count == Self.rowCount)
        }
    }

    // Holds without waiting: the old 5 s eviction would need a fixed sleep to observe, which the test rules forbid.
    @Test("Losing key status keeps every background table tab's rows")
    func resigningKeyKeepsRows() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let background = addLoadedTableTab(coordinator, tabManager, tableName: "orders")
        let selected = addLoadedTableTab(coordinator, tabManager, tableName: "customers")
        coordinator.handleWindowDidBecomeKey()

        coordinator.handleWindowDidResignKey()

        #expect(coordinator.isKeyWindow == false)
        for id in [background, selected] {
            let current = try tab(id, in: tabManager)
            #expect(coordinator.tabSessionRegistry.tableRows(for: id).rows.count == Self.rowCount)
            #expect(coordinator.canAutoLoadTableTab(current) == false)
        }
    }

    @Test("Rows cannot be edited while a load that replaces them is running")
    func rowsAreReadOnlyWhileReplaced() {
        let (coordinator, tabManager) = makeCoordinator()
        let tabId = addLoadedTableTab(coordinator, tabManager, tableName: "orders")
        tabManager.mutate(tabId: tabId) { $0.tableContext.isEditable = true }
        #expect(coordinator.canEditActiveResult)

        let claim = coordinator.tabExecution.claim(tabId)
        #expect(coordinator.canEditActiveResult == false)

        let settled = coordinator.tabExecution.settle(claim)
        #expect(settled)
        #expect(coordinator.canEditActiveResult)
    }

    @Test("A tab whose table TablePro changed keeps its rows and reloads when shown")
    func changedTableReloadsOverItsRows() throws {
        let (coordinator, tabManager) = makeCoordinator()
        let background = addLoadedTableTab(coordinator, tabManager, tableName: "orders")
        _ = addLoadedTableTab(coordinator, tabManager, tableName: "customers")

        coordinator.tabSessionRegistry.recordChange(
            TableFreshness.Change(extent: .rows, at: .now),
            for: background
        )

        let current = try tab(background, in: tabManager)
        #expect(coordinator.tabSessionRegistry.tableRows(for: background).rows.count == Self.rowCount)
        #expect(coordinator.canAutoLoadTableTab(current))
    }
}
