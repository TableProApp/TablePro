import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class DataGridRowViewCopyClipboard: ClipboardProvider {
    var text: String?
    var hasGridRowsValue = false

    func readText() -> String? { text }
    func readGridRows() -> GridRowsClipboardPayload? { nil }
    func writeText(_ text: String) { self.text = text; hasGridRowsValue = false }
    func writeCsv(_ csv: String) { text = csv; hasGridRowsValue = false }
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) { text = tsv; hasGridRowsValue = true }
    var hasText: Bool { text != nil }
    var hasGridRows: Bool { hasGridRowsValue }
}

@MainActor
private final class DataGridRowViewCopyLayoutPersister: ColumnLayoutPersisting {
    func load(for tableName: String, connectionId: UUID) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for tableName: String, connectionId: UUID) {}
    func clear(for tableName: String, connectionId: UUID) {}
}

@MainActor
private final class DataGridRowViewCopyDelegateSpy: DataGridViewDelegate {
    var copiedRows: Set<Int>?

    func dataGridCopyRows(_ indices: Set<Int>) {
        copiedRows = indices
    }
}

@Suite("DataGridRowView context menu copy")
@MainActor
struct DataGridRowViewCopyTests {
    private func makeCoordinator(
        rows: [[PluginCellValue]],
        columnTypes: [ColumnType],
        selectedRows: Set<Int> = [],
        delegate: (any DataGridViewDelegate)? = nil
    ) -> TableViewCoordinator {
        let columns = (0..<columnTypes.count).map { "c\($0)" }
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant(selectedRows),
            delegate: delegate,
            layoutPersister: DataGridRowViewCopyLayoutPersister()
        )
        let tableRows = TableRows.from(queryRows: rows, columns: columns, columnTypes: columnTypes)
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()
        return coordinator
    }

    private func makeTableView(for coordinator: TableViewCoordinator) -> KeyHandlingTableView {
        let tableView = KeyHandlingTableView()
        tableView.coordinator = coordinator
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        for identifier in coordinator.identitySchema.identifiers {
            tableView.addTableColumn(NSTableColumn(identifier: identifier))
        }
        coordinator.tableView = tableView
        return tableView
    }

    private func invokeCopy(
        on rowView: DataGridRowView,
        target: DataGridRowView.CopyContextTarget = .unresolved
    ) {
        let item = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
        item.representedObject = target
        _ = rowView.perform(NSSelectorFromString("copyFromContextMenu:"), with: item)
    }

    private func invokeCopyRows(on rowView: DataGridRowView) {
        _ = rowView.perform(NSSelectorFromString("copySelectedOrCurrentRow"))
    }

    @Test("Copy uses clicked cell value instead of row TSV")
    func copyUsesClickedCellValue() {
        let clipboard = DataGridRowViewCopyClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }

        let coordinator = makeCoordinator(
            rows: [[.text("1"), .bytes(Data([0xAA, 0xBB]))]],
            columnTypes: [.integer(rawType: "INT"), .blob(rawType: "BYTEA")]
        )
        let rowView = DataGridRowView()
        rowView.coordinator = coordinator
        rowView.rowIndex = 0

        invokeCopy(on: rowView, target: .cell(1))

        #expect(clipboard.text == "0xAABB")
        #expect(clipboard.hasGridRows == false)
    }

    @Test("Copy falls back to focused cell when no clicked column is attached")
    func copyFallsBackToFocusedCell() {
        let clipboard = DataGridRowViewCopyClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }

        let coordinator = makeCoordinator(
            rows: [[.text("1"), .null]],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")]
        )
        let tableView = makeTableView(for: coordinator)
        tableView.focusedRow = 0
        tableView.focusedColumn = 2

        let rowView = DataGridRowView()
        rowView.coordinator = coordinator
        rowView.rowIndex = 0

        invokeCopy(on: rowView)

        #expect(clipboard.text == "NULL")
        #expect(clipboard.hasGridRows == false)
    }

    @Test("Copy from row-number column copies row even when a data cell is focused")
    func copyFromRowNumberColumnCopiesRow() {
        let delegate = DataGridRowViewCopyDelegateSpy()
        let coordinator = makeCoordinator(
            rows: [[.text("1"), .text("Alice")]],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")],
            selectedRows: [0],
            delegate: delegate
        )
        let tableView = makeTableView(for: coordinator)
        tableView.focusedRow = 0
        tableView.focusedColumn = 2

        let rowView = DataGridRowView()
        rowView.coordinator = coordinator
        rowView.rowIndex = 0

        invokeCopy(on: rowView, target: .row)

        #expect(delegate.copiedRows == Set([0]))
    }

    @Test("Copy rows action still dispatches full-row copy")
    func copyRowsActionStillCopiesRows() {
        let delegate = DataGridRowViewCopyDelegateSpy()
        let coordinator = makeCoordinator(
            rows: [[.text("1"), .text("Alice")], [.text("2"), .text("Bob")]],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")],
            selectedRows: [0, 1],
            delegate: delegate
        )
        let rowView = DataGridRowView()
        rowView.coordinator = coordinator
        rowView.rowIndex = 0

        invokeCopyRows(on: rowView)

        #expect(delegate.copiedRows == Set([0, 1]))
    }

    @Test("Copy falls back to row copy when no cell context exists")
    func copyFallsBackToRowCopy() {
        let delegate = DataGridRowViewCopyDelegateSpy()
        let coordinator = makeCoordinator(
            rows: [[.text("1"), .text("Alice")], [.text("2"), .text("Bob")]],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")],
            selectedRows: [0, 1],
            delegate: delegate
        )
        let rowView = DataGridRowView()
        rowView.coordinator = coordinator
        rowView.rowIndex = 1

        invokeCopy(on: rowView)

        #expect(delegate.copiedRows == Set([0, 1]))
    }

    @Test("Copy uses the rectangular grid selection when one exists")
    func copyUsesGridSelection() {
        let clipboard = DataGridRowViewCopyClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }

        let coordinator = makeCoordinator(
            rows: [[.text("1"), .text("Alice")], [.text("2"), .text("Bob")]],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")]
        )
        coordinator.selectionController.selectAll(totalRows: 2, totalColumns: 2)

        let rowView = DataGridRowView()
        rowView.coordinator = coordinator
        rowView.rowIndex = 0

        invokeCopy(on: rowView, target: .cell(0))

        #expect(clipboard.text == "1\tAlice\n2\tBob")
    }
}
