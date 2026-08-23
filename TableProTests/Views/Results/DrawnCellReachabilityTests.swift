//
//  DrawnCellReachabilityTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class ReachabilityLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// A data cell is drawn rather than mounted, so `view(atColumn:row:makeIfNecessary:false)` is always
/// nil. Twelve guards still asked it before opening an editor or a popover, and every one of them
/// returned early: the JSON, blob, PHP, date, enum, set, array, dropdown and type-picker editors
/// were all unreachable. `presentsCell(row:tableColumnIndex:)` is the single replacement (#2381).
@Suite("Drawn cell reachability")
@MainActor
struct DrawnCellReachabilityTests {
    /// Holds the window: `TableViewCoordinator.tableView` is weak both ways, so a suite that
    /// dropped the hierarchy would only survive on `NSApplication` incidentally retaining it.
    private struct Grid {
        let window: NSWindow
        let coordinator: TableViewCoordinator
    }

    private func makeGrid(columns: [String], rows: Int = 3) -> Grid {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: ReachabilityLayoutPersister()
        )
        let queryRows = (0 ..< rows).map { row in columns.map { PluginCellValue.text("\($0)-\(row)") } }
        let tableRows = TableRows.from(
            queryRows: queryRows,
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: columns.count)
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()

        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 21
        tableView.coordinator = coordinator
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: columns.count),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: { _, _ in 120 }
        )
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        scrollView.documentView = tableView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        return Grid(window: window, coordinator: coordinator)
    }

    /// The regression itself: the question the guards used to ask now answers nil for every data
    /// cell, so anything still asking it is dead code.
    @Test("No data cell mounts a view any more")
    func dataCellsMountNoView() throws {
        let coordinator = makeGrid(columns: ["id", "name"]).coordinator
        let tableView = try #require(coordinator.tableView)
        let dataColumn = try #require(coordinator.firstPresentedColumnIndex())

        #expect(tableView.view(atColumn: dataColumn, row: 0, makeIfNecessary: false) == nil)
        #expect(tableView.view(atColumn: dataColumn, row: 0, makeIfNecessary: true) == nil)
    }

    @Test("An on-screen data cell is reachable")
    func onScreenCellIsReachable() throws {
        let coordinator = makeGrid(columns: ["id", "name"]).coordinator
        let dataColumn = try #require(coordinator.firstPresentedColumnIndex())

        #expect(coordinator.presentsCell(row: 0, tableColumnIndex: dataColumn))
    }

    @Test("A row outside the result is not reachable")
    func rowOutOfRangeIsNotReachable() throws {
        let coordinator = makeGrid(columns: ["id", "name"]).coordinator
        let dataColumn = try #require(coordinator.firstPresentedColumnIndex())

        #expect(!coordinator.presentsCell(row: -1, tableColumnIndex: dataColumn))
        #expect(!coordinator.presentsCell(row: 99, tableColumnIndex: dataColumn))
    }

    @Test("The row-number column is not a cell anything opens on")
    func rowNumberColumnIsNotReachable() throws {
        let coordinator = makeGrid(columns: ["id", "name"]).coordinator
        let tableView = try #require(coordinator.tableView)
        let rowNumber = tableView.column(withIdentifier: ColumnIdentitySchema.rowNumberIdentifier)

        #expect(rowNumber >= 0)
        #expect(!coordinator.presentsCell(row: 0, tableColumnIndex: rowNumber))
    }

    /// `reloadData(forRowIndexes:columnIndexes:)` raises `NSRangeException` for a row past the end,
    /// and a row view can outlive a result that shrank under it, so undoing a delete on a stale row
    /// used to crash rather than no-op.
    @Test("Repainting a row past the end of the result is a no-op")
    func repaintingAnOutOfRangeRowIsANoOp() throws {
        let coordinator = makeGrid(columns: ["id", "name"], rows: 2).coordinator

        coordinator.repaintRows(IndexSet(integer: 99))
        coordinator.repaintRows(IndexSet(integer: -1))
    }

    /// A drawn cell has no view of its own, so the row vends the accessibility element that carries
    /// the value. Repainting one cell has to stand that element down as well, or VoiceOver keeps
    /// reading what the cell said before the edit. A committed cell edit takes this exact path.
    @Test("Repainting one cell refreshes the value VoiceOver reads")
    func repaintingOneCellRefreshesItsAccessibilityValue() throws {
        let columns = ["id", "name"]
        var current = TableRows.from(
            queryRows: [columns.map { PluginCellValue.text("before-\($0)") }],
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: columns.count)
        )
        let coordinator = makeGrid(columns: columns, rows: 1).coordinator
        coordinator.tableRowsProvider = { current }
        coordinator.updateCache()

        let tableView = try #require(coordinator.tableView)
        tableView.reloadData()
        let rowView = try #require(tableView.rowView(atRow: 0, makeIfNecessary: true) as? DataGridRowView)
        let before = (rowView.accessibilityChildren()?.first as? NSAccessibilityElement)?.accessibilityValue() as? String
        #expect(before?.contains("before") == true)

        current = TableRows.from(
            queryRows: [columns.map { _ in PluginCellValue.text("after") }],
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: columns.count)
        )
        coordinator.invalidateDisplayCache()
        let dataColumn = try #require(coordinator.firstPresentedColumnIndex())
        rowView.redrawCell(atTableColumnIndex: dataColumn)

        let after = (rowView.accessibilityChildren()?.first as? NSAccessibilityElement)?.accessibilityValue() as? String
        #expect(after == "after", "the element still held the pre-edit value")
    }
}
