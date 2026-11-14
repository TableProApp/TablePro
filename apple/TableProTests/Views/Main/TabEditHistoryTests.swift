//
//  TabEditHistoryTests.swift
//  TableProTests
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct TabEditHistoryTests {
    private func makeSUT() -> (MainContentCommandActions, MainContentCoordinator) {
        let connection = TestFixtures.makeConnection()
        let coordinator = SessionStateFactory.create(connection: connection, payload: nil).coordinator
        var selectedTables: Set<DatabaseTreeTableRef> = []
        var pendingTruncates: Set<DatabaseTreeTableRef> = []
        var pendingDeletes: Set<DatabaseTreeTableRef> = []
        var tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions] = [:]
        let actions = MainContentCommandActions(
            coordinator: coordinator,
            connection: connection,
            selectedTables: Binding(get: { selectedTables }, set: { selectedTables = $0 }),
            pendingTruncates: Binding(get: { pendingTruncates }, set: { pendingTruncates = $0 }),
            pendingDeletes: Binding(get: { pendingDeletes }, set: { pendingDeletes = $0 }),
            tableOperationOptions: Binding(get: { tableOperationOptions }, set: { tableOperationOptions = $0 }),
            trailingPaneState: TrailingPaneState()
        )
        return (actions, coordinator)
    }

    private func openTable(_ name: String, in coordinator: MainContentCoordinator) -> UUID {
        var tab = QueryTab(title: name, query: "SELECT * FROM \(name)", tabType: .table, tableName: name)
        tab.tableContext.isEditable = true
        tab.tableContext.primaryKeyColumns = ["id"]
        coordinator.tabManager.tabs.append(tab)
        coordinator.setActiveTableRows(
            TableRows.from(
                queryRows: [[.text("1"), .text("ada")], [.text("2"), .text("grace")]],
                columns: ["id", "name"],
                columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")]
            ),
            for: tab.id
        )
        select(tab.id, in: coordinator)
        return tab.id
    }

    private func select(_ tabId: UUID, in coordinator: MainContentCoordinator) {
        let outgoing = coordinator.tabManager.selectedTabId
        coordinator.tabManager.selectedTabId = tabId
        coordinator.handleTabChange(from: outgoing, to: tabId, tabs: coordinator.tabManager.tabs)
    }

    private func rename(row: Int, to name: String, in tabId: UUID, of coordinator: MainContentCoordinator) {
        let old: PluginCellValue = row == 0 ? .text("ada") : .text("grace")
        coordinator.changeManager(forTab: tabId).recordCellChange(
            rowID: .existing(row),
            columnIndex: 1,
            columnName: "name",
            oldValue: old,
            newValue: .text(name),
            originalRow: [.text("\(row + 1)"), old]
        )
    }

    @Test("Switching tabs and back keeps the data undo history with the edits")
    func switchingKeepsTheUndoHistory() {
        let (actions, coordinator) = makeSUT()
        let users = openTable("users", in: coordinator)
        rename(row: 0, to: "lovelace", in: users, of: coordinator)
        let orders = openTable("orders", in: coordinator)

        select(users, in: coordinator)

        #expect(coordinator.changeManager === coordinator.changeManager(forTab: users))
        #expect(coordinator.changeManager.hasChanges)
        #expect(actions.canUndo)

        actions.undoChange()

        #expect(!coordinator.changeManager(forTab: users).hasChanges)
        #expect(actions.canRedo)
        #expect(coordinator.existingChangeManager(forTab: orders)?.hasChanges != true)
    }

    @Test("Undo in one tab never reaches another tab's edits")
    func undoStaysInItsTab() {
        let (actions, coordinator) = makeSUT()
        let users = openTable("users", in: coordinator)
        rename(row: 0, to: "lovelace", in: users, of: coordinator)
        let orders = openTable("orders", in: coordinator)
        rename(row: 1, to: "hopper", in: orders, of: coordinator)

        actions.undoChange()

        #expect(!coordinator.changeManager(forTab: orders).hasChanges)
        #expect(coordinator.changeManager(forTab: users).hasChanges)
        #expect(!actions.canUndo)
    }

    @Test("Each tab's edits keep their own table while another tab is shown")
    func editsStayWithTheirTab() {
        let (_, coordinator) = makeSUT()
        let users = openTable("users", in: coordinator)
        rename(row: 0, to: "lovelace", in: users, of: coordinator)
        let orders = openTable("orders", in: coordinator)

        #expect(coordinator.changeManager(forTab: users).tableName == "users")
        #expect(coordinator.changeManager(forTab: orders).tableName == "orders")
        #expect(coordinator.changeManager(forTab: users).hasChanges)
        #expect(!coordinator.changeManager.hasChanges)
        #expect(coordinator.hasUnsavedWork(forTab: users))
        #expect(coordinator.selectedTabEdits.manager === coordinator.changeManager(forTab: orders))
    }

    @Test("A result that replaces a background tab's rows drops only that tab's edits")
    func replacedResultDropsOnlyItsTabsEdits() {
        let (_, coordinator) = makeSUT()
        let users = openTable("users", in: coordinator)
        rename(row: 0, to: "lovelace", in: users, of: coordinator)
        let orders = openTable("orders", in: coordinator)
        rename(row: 1, to: "hopper", in: orders, of: coordinator)

        coordinator.dropEdits(ofReplacedResultIn: users)

        #expect(!coordinator.changeManager(forTab: users).hasChanges)
        #expect(coordinator.changeManager(forTab: orders).hasChanges)
    }

    @Test("Closing a tab releases its edits and history")
    func closingReleasesTheTabsEdits() {
        let (_, coordinator) = makeSUT()
        let users = openTable("users", in: coordinator)
        rename(row: 0, to: "lovelace", in: users, of: coordinator)
        let orders = openTable("orders", in: coordinator)

        coordinator.releaseEdits(ofTab: users)

        #expect(coordinator.existingChangeManager(forTab: users) == nil)
        #expect(coordinator.existingChangeManager(forTab: orders) != nil)
    }

    @Test("A schema rename moves a background tab's staged edits without clearing them")
    func schemaRenameMovesStagedEdits() {
        let (actions, coordinator) = makeSUT()
        let users = openTable("users", in: coordinator)
        coordinator.tabManager.mutate(tabId: users) { tab in
            tab.tableContext.databaseName = "app"
            tab.tableContext.schemaName = "sales"
        }
        coordinator.changeManager(forTab: users).schemaName = "sales"
        rename(row: 0, to: "lovelace", in: users, of: coordinator)
        _ = openTable("orders", in: coordinator)

        coordinator.retargetTabs(database: "app", schema: "sales", toDatabase: "app", toSchema: "crm")
        select(users, in: coordinator)

        #expect(coordinator.changeManager.schemaName == "crm")
        #expect(coordinator.changeManager.hasChanges)
        #expect(actions.canUndo)
    }
}
