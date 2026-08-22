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
    private func makeCoordinator(columns: [String], rows: Int = 3) -> TableViewCoordinator {
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
        return coordinator
    }

    /// The regression itself: the question the guards used to ask now answers nil for every data
    /// cell, so anything still asking it is dead code.
    @Test("No data cell mounts a view any more")
    func dataCellsMountNoView() throws {
        let coordinator = makeCoordinator(columns: ["id", "name"])
        let tableView = try #require(coordinator.tableView)
        let dataColumn = try #require(coordinator.firstPresentedColumnIndex())

        #expect(tableView.view(atColumn: dataColumn, row: 0, makeIfNecessary: false) == nil)
        #expect(tableView.view(atColumn: dataColumn, row: 0, makeIfNecessary: true) == nil)
    }

    @Test("An on-screen data cell is reachable")
    func onScreenCellIsReachable() throws {
        let coordinator = makeCoordinator(columns: ["id", "name"])
        let dataColumn = try #require(coordinator.firstPresentedColumnIndex())

        #expect(coordinator.presentsCell(row: 0, tableColumnIndex: dataColumn))
    }

    @Test("A row outside the result is not reachable")
    func rowOutOfRangeIsNotReachable() throws {
        let coordinator = makeCoordinator(columns: ["id", "name"])
        let dataColumn = try #require(coordinator.firstPresentedColumnIndex())

        #expect(!coordinator.presentsCell(row: -1, tableColumnIndex: dataColumn))
        #expect(!coordinator.presentsCell(row: 99, tableColumnIndex: dataColumn))
    }

    @Test("The row-number column is not a cell anything opens on")
    func rowNumberColumnIsNotReachable() throws {
        let coordinator = makeCoordinator(columns: ["id", "name"])
        let tableView = try #require(coordinator.tableView)
        let rowNumber = tableView.column(withIdentifier: ColumnIdentitySchema.rowNumberIdentifier)

        #expect(rowNumber >= 0)
        #expect(!coordinator.presentsCell(row: 0, tableColumnIndex: rowNumber))
    }

    /// `reloadData(forRowIndexes:columnIndexes:)` rebuilds a cell view, and the row-number column is
    /// the only one that still has one. Seven callers reloaded a row's whole column range and so
    /// repainted nothing, which is how a committed cell edit and an undo stopped showing (#2381).
    @Test("Repainting a row reaches the row's drawn cells")
    func repaintingARowReachesItsDrawnCells() throws {
        let coordinator = makeCoordinator(columns: ["id", "name"])
        let tableView = try #require(coordinator.tableView)
        let rowView = try #require(tableView.rowView(atRow: 0, makeIfNecessary: true) as? DataGridRowView)
        rowView.layoutSubtreeIfNeeded()
        rowView.displayIfNeeded()

        coordinator.repaintRows(IndexSet(integer: 0))

        #expect(rowView.needsToDrawCells, "the row's drawn cells must be marked for redisplay")
    }
}
