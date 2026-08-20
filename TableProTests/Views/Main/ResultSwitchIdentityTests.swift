//
//  ResultSwitchIdentityTests.swift
//  TableProTests
//
//  A query tab can hold several results, but its table context only ever describes the newest
//  execution, and every edit is generated from that context. Clicking back to a pinned result used
//  to leave the grid editable against whichever table ran last, so saving an edit sent the UPDATE
//  to the wrong table (#2243).
//

import AppKit
import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Result switch identity")
@MainActor
struct ResultSwitchIdentityTests {
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

    private func makeResult(label: String, table: String, columns: [String], isPinned: Bool = false) -> ResultSet {
        let result = ResultSet(
            label: label,
            tableRows: TableRows.from(queryRows: [], columns: columns, columnTypes: [])
        )
        result.isPinned = isPinned
        result.origin = ResultOrigin(
            tableName: table,
            schemaName: nil,
            databaseName: "",
            primaryKeyColumns: ["id"],
            isEditable: true,
            isView: false,
            keysResolved: true
        )
        return result
    }

    @Test("Switching back to a pinned result moves the tab's table onto that result")
    func switchRestoresTheResultsOwnTable() throws {
        let (coordinator, tabManager) = makeCoordinator()
        tabManager.addTab(databaseName: "db")
        let tabIndex = try #require(tabManager.selectedTabIndex)
        let tabId = tabManager.tabs[tabIndex].id

        let users = makeResult(label: "users", table: "users", columns: ["id", "name"], isPinned: true)
        let orders = makeResult(label: "orders", table: "orders", columns: ["id", "total"])
        tabManager.mutate(at: tabIndex) { tab in
            tab.display.resultSets = [users, orders]
            tab.display.activeResultSetId = orders.id
            tab.tableContext.tableName = "orders"
            tab.tableContext.primaryKeyColumns = ["id"]
            tab.tableContext.isEditable = true
        }

        coordinator.applyResultSetSwitch(to: users.id, in: tabId)

        #expect(tabManager.tabs[tabIndex].tableContext.tableName == "users")
        #expect(tabManager.tabs[tabIndex].tableContext.isEditable)
        #expect(coordinator.changeManager.tableName == "users")
    }

    @Test("The switch bumps schemaVersion so the grid reconfigures")
    func switchBumpsSchemaVersion() throws {
        let (coordinator, tabManager) = makeCoordinator()
        tabManager.addTab(databaseName: "db")
        let tabIndex = try #require(tabManager.selectedTabIndex)
        let tabId = tabManager.tabs[tabIndex].id

        let first = makeResult(label: "users", table: "users", columns: ["id"])
        let second = makeResult(label: "orders", table: "orders", columns: ["id"])
        tabManager.mutate(at: tabIndex) { tab in
            tab.display.resultSets = [first, second]
            tab.display.activeResultSetId = second.id
        }
        let before = tabManager.tabs[tabIndex].schemaVersion

        coordinator.applyResultSetSwitch(to: first.id, in: tabId)

        #expect(tabManager.tabs[tabIndex].schemaVersion > before)
    }

    @Test("A result that captured no table leaves the tab with nothing to write to")
    func switchToUnidentifiedResultRefusesEditing() throws {
        let (coordinator, tabManager) = makeCoordinator()
        tabManager.addTab(databaseName: "db")
        let tabIndex = try #require(tabManager.selectedTabIndex)
        let tabId = tabManager.tabs[tabIndex].id

        let users = makeResult(label: "users", table: "users", columns: ["id"])
        let joined = ResultSet(label: "joined", tableRows: TableRows.from(queryRows: [], columns: ["id"], columnTypes: []))
        tabManager.mutate(at: tabIndex) { tab in
            tab.display.resultSets = [users, joined]
            tab.display.activeResultSetId = users.id
            tab.tableContext.tableName = "users"
            tab.tableContext.isEditable = true
        }

        coordinator.applyResultSetSwitch(to: joined.id, in: tabId)

        #expect(tabManager.tabs[tabIndex].tableContext.tableName == nil)
        #expect(!tabManager.tabs[tabIndex].tableContext.isEditable)
        #expect(coordinator.activeResultEditRefusal == .unknownTable)
    }

    @Test("Switching hands the outgoing result its rows so it does not serve another result's")
    func switchGivesTheOutgoingResultItsRowsBack() throws {
        let (coordinator, tabManager) = makeCoordinator()
        tabManager.addTab(databaseName: "db")
        let tabIndex = try #require(tabManager.selectedTabIndex)
        let tabId = tabManager.tabs[tabIndex].id

        let first = makeResult(label: "users", table: "users", columns: ["id"])
        let second = makeResult(label: "orders", table: "orders", columns: ["id"])
        tabManager.mutate(at: tabIndex) { tab in
            tab.display.resultSets = [first, second]
            tab.display.activeResultSetId = first.id
        }
        let fetched = TableRows.from(
            queryRows: [[PluginCellValue.text("1")]],
            columns: ["id"],
            columnTypes: []
        )
        coordinator.setActiveTableRows(fetched, for: tabId)

        coordinator.applyResultSetSwitch(to: second.id, in: tabId)

        #expect(first.tableRows.rows.count == 1)
        #expect(coordinator.tabSessionRegistry.tableRows(for: tabId).rows.isEmpty)
    }
}
