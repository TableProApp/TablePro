//
//  TableViewCoordinatorColumnJumpTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class ColumnJumpLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@Suite("Jump to Column in the grid")
@MainActor
struct TableViewCoordinatorColumnJumpTests {
    private func makeCoordinator(
        columns: [String] = ["id", "name", "email"],
        hiddenColumns: Set<String> = [],
        rowCount: Int = 2
    ) -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: ColumnJumpLayoutPersister()
        )
        let rows = (0..<rowCount).map { row in columns.map { PluginCellValue.text("\($0) \(row)") } }
        let tableRows = TableRows.from(
            queryRows: rows,
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: columns.count)
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()

        let tableView = KeyHandlingTableView()
        tableView.coordinator = coordinator
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView
        reconcile(coordinator, hiddenColumns: hiddenColumns)
        tableView.reloadData()
        return coordinator
    }

    private func reconcile(_ coordinator: TableViewCoordinator, hiddenColumns: Set<String>) {
        guard let tableView = coordinator.tableView else { return }
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: [],
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: hiddenColumns,
            widthCalculator: { _, _ in 100 }
        )
        coordinator.invalidateColumnIndexCache()
    }

    @Test("A jump puts the cell cursor in the column on the first row when nothing is selected")
    func jumpSeedsTheCursor() throws {
        let coordinator = makeCoordinator()
        let tableView = try #require(coordinator.tableView as? KeyHandlingTableView)

        #expect(coordinator.jumpToColumn(dataIndex: 2))

        #expect(tableView.selectedRow == 0)
        #expect(tableView.focusedRow == 0)
        #expect(tableView.focusedColumn == coordinator.tableColumnIndex(for: 2))
        #expect(coordinator.focusedDataColumnIndex == 2)
    }

    @Test("A jump keeps the selected row")
    func jumpKeepsTheSelectedRow() throws {
        let coordinator = makeCoordinator()
        let tableView = try #require(coordinator.tableView as? KeyHandlingTableView)
        tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        #expect(coordinator.jumpToColumn(dataIndex: 1))

        #expect(tableView.selectedRow == 1)
        #expect(tableView.focusedRow == 1)
        #expect(coordinator.focusedDataColumnIndex == 1)
    }

    @Test("A hidden column is refused, and the cursor is left where it was")
    func hiddenColumnIsRefused() throws {
        let coordinator = makeCoordinator(hiddenColumns: ["name"])
        let tableView = try #require(coordinator.tableView as? KeyHandlingTableView)

        #expect(coordinator.jumpToColumn(dataIndex: 1) == false)

        #expect(tableView.selectedRow == -1)
        #expect(coordinator.focusedDataColumnIndex == nil)
    }

    private func parked(
        _ name: String,
        dataIndex: Int? = nil,
        tableKey: ColumnLayoutTableKey? = nil,
        awaitsResultReplacement: Bool = false
    ) -> PendingColumnJump {
        PendingColumnJump(
            name: name,
            dataIndex: dataIndex,
            tableKey: tableKey,
            awaitsResultReplacement: awaitsResultReplacement
        )
    }

    @Test("A parked jump waits for the column to be presented, then lands once")
    func pendingJumpLandsWhenPresented() throws {
        let coordinator = makeCoordinator(hiddenColumns: ["name"])
        let pending = parked("name")
        coordinator.pendingColumnJump = pending

        coordinator.consumePendingColumnJump(contentReplaced: false)
        #expect(coordinator.pendingColumnJump == pending)
        #expect(coordinator.focusedDataColumnIndex == nil)

        reconcile(coordinator, hiddenColumns: [])
        coordinator.consumePendingColumnJump(contentReplaced: false)

        #expect(coordinator.pendingColumnJump == nil)
        #expect(coordinator.focusedDataColumnIndex == 1)
    }

    /// A name resolves to the last of two same-named columns, so a parked jump keeps the index the
    /// reader chose and lands on that one.
    @Test("A parked jump on a duplicate name lands on the chosen column")
    func pendingJumpKeepsTheChosenDuplicate() throws {
        let coordinator = makeCoordinator(columns: ["id", "name", "name"], hiddenColumns: ["name"])
        coordinator.pendingColumnJump = parked("name", dataIndex: 1)

        reconcile(coordinator, hiddenColumns: [])
        coordinator.consumePendingColumnJump(contentReplaced: false)

        #expect(coordinator.pendingColumnJump == nil)
        #expect(coordinator.focusedDataColumnIndex == 1)
    }

    /// A table tab refetches to show a column, and a key or sort column is fetched while hidden,
    /// so the interim update that unhides it must not land the jump the refetch would then undo.
    @Test("A table tab's parked jump waits for the refetched result")
    func pendingJumpOnATableTabWaitsForTheResult() throws {
        let coordinator = makeCoordinator(hiddenColumns: ["name"])
        let pending = parked("name", dataIndex: 1, awaitsResultReplacement: true)
        coordinator.pendingColumnJump = pending
        reconcile(coordinator, hiddenColumns: [])

        coordinator.consumePendingColumnJump(contentReplaced: false)
        #expect(coordinator.pendingColumnJump == pending)
        #expect(coordinator.focusedDataColumnIndex == nil)

        coordinator.consumePendingColumnJump(contentReplaced: true)
        #expect(coordinator.pendingColumnJump == nil)
        #expect(coordinator.focusedDataColumnIndex == 1)
    }

    @Test("A new result that lacks the column drops the parked jump instead of arming it forever")
    func replacementWithoutTheColumnDropsThePendingJump() throws {
        let coordinator = makeCoordinator(hiddenColumns: ["name"])
        coordinator.pendingColumnJump = parked("elsewhere")

        coordinator.consumePendingColumnJump(contentReplaced: false)
        #expect(coordinator.pendingColumnJump != nil)

        coordinator.consumePendingColumnJump(contentReplaced: true)
        #expect(coordinator.pendingColumnJump == nil)
    }

    @Test("A jump that lands supersedes a jump still parked")
    func directJumpSupersedesThePendingJump() throws {
        let coordinator = makeCoordinator(hiddenColumns: ["name"])
        coordinator.pendingColumnJump = parked("name", dataIndex: 1)

        #expect(coordinator.jumpToColumn(dataIndex: 2))

        #expect(coordinator.pendingColumnJump == nil)
        #expect(coordinator.focusedDataColumnIndex == 2)
    }

    @Test("A parked jump made against another table is dropped")
    func pendingJumpForAnotherTableIsDropped() throws {
        let coordinator = makeCoordinator(hiddenColumns: ["name"])
        let otherTable = ColumnLayoutTableKey(
            connectionId: UUID(),
            databaseName: "db",
            schemaName: nil,
            tableName: "other"
        )
        coordinator.pendingColumnJump = parked("name", dataIndex: 1, tableKey: otherTable)
        reconcile(coordinator, hiddenColumns: [])

        coordinator.consumePendingColumnJump(contentReplaced: false)

        #expect(coordinator.pendingColumnJump == nil)
        #expect(coordinator.focusedDataColumnIndex == nil)
    }

    @Test("A jump with no rows still scrolls to the column without seeding a cursor")
    func jumpWithoutRows() throws {
        let coordinator = makeCoordinator(rowCount: 0)
        let tableView = try #require(coordinator.tableView as? KeyHandlingTableView)

        #expect(coordinator.jumpToColumn(dataIndex: 2))

        #expect(tableView.selectedRow == -1)
        #expect(coordinator.focusedDataColumnIndex == nil)
    }

    @Test("Releasing the grid drops a parked jump")
    func releaseDropsPendingJump() {
        let coordinator = makeCoordinator(hiddenColumns: ["name"])
        coordinator.pendingColumnJump = parked("name", dataIndex: 1)

        coordinator.releaseData()

        #expect(coordinator.pendingColumnJump == nil)
    }
}
