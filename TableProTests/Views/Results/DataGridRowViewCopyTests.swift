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
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private final class DataGridRowViewCopyDelegateSpy: DataGridViewDelegate {
    var copiedRows: Set<Int>?
    var deletedRows: Set<Int>?

    func dataGridCopyRows(_ indices: Set<Int>) {
        copiedRows = indices
    }

    func dataGridDeleteRows(_ indices: Set<Int>) {
        deletedRows = indices
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

    private func makeRangeSelectedRowView(
        delegate: (any DataGridViewDelegate)? = nil
    ) -> (DataGridRowView, TableViewCoordinator) {
        let coordinator = makeCoordinator(
            rows: [[.text("1"), .text("Alice")], [.text("2"), .text("Bob")]],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")],
            selectedRows: [1],
            delegate: delegate
        )
        coordinator.selectionController.update(
            .single(
                GridRect(rows: 0...1, columns: 0...1),
                anchor: GridCoord(row: 0, column: 0),
                active: GridCoord(row: 1, column: 0)
            )
        )
        let rowView = DataGridRowView()
        rowView.coordinator = coordinator
        rowView.rowIndex = 1
        return (rowView, coordinator)
    }

    private func withClipboard(_ body: (DataGridRowViewCopyClipboard) -> Void) {
        let clipboard = DataGridRowViewCopyClipboard()
        ClipboardService.shared = clipboard
        defer { ClipboardService.shared = NSPasteboardClipboardProvider() }
        body(clipboard)
    }

    @Test("Copy as Rows sends every row of the range selection")
    func copyRowsUsesRangeSelection() {
        let delegate = DataGridRowViewCopyDelegateSpy()
        let (rowView, coordinator) = makeRangeSelectedRowView(delegate: delegate)

        invokeCopyRows(on: rowView)

        #expect(delegate.copiedRows == Set([0, 1]))
        withExtendedLifetime(coordinator) {}
    }

    @Test("Copy as With Headers includes every row of the range selection")
    func copyWithHeadersUsesRangeSelection() {
        withClipboard { clipboard in
            let (rowView, coordinator) = makeRangeSelectedRowView()

            _ = rowView.perform(NSSelectorFromString("copySelectedOrCurrentRowWithHeaders"))

            #expect(clipboard.text == "c0\tc1\n1\tAlice\n2\tBob")
            withExtendedLifetime(coordinator) {}
        }
    }

    @Test("Copy as JSON includes every row of the range selection")
    func copyAsJsonUsesRangeSelection() {
        withClipboard { clipboard in
            let (rowView, coordinator) = makeRangeSelectedRowView()

            _ = rowView.perform(NSSelectorFromString("copyAsJson"))

            #expect(clipboard.text?.contains("Alice") == true)
            #expect(clipboard.text?.contains("Bob") == true)
            withExtendedLifetime(coordinator) {}
        }
    }

    @Test("Copy as CSV includes every row of the range selection")
    func copyAsCsvUsesRangeSelection() {
        withClipboard { clipboard in
            let (rowView, coordinator) = makeRangeSelectedRowView()

            _ = rowView.perform(NSSelectorFromString("copyAsCsv"))

            #expect(clipboard.text?.contains("Alice") == true)
            #expect(clipboard.text?.contains("Bob") == true)
            withExtendedLifetime(coordinator) {}
        }
    }

    @Test("Copy as CSV with Headers includes every row of the range selection")
    func copyAsCsvWithHeadersUsesRangeSelection() {
        withClipboard { clipboard in
            let (rowView, coordinator) = makeRangeSelectedRowView()

            _ = rowView.perform(NSSelectorFromString("copyAsCsvWithHeaders"))

            #expect(clipboard.text?.contains("c0") == true)
            #expect(clipboard.text?.contains("Alice") == true)
            #expect(clipboard.text?.contains("Bob") == true)
            withExtendedLifetime(coordinator) {}
        }
    }

    @Test("Copy as Markdown includes every row of the range selection")
    func copyAsMarkdownUsesRangeSelection() {
        withClipboard { clipboard in
            let (rowView, coordinator) = makeRangeSelectedRowView()

            _ = rowView.perform(NSSelectorFromString("copyAsMarkdown"))

            #expect(clipboard.text?.contains("Alice") == true)
            #expect(clipboard.text?.contains("Bob") == true)
            withExtendedLifetime(coordinator) {}
        }
    }

    @Test("Copy as IN Clause includes every row of the range selection")
    func copyAsInClauseUsesRangeSelection() {
        withClipboard { clipboard in
            let (rowView, coordinator) = makeRangeSelectedRowView()
            let item = NSMenuItem(title: "IN Clause", action: nil, keyEquivalent: "")
            item.representedObject = 1

            _ = rowView.perform(NSSelectorFromString("copyAsInClause:"), with: item)

            #expect(clipboard.text?.contains("Alice") == true)
            #expect(clipboard.text?.contains("Bob") == true)
            withExtendedLifetime(coordinator) {}
        }
    }

    @Test("Copy as INSERT emits a statement for every row of the range selection")
    func copyAsInsertUsesRangeSelection() {
        withClipboard { clipboard in
            let (rowView, coordinator) = makeRangeSelectedRowView()
            coordinator.tableName = "users"
            coordinator.databaseType = .mysql

            _ = rowView.perform(NSSelectorFromString("copyAsInsert"))

            let statements = clipboard.text?.components(separatedBy: "INSERT INTO").count ?? 0
            #expect(statements - 1 == 2)
            #expect(clipboard.text?.contains("Alice") == true)
            #expect(clipboard.text?.contains("Bob") == true)
        }
    }

    @Test("Copy as UPDATE emits a statement for every row of the range selection")
    func copyAsUpdateUsesRangeSelection() {
        withClipboard { clipboard in
            let (rowView, coordinator) = makeRangeSelectedRowView()
            coordinator.tableName = "users"
            coordinator.databaseType = .mysql
            coordinator.primaryKeyColumns = ["c0"]

            _ = rowView.perform(NSSelectorFromString("copyAsUpdate"))

            let statements = clipboard.text?.components(separatedBy: "UPDATE").count ?? 0
            #expect(statements - 1 == 2)
            #expect(clipboard.text?.contains("Alice") == true)
            #expect(clipboard.text?.contains("Bob") == true)
        }
    }

    @Test("Delete targets every row of the range selection")
    func deleteUsesRangeSelection() {
        let delegate = DataGridRowViewCopyDelegateSpy()
        let (rowView, coordinator) = makeRangeSelectedRowView(delegate: delegate)

        _ = rowView.perform(NSSelectorFromString("deleteRow"))

        #expect(delegate.deletedRows == Set([0, 1]))
        withExtendedLifetime(coordinator) {}
    }

    @Test("Copy as JSON covers every row of a column selection")
    func copyAsJsonUsesColumnSelection() {
        withClipboard { clipboard in
            let coordinator = makeCoordinator(
                rows: [[.text("1"), .text("Alice")], [.text("2"), .text("Bob")]],
                columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")]
            )
            coordinator.selectionController.selectEntireColumn(0, totalRows: 2)
            let rowView = DataGridRowView()
            rowView.coordinator = coordinator
            rowView.rowIndex = 0

            _ = rowView.perform(NSSelectorFromString("copyAsJson"))

            #expect(clipboard.text?.contains("Alice") == true)
            #expect(clipboard.text?.contains("Bob") == true)
        }
    }

    @Test("Copy as JSON falls back to the clicked row without any selection")
    func copyAsJsonFallsBackToClickedRow() {
        withClipboard { clipboard in
            let coordinator = makeCoordinator(
                rows: [[.text("1"), .text("Alice")], [.text("2"), .text("Bob")]],
                columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")]
            )
            let rowView = DataGridRowView()
            rowView.coordinator = coordinator
            rowView.rowIndex = 1

            _ = rowView.perform(NSSelectorFromString("copyAsJson"))

            #expect(clipboard.text?.contains("Bob") == true)
            #expect(clipboard.text?.contains("Alice") != true)
        }
    }
}
