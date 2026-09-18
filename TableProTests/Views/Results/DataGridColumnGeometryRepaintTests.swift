//
//  DataGridColumnGeometryRepaintTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class NoopColumnLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// A data cell has no view, so `NSTableView` never relays one out and never invalidates the row that
/// drew it. AppKit resizes a row view only when the table's total width moves, which it does not
/// while the columns still fit inside the viewport, so every column geometry change on a grid
/// narrower than its scroll view used to leave the body painting the layout it last drew (#2449).
@Suite("Data grid column geometry repaint")
@MainActor
struct DataGridColumnGeometryRepaintTests {
    private struct Grid {
        let window: NSWindow
        let scrollView: NSScrollView
        let tableView: KeyHandlingTableView
        let coordinator: TableViewCoordinator
        let overlay: GridSelectionOverlay
        let dataColumns: [NSTableColumn]
        let rowNumberColumn: NSTableColumn

        var rowViews: [DataGridRowView] {
            (0 ..< tableView.numberOfRows).compactMap {
                tableView.rowView(atRow: $0, makeIfNecessary: false) as? DataGridRowView
            }
        }
    }

    private static let rows = TableRows.from(
        queryRows: [
            [.text("edge-01"), .text("running"), .text("2026-08-20 11:03:39")],
            [.text("edge-02"), .text("stopped"), .text("2026-08-21 09:14:02")],
        ],
        columns: ["machine_id", "state", "last_seen_at"],
        columnTypes: [.text(rawType: "TEXT"), .text(rawType: "TEXT"), .text(rawType: "TEXT")]
    )

    /// - Parameters:
    ///   - viewportWidth: the scroll view's width. Wider than the columns is the configuration the
    ///     bug lives in, because the table view's frame never moves and AppKit therefore never
    ///     resizes a row view. Narrower is the configuration that hides it, where the frame grows
    ///     and the incidental resize redraw covers for the missing invalidation.
    private func makeGrid(viewportWidth: CGFloat, columnWidth: CGFloat) -> Grid {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: NoopColumnLayoutPersister()
        )
        coordinator.tabType = .table
        coordinator.connectionId = UUID()
        coordinator.tableName = "machines"
        coordinator.tableRowsProvider = { Self.rows }

        let tableView = KeyHandlingTableView()
        tableView.coordinator = coordinator
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
        tableView.rowHeight = 24
        tableView.usesAutomaticRowHeights = false
        coordinator.tableView = tableView

        let rowNumberColumn = NSTableColumn(identifier: ColumnIdentitySchema.rowNumberIdentifier)
        rowNumberColumn.width = 40
        tableView.addTableColumn(rowNumberColumn)

        coordinator.rebuildColumnMetadataCache(from: Self.rows)
        var dataColumns: [NSTableColumn] = []
        for index in Self.rows.columns.indices {
            let identifier = coordinator.columnIdentifier(for: index) ?? ColumnIdentitySchema.slotIdentifier(index)
            let column = NSTableColumn(identifier: identifier)
            column.title = Self.rows.columns[index]
            column.minWidth = 20
            column.maxWidth = 2000
            column.width = columnWidth
            tableView.addTableColumn(column)
            dataColumns.append(column)
        }
        coordinator.updateColumnPresentations(from: Self.rows)
        coordinator.updateCache()

        let overlay = GridSelectionOverlay(frame: tableView.bounds)
        overlay.tableView = tableView
        overlay.coordinator = coordinator
        coordinator.selectionController.overlay = overlay
        tableView.selectionOverlay = overlay
        tableView.addSubview(overlay)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: viewportWidth, height: 200))
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = tableView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: viewportWidth, height: 220),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView

        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        tableView.reloadData()
        scrollView.tile()
        window.layoutIfNeeded()
        for row in 0 ..< tableView.numberOfRows {
            _ = tableView.rowView(atRow: row, makeIfNecessary: true)
        }

        return Grid(
            window: window,
            scrollView: scrollView,
            tableView: tableView,
            coordinator: coordinator,
            overlay: overlay,
            dataColumns: dataColumns,
            rowNumberColumn: rowNumberColumn
        )
    }

    private func settle(_ grid: Grid) {
        grid.window.displayIfNeeded()
        grid.tableView.needsDisplay = false
        grid.overlay.needsDisplay = false
        for rowView in grid.rowViews {
            rowView.needsDisplay = false
            rowView.cellsNeedDisplay = false
        }
    }

    @Test("A width change repaints the drawn cells when the columns fit inside the viewport")
    func widthChangeRepaintsInsideViewport() throws {
        let grid = makeGrid(viewportWidth: 900, columnWidth: 100)
        let rowViews = grid.rowViews
        try #require(!rowViews.isEmpty)
        let widthBefore = grid.tableView.frame.width
        settle(grid)

        grid.dataColumns[0].width = 260

        #expect(grid.tableView.frame.width == widthBefore)
        #expect(rowViews.filter(\.cellsNeedDisplay).count == rowViews.count)
        #expect(grid.tableView.needsDisplay)
        #expect(grid.overlay.needsDisplay)
    }

    @Test("A width change repaints the drawn cells when the columns overflow the viewport")
    func widthChangeRepaintsOutsideViewport() throws {
        let grid = makeGrid(viewportWidth: 300, columnWidth: 200)
        let rowViews = grid.rowViews
        try #require(!rowViews.isEmpty)
        settle(grid)

        grid.dataColumns[0].width = 380

        #expect(rowViews.filter(\.cellsNeedDisplay).count == rowViews.count)
    }

    @Test("Reordering a column repaints the drawn cells")
    func reorderRepaints() throws {
        let grid = makeGrid(viewportWidth: 900, columnWidth: 100)
        let rowViews = grid.rowViews
        try #require(!rowViews.isEmpty)
        settle(grid)

        let from = grid.tableView.column(withIdentifier: grid.dataColumns[0].identifier)
        let to = grid.tableView.column(withIdentifier: grid.dataColumns[2].identifier)
        grid.tableView.moveColumn(from, toColumn: to)

        #expect(rowViews.filter(\.cellsNeedDisplay).count == rowViews.count)
    }

    /// The row-number column is pinned, `minWidth == maxWidth == width`. Raising `minWidth` past the
    /// current width moves `width` with it while `NSTableView` keeps the old cumulative geometry and
    /// posts nothing, so the assertion has to be on `rect(ofColumn:)` rather than on the width
    /// property, which reports the new value either way. Paging from row 999 to row 1000 is the
    /// trigger.
    @Test("Widening the row-number column moves the geometry the cells are drawn from")
    func rowNumberWidthChangeRepaints() throws {
        let grid = makeGrid(viewportWidth: 900, columnWidth: 100)
        let rowViews = grid.rowViews
        try #require(!rowViews.isEmpty)
        let rowNumberIndex = grid.tableView.column(withIdentifier: ColumnIdentitySchema.rowNumberIdentifier)
        let firstDataIndex = grid.tableView.column(withIdentifier: grid.dataColumns[0].identifier)
        let rowNumberWidthBefore = grid.tableView.rect(ofColumn: rowNumberIndex).width
        let firstDataOriginBefore = grid.tableView.rect(ofColumn: firstDataIndex).minX
        settle(grid)

        grid.coordinator.paginationOffsetProvider = { 1_000_000 }
        grid.coordinator.resizeRowNumberColumnForCurrentRange()

        #expect(grid.tableView.rect(ofColumn: rowNumberIndex).width > rowNumberWidthBefore)
        #expect(grid.tableView.rect(ofColumn: firstDataIndex).minX > firstDataOriginBefore)
        #expect(rowViews.filter(\.cellsNeedDisplay).count == rowViews.count)
    }

    @Test("Narrowing the row-number column moves the geometry back")
    func rowNumberShrinkRepaints() throws {
        let grid = makeGrid(viewportWidth: 900, columnWidth: 100)
        grid.coordinator.paginationOffsetProvider = { 1_000_000 }
        grid.coordinator.resizeRowNumberColumnForCurrentRange()
        let rowViews = grid.rowViews
        try #require(!rowViews.isEmpty)
        let rowNumberIndex = grid.tableView.column(withIdentifier: ColumnIdentitySchema.rowNumberIdentifier)
        let firstDataIndex = grid.tableView.column(withIdentifier: grid.dataColumns[0].identifier)
        let widenedWidth = grid.tableView.rect(ofColumn: rowNumberIndex).width
        let widenedOrigin = grid.tableView.rect(ofColumn: firstDataIndex).minX
        settle(grid)

        grid.coordinator.paginationOffsetProvider = { 0 }
        grid.coordinator.resizeRowNumberColumnForCurrentRange()

        #expect(grid.tableView.rect(ofColumn: rowNumberIndex).width < widenedWidth)
        #expect(grid.tableView.rect(ofColumn: firstDataIndex).minX < widenedOrigin)
        #expect(rowViews.filter(\.cellsNeedDisplay).count == rowViews.count)
    }

    /// The cell-range selection wash is painted by the row itself in `drawBackground`, placed from
    /// the same live column rects the cells use. It repaints because `canDrawSubviewsIntoLayer` puts
    /// the row and its cells in one backing store, so dirtying the cells dirties the row. This pins
    /// that, since the wash would otherwise be left at the old column with nothing to catch it.
    @Test("A geometry change invalidates the selection wash the row paints")
    func geometryChangeInvalidatesTheSelectionWash() throws {
        let grid = makeGrid(viewportWidth: 900, columnWidth: 100)
        let rowViews = grid.rowViews
        try #require(!rowViews.isEmpty)
        grid.coordinator.selectionController.selectEntireColumn(0, totalRows: grid.tableView.numberOfRows)
        settle(grid)

        grid.dataColumns[0].width = 260

        #expect(rowViews.filter(\.needsDisplay).count == rowViews.count)
    }

    /// `markColumnWidthUserSized` is false for the row-number column and for an unused pool slot, and
    /// it is the second guard the resize handler returns on, so a repaint placed behind it would skip
    /// exactly those columns.
    @Test("A resize notification repaints a column that is never user-sized")
    func resizeRepaintsAColumnThatIsNeverUserSized() throws {
        let grid = makeGrid(viewportWidth: 900, columnWidth: 100)
        let rowViews = grid.rowViews
        try #require(!rowViews.isEmpty)
        settle(grid)

        grid.coordinator.tableViewColumnDidResize(
            Notification(
                name: NSTableView.columnDidResizeNotification,
                object: grid.tableView,
                userInfo: ["NSTableColumn": grid.rowNumberColumn, "NSOldWidth": CGFloat(40)]
            )
        )

        #expect(grid.coordinator.userSizedColumnNames.isEmpty)
        #expect(rowViews.filter(\.cellsNeedDisplay).count == rowViews.count)
    }

    @Test("A width change during a column rebuild still repaints")
    func rebuildingColumnsStillRepaints() throws {
        let grid = makeGrid(viewportWidth: 900, columnWidth: 100)
        let rowViews = grid.rowViews
        try #require(!rowViews.isEmpty)
        settle(grid)

        grid.coordinator.isRebuildingColumns = true
        defer { grid.coordinator.isRebuildingColumns = false }
        grid.dataColumns[1].width = 240

        #expect(grid.coordinator.userSizedColumnNames.isEmpty)
        #expect(rowViews.filter(\.cellsNeedDisplay).count == rowViews.count)
    }

    /// The invalidation is only half the contract. The cells have to be drawn from the geometry the
    /// table view reports now, so the same row rasterises differently once a column has moved.
    @Test("The redrawn cells land at the new column geometry")
    func redrawnCellsFollowTheNewGeometry() throws {
        let grid = makeGrid(viewportWidth: 900, columnWidth: 100)
        let rowView = try #require(grid.rowViews.first)
        let before = try #require(Self.rasterize(rowView))

        grid.dataColumns[0].width = 300
        grid.window.layoutIfNeeded()

        let after = try #require(Self.rasterize(rowView))
        #expect(before != after)
    }

    /// `DataGridColumnPool` places every data column relative to the row-number column and reads its
    /// position off `tableColumns.first`, so it has to stay at the head of the run.
    @Test("The row-number column cannot be dragged out of the first position")
    func rowNumberColumnStaysFirst() {
        let grid = makeGrid(viewportWidth: 900, columnWidth: 100)
        let coordinator = grid.coordinator

        #expect(!coordinator.tableView(grid.tableView, shouldReorderColumn: 0, toColumn: 2))
        #expect(!coordinator.tableView(grid.tableView, shouldReorderColumn: 2, toColumn: 0))
        #expect(coordinator.tableView(grid.tableView, shouldReorderColumn: 2, toColumn: 1))
        #expect(coordinator.tableView(grid.tableView, shouldReorderColumn: 1, toColumn: 3))
    }

    /// A drag opens with a `newColumnIndex` of -1, and answering no to it disallows the column from
    /// being reordered at all. Refusing that probe for every column would disable the whole feature
    /// while trying to pin one column.
    @Test("The opening reorder probe leaves data columns draggable")
    func openingReorderProbeAllowsDataColumns() {
        let grid = makeGrid(viewportWidth: 900, columnWidth: 100)
        let coordinator = grid.coordinator

        #expect(coordinator.tableView(grid.tableView, shouldReorderColumn: 1, toColumn: -1))
        #expect(coordinator.tableView(grid.tableView, shouldReorderColumn: 3, toColumn: -1))
        #expect(!coordinator.tableView(grid.tableView, shouldReorderColumn: 0, toColumn: -1))
    }

    private static func rasterize(_ rowView: DataGridRowView) -> Data? {
        guard let representation = rowView.bitmapImageRepForCachingDisplay(in: rowView.bounds) else { return nil }
        rowView.cacheDisplay(in: rowView.bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }
}
