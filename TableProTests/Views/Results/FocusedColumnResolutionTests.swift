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
/// ahead of the data and which the reader can reorder. Preview FK Reference used to turn it into a
/// data index by subtracting 1, so the menu command previewed the wrong column or silently nothing
/// while the key-equivalent path on the same cell worked.
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
    /// from the selection change. Seeding it with a fixed position landed on chrome, and every
    /// command that reads the cursor then resolved it to no column at all: Return opened no editor
    /// while the menu item still validated as enabled (#2381).
    @Test("A selection with no cell cursor seeds one on a data column, not chrome")
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
    /// Return has to open the editor on it. Seeded onto chrome, every step past the seed resolved to
    /// no column and the keystroke was swallowed (#2381).
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

    /// Resolution goes through the column's own identifier. Subtracting a fixed offset from the
    /// position happens to agree while the row-number column is the only chrome, and stops agreeing
    /// the moment the reader reorders a column or the grid grows another chrome column.
    @Test("A data column resolves by identity, not by its distance from the start")
    func dataColumnsResolveByIdentity() throws {
        let grid = makeGrid(columns: ["id", "name", "customer_id"])
        let tableColumn = try #require(tableColumnIndex(of: "customer_id", in: grid))

        #expect(DataGridView.dataColumnIndex(for: tableColumn, in: grid.tableView, schema: grid.schema) == 2)

        grid.tableView.moveColumn(tableColumn, toColumn: 1)
        let moved = try #require(tableColumnIndex(of: "customer_id", in: grid))
        #expect(DataGridView.dataColumnIndex(for: moved, in: grid.tableView, schema: grid.schema) == 2)
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

    /// The row-number column sits in `tableColumns` too, so a fixed position names chrome rather
    /// than data.
    @Test("The row-number column is not a data column")
    func chromeColumnsAreNotData() {
        let grid = makeGrid(columns: ["id", "name"])

        let chrome = grid.tableView.tableColumns.indices.filter {
            DataGridView.dataColumnIndex(for: $0, in: grid.tableView, schema: grid.schema) == nil
        }

        #expect(chrome == [0])
    }
}
