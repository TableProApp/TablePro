//
//  FocusedColumnResolutionTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class FocusedColumnLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// `focusedColumn` is a position in `tableView.tableColumns`, which carries the row-number column
/// and a hidden spacer ahead of the data and which the reader can reorder. Preview FK Reference
/// used to turn it into a data index by subtracting 1, so the menu command previewed the wrong
/// column or silently nothing while the key-equivalent path on the same cell worked.
@Suite("Focused column resolution")
@MainActor
struct FocusedColumnResolutionTests {
    private func makeGrid(columns: [String]) -> (tableView: NSTableView, schema: ColumnIdentitySchema) {
        let tableView = NSTableView()
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        let rowNumberColumn = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        rowNumberColumn.width = 40
        tableView.addTableColumn(rowNumberColumn)

        let schema = ColumnIdentitySchema(columns: columns)
        DataGridColumnPool().reconcile(
            tableView: tableView,
            schema: schema,
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: columns.count),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: { _, _ in 100 }
        )
        return (tableView, schema)
    }

    private func makeCoordinator(columns: [String]) -> TableViewCoordinator {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: FocusedColumnLayoutPersister()
        )
        let rows = columns.map { PluginCellValue.text($0) }
        let tableRows = TableRows.from(
            queryRows: [rows],
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
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: [],
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: { _, _ in 100 }
        )
        tableView.reloadData()
        return coordinator
    }

    private func tableColumnIndex(of name: String, in grid: (tableView: NSTableView, schema: ColumnIdentitySchema)) -> Int? {
        guard let identifier = grid.schema.identifier(for: grid.schema.dataIndex(forColumnName: name) ?? -1) else {
            return nil
        }
        let index = grid.tableView.column(withIdentifier: identifier)
        return index >= 0 ? index : nil
    }

    /// Moving the selection with the keyboard leaves no cell cursor behind, so the grid seeds one
    /// from the selection change. Seeding it with a fixed position lands on the window's leading
    /// spacer, and every command that reads the cursor then resolves it to no column at all: Return
    /// opens no editor while the menu item still validates as enabled (#2381).
    @Test("A selection with no cell cursor seeds one on a data column, not a spacer")
    func selectionSeedsTheCursorOnADataColumn() throws {
        let coordinator = makeCoordinator(columns: ["id", "name"])
        let tableView = try #require(coordinator.tableView as? KeyHandlingTableView)
        tableView.focusedRow = -1
        tableView.focusedColumn = -1

        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: tableView)
        )

        #expect(coordinator.presentsColumn(atTableColumnIndex: tableView.focusedColumn))
        #expect(
            DataGridView.dataColumnIndex(
                for: tableView.focusedColumn,
                in: tableView,
                schema: coordinator.identitySchema
            ) == 0
        )
    }

    /// The whole keystroke, not just the seed: with no cell cursor, a selection change seeds one and
    /// Return has to open the editor on it. Seeded onto a spacer, every step past the seed resolved
    /// to no column and the keystroke was swallowed (#2381).
    @Test("Return opens the editor on the column a keyboard selection seeded")
    func returnOpensTheEditorOnTheSeededColumn() throws {
        let coordinator = makeCoordinator(columns: ["id", "name"])
        let tableView = try #require(coordinator.tableView as? KeyHandlingTableView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = tableView
        tableView.layoutSubtreeIfNeeded()
        tableView.focusedRow = -1
        tableView.focusedColumn = -1

        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: tableView)
        )
        tableView.insertNewline(nil)

        #expect(coordinator.overlayEditor != nil)
    }

    @Test("A data column does not sit one place after its data index")
    func dataColumnsAreNotOffsetByOne() throws {
        let grid = makeGrid(columns: ["id", "name", "customer_id"])
        let tableColumn = try #require(tableColumnIndex(of: "customer_id", in: grid))

        let resolved = DataGridView.dataColumnIndex(for: tableColumn, in: grid.tableView, schema: grid.schema)

        #expect(resolved == 2)
        #expect(tableColumn - 1 != resolved, "the subtract-one mapping is what shipped broken")
    }

    @Test("Every data column resolves back to its own index")
    func everyColumnRoundTrips() throws {
        let names = ["id", "name", "customer_id", "total"]
        let grid = makeGrid(columns: names)

        for (dataIndex, name) in names.enumerated() {
            let tableColumn = try #require(tableColumnIndex(of: name, in: grid))
            #expect(DataGridView.dataColumnIndex(for: tableColumn, in: grid.tableView, schema: grid.schema) == dataIndex)
        }
    }

    @Test("Reordering a column moves it without changing what it resolves to")
    func reorderingKeepsTheMapping() throws {
        let grid = makeGrid(columns: ["id", "name", "customer_id"])
        let before = try #require(tableColumnIndex(of: "customer_id", in: grid))
        let firstData = try #require(tableColumnIndex(of: "id", in: grid))

        grid.tableView.moveColumn(before, toColumn: firstData)
        let after = try #require(tableColumnIndex(of: "customer_id", in: grid))

        #expect(after != before)
        #expect(DataGridView.dataColumnIndex(for: after, in: grid.tableView, schema: grid.schema) == 2)
    }

    /// The row-number column and the window's two spacers all sit in `tableColumns`, and one spacer
    /// sits ahead of the first data column, so a fixed position names chrome rather than data.
    @Test("Neither the row-number column nor the window's spacers are data columns")
    func chromeColumnsAreNotData() {
        let grid = makeGrid(columns: ["id", "name"])

        let chrome = grid.tableView.tableColumns.indices.filter {
            DataGridView.dataColumnIndex(for: $0, in: grid.tableView, schema: grid.schema) == nil
        }

        #expect(chrome.contains(0))
        #expect(chrome.count == 3)
    }
}
