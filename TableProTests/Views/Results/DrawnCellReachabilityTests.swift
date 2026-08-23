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
@Suite("Drawn cell reachability", .serialized)
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
        DataGridAccessibility.isActive = false
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

    // MARK: - Accessibility

    private func mountedCell(
        in grid: Grid,
        row: Int = 0
    ) throws -> DataGridCellAccessibilityView? {
        let tableView = try #require(grid.coordinator.tableView)
        let column = try #require(grid.coordinator.firstPresentedColumnIndex())
        return tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? DataGridCellAccessibilityView
    }

    /// The whole point of drawing the cells: a result with hundreds of columns builds no view for
    /// any of them. Nothing has asked this grid an accessibility question, so nothing mounts.
    @Test("A data cell mounts no view until something reads the grid")
    func noCellViewIsMountedWhileAccessibilityIsIdle() throws {
        DataGridAccessibility.isActive = false
        let grid = makeGrid(columns: ["id", "name"])

        #expect(try mountedCell(in: grid) == nil)
    }

    /// `NSTableView` builds its `AXCell` tree from cell views and from nothing else, so a drawn cell
    /// can only speak through one. Measured: an `NSAccessibilityElement` published by the row never
    /// reaches the tree, whichever attribute carries the text and however it is parented, and AppKit
    /// puts its own blank placeholder there instead.
    @Test("A cell mounts a view carrying its value once accessibility is active")
    func anActiveClientGetsACellItCanRead() throws {
        DataGridAccessibility.isActive = true
        defer { DataGridAccessibility.isActive = false }
        let grid = makeGrid(columns: ["id", "name"])

        let cell = try #require(try mountedCell(in: grid))

        #expect(cell.accessibilityValue() as? String == "id-0")
        #expect(cell.accessibilityRole() == .staticText)
    }

    /// Walking the tree makes `NSTableView` prepare every row of the page and ask for a view for
    /// each one, so mounting on preparation alone put 9,000 views and a 21,000 element tree behind a
    /// 1,000-row page and starved the app of the main thread.
    @Test("A row below the viewport mounts no cell")
    func aRowBelowTheViewportMountsNothing() throws {
        DataGridAccessibility.isActive = true
        defer { DataGridAccessibility.isActive = false }
        let grid = makeGrid(columns: ["id"], rows: 200)
        let tableView = try #require(grid.coordinator.tableView)
        let column = try #require(grid.coordinator.firstPresentedColumnIndex())

        #expect(tableView.view(atColumn: column, row: 0, makeIfNecessary: true) is DataGridCellAccessibilityView)
        #expect(tableView.view(atColumn: column, row: 199, makeIfNecessary: true) == nil)
    }

    /// The value is read through rather than stored, so an edit is spoken without anything having to
    /// remember to stand the cell down first. A committed cell edit takes this exact path.
    @Test("An edited cell is read back without any invalidation")
    func anEditedCellReadsItsNewValue() throws {
        DataGridAccessibility.isActive = true
        defer { DataGridAccessibility.isActive = false }
        let columns = ["id"]
        var current = TableRows.from(
            queryRows: [[PluginCellValue.text("before")]],
            columns: columns,
            columnTypes: [ColumnType.text(rawType: "TEXT")]
        )
        let grid = makeGrid(columns: columns, rows: 1)
        grid.coordinator.tableRowsProvider = { current }
        grid.coordinator.updateCache()
        let cell = try #require(try mountedCell(in: grid))
        #expect(cell.accessibilityValue() as? String == "before")

        current = TableRows.from(
            queryRows: [[PluginCellValue.text("after")]],
            columns: columns,
            columnTypes: [ColumnType.text(rawType: "TEXT")]
        )
        grid.coordinator.invalidateDisplayCache()

        #expect(cell.accessibilityValue() as? String == "after")
    }

    /// The row still draws every cell and still handles every click, so the view mounted over it
    /// must be transparent to the mouse or the in-cell accessories and the double click to edit go
    /// to a view that does nothing with them.
    @Test("The mounted cell takes no clicks")
    func theMountedCellIsTransparentToTheMouse() throws {
        DataGridAccessibility.isActive = true
        defer { DataGridAccessibility.isActive = false }
        let grid = makeGrid(columns: ["id"])
        let cell = try #require(try mountedCell(in: grid))

        #expect(cell.hitTest(NSPoint(x: cell.bounds.midX, y: cell.bounds.midY)) == nil)
    }

    @Test("The view that draws the cells stays out of the accessibility tree")
    func theDrawingViewIsNotAnAccessibilityElement() throws {
        let rowView = DataGridRowView()
        let content = try #require(rowView.subviews.first as? DataGridRowContentView)

        #expect(content.isAccessibilityElement() == false)
    }

    /// The row covers more than its cells do: the row-number column at one end and, on a result
    /// narrower than the grid, the empty width past the last column at the other. AppKit's own hit
    /// test descends into subviews and the view that draws the cells covers the whole row, so a
    /// point outside every cell resolved to a view that is not in the tree at all.
    @Test("An accessibility hit test past the last column lands on the row itself")
    func aHitTestPastTheLastColumnReturnsTheRow() throws {
        let grid = makeGrid(columns: ["id", "name"], rows: 1)
        let tableView = try #require(grid.coordinator.tableView)
        let rowView = try #require(tableView.rowView(atRow: 0, makeIfNecessary: true) as? DataGridRowView)
        let lastColumn = try #require(grid.coordinator.lastPresentedColumnIndex())
        let pastEverything = tableView.rect(ofColumn: lastColumn).maxX + 20

        let hit = rowView.accessibilityHitTest(
            screenPoint(x: pastEverything, in: rowView, of: tableView, window: grid.window)
        )

        #expect(hit as? NSView === rowView)
    }

    private func screenPoint(
        x horizontal: CGFloat,
        in rowView: DataGridRowView,
        of tableView: NSTableView,
        window: NSWindow
    ) -> NSPoint {
        let inRow = rowView.convert(NSPoint(x: horizontal, y: 0), from: tableView)
        let centred = NSPoint(x: inRow.x, y: rowView.bounds.midY)
        return window.convertPoint(toScreen: rowView.convert(centred, to: nil))
    }
}
