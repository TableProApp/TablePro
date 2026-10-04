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

/// Serves row views that count their own draws. A dirty flag cannot show a drag step: the display
/// pass runs inside the header's tracking loop, so a row dirtied by one step is drawn and clean
/// again before anything outside the loop can read it.
@MainActor
private final class DrawCountingRowViewSource: DataGridViewDelegate {
    var rowDraws = 0

    func dataGridRowView(for tableView: NSTableView, row: Int, coordinator: TableViewCoordinator) -> NSTableRowView? {
        let rowView = DrawCountingRowView()
        rowView.coordinator = coordinator
        rowView.rowIndex = row
        rowView.source = self
        return rowView
    }
}

@MainActor
private final class DrawCountingRowView: DataGridRowView {
    weak var source: DrawCountingRowViewSource?

    override func drawBackground(in dirtyRect: NSRect) {
        source?.rowDraws += 1
        super.drawBackground(in: dirtyRect)
    }
}

/// Drags a header divider or heading through AppKit's own tracking loop. `NSTableHeaderView.mouseDown` runs a
/// modal loop in `.eventTracking` that dequeues every event itself, so a timer in that mode is how
/// code runs between two steps, and the events it posts are the ones the loop reads.
@MainActor
private final class HeaderDividerDrag {
    struct Sample {
        let resizedColumn: Int
        let draggedColumn: Int
        let width: CGFloat
        let tableWidth: CGFloat
        let resizeNotifications: Int
        let moveNotifications: Int
        let rowDraws: Int
        let cacheAgrees: Bool
    }

    private static let defaultSteps = 6
    /// Long enough for the loop to take one step and draw it before the next tick. Posted faster,
    /// the drags queue up and AppKit takes several of them as one step.
    private static let tickInterval: TimeInterval = 0.08
    /// A loop that never read the release would never return, so the release is posted again on
    /// later ticks, a bounded number of times.
    private static let releaseRetries = 10

    private let window: NSWindow
    private let header: NSTableHeaderView
    private let tableView: NSTableView
    private let column: NSTableColumn
    private let rowViews: DrawCountingRowViewSource
    private let startX: CGFloat
    private let offsets: [CGFloat]
    private let cacheAgrees: () -> Bool
    private var ticks = 0
    private(set) var samples: [Sample] = []
    private(set) var resizeNotifications = 0
    private(set) var moveNotifications = 0

    /// - Parameters:
    ///   - startX: where the press lands, the column's divider unless given.
    ///   - offsets: the pointer's distance from `startX` at each drag step; even steps of
    ///     `stepDistance` unless given. The release lands at the last one.
    init(
        window: NSWindow,
        header: NSTableHeaderView,
        tableView: NSTableView,
        columnIndex: Int,
        rowViews: DrawCountingRowViewSource,
        startX: CGFloat? = nil,
        stepDistance: CGFloat = 25,
        offsets: [CGFloat]? = nil,
        cacheAgrees: @escaping () -> Bool = { true }
    ) {
        self.window = window
        self.header = header
        self.tableView = tableView
        self.column = tableView.tableColumns[columnIndex]
        self.rowViews = rowViews
        self.startX = startX ?? header.headerRect(ofColumn: columnIndex).maxX
        self.offsets = offsets ?? (1...Self.defaultSteps).map { CGFloat($0) * stepDistance }
        self.cacheAgrees = cacheAgrees
    }

    func run() throws {
        let observer = NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidResizeNotification,
            object: tableView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resizeNotifications += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let moveObserver = NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidMoveNotification,
            object: tableView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.moveNotifications += 1 }
        }
        defer { NotificationCenter.default.removeObserver(moveObserver) }

        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] timer in
            let isFinished = MainActor.assumeIsolated { self?.tick() ?? true }
            if isFinished { timer.invalidate() }
        }
        RunLoop.current.add(timer, forMode: .eventTracking)
        defer { timer.invalidate() }

        let press = try #require(mouseEvent(.leftMouseDown, x: startX))
        header.mouseDown(with: press)
        /// The spare releases the timer posts after the loop ends would otherwise reach whichever
        /// suite runs next.
        while NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantPast,
            inMode: .default,
            dequeue: true
        ) != nil {}
    }

    /// - Returns: whether the timer has nothing left to post.
    private func tick() -> Bool {
        ticks += 1
        if ticks <= offsets.count + 1 {
            samples.append(Sample(
                resizedColumn: header.resizedColumn,
                draggedColumn: header.draggedColumn,
                width: column.width,
                tableWidth: tableView.frame.width,
                resizeNotifications: resizeNotifications,
                moveNotifications: moveNotifications,
                rowDraws: rowViews.rowDraws,
                cacheAgrees: cacheAgrees()
            ))
        }
        if ticks <= offsets.count {
            post(.leftMouseDragged, x: startX + offsets[ticks - 1])
            return false
        }
        post(.leftMouseUp, x: startX + (offsets.last ?? 0))
        return ticks > offsets.count + Self.releaseRetries
    }

    private func post(_ type: NSEvent.EventType, x: CGFloat) {
        guard let event = mouseEvent(type, x: x) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private func mouseEvent(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: header.convert(NSPoint(x: x, y: header.bounds.midY), to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        )
    }
}

/// A data cell has no view, so `NSTableView` never relays one out and never invalidates the row that
/// drew it. AppKit resizes a row view only when the table's total width moves, which it does not
/// while the columns still fit inside the viewport, so every column geometry change on a grid
/// narrower than its scroll view used to leave the body painting the layout it last drew (#2449).
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
            column.maxWidth = 2_000
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

    private struct DraggableGrid {
        let window: NSWindow
        let tableView: KeyHandlingTableView
        let header: SortableHeaderView
        let coordinator: TableViewCoordinator
    }

    /// The grid as `DataGridView` builds it: pool columns, the sortable header and a layer-backed
    /// table. The header hands a press to AppKit's resize tracking only on a presented column.
    private func makeDraggableGrid(rowViews: DrawCountingRowViewSource) -> DraggableGrid {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: rowViews,
            layoutPersister: NoopColumnLayoutPersister()
        )
        coordinator.tabType = .table
        coordinator.connectionId = UUID()
        coordinator.tableName = "machines"
        coordinator.tableRowsProvider = { Self.rows }
        coordinator.rebuildColumnMetadataCache(from: Self.rows)
        coordinator.updateCache()

        let tableView = KeyHandlingTableView()
        tableView.coordinator = coordinator
        tableView.style = .plain
        tableView.wantsLayer = true
        tableView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
        tableView.rowHeight = 24
        tableView.usesAutomaticRowHeights = false
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView

        let header = SortableHeaderView(frame: tableView.headerView?.frame ?? .zero)
        header.coordinator = coordinator
        tableView.headerView = header

        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: Self.rows.columnTypes,
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in 100 }
        )
        coordinator.updateColumnPresentations(from: Self.rows)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 200))
        scrollView.hasHorizontalScroller = true
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        scrollView.documentView = tableView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 220),
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

        return DraggableGrid(window: window, tableView: tableView, header: header, coordinator: coordinator)
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

    /// AppKit moves the width on every step of a divider drag but posts `columnDidResizeNotification`
    /// only at mouse-up, so a case that sets the width directly, which posts it at once, cannot see a
    /// body that stays frozen for the whole drag. The columns fit the viewport, so the table's frame
    /// holds still and no incidental row resize repaints the rows instead.
    @Test("A divider drag repaints the drawn cells before the mouse comes up")
    func dividerDragRepaintsBeforeMouseUp() throws {
        let rowViews = DrawCountingRowViewSource()
        let grid = makeDraggableGrid(rowViews: rowViews)
        let columnIndex = try #require(grid.coordinator.firstPresentedColumnIndex())
        let widthBefore = grid.tableView.tableColumns[columnIndex].width
        let tableWidthBefore = grid.tableView.frame.width
        let drag = HeaderDividerDrag(
            window: grid.window,
            header: grid.header,
            tableView: grid.tableView,
            columnIndex: columnIndex,
            rowViews: rowViews
        )

        try drag.run()

        let samples = drag.samples
        try #require(
            samples.contains { $0.rowDraws > 0 },
            "The rows never drew, so this host cannot show whether a drag step repaints them"
        )
        let midDrag = samples.filter { $0.resizedColumn == columnIndex && $0.width > widthBefore }
        try #require(midDrag.count >= 2, "The tracking loop ended before a second drag step: \(samples)")
        #expect(midDrag.allSatisfy { $0.resizeNotifications == 0 })
        #expect(midDrag.allSatisfy { $0.tableWidth == tableWidthBefore })
        let repaintedSteps = zip(midDrag, midDrag.dropFirst()).filter { previous, current in
            current.width > previous.width && current.rowDraws > previous.rowDraws
        }
        #expect(!repaintedSteps.isEmpty, "Row draws during the drag: \(midDrag.map { $0.rowDraws })")
        #expect(drag.resizeNotifications == 1)
    }

    /// A reorder drag posts `columnDidMoveNotification` only at mouse-up, and AppKit neither tiles nor
    /// redraws the table while it lasts, so nothing but the header's own redraws can move the body.
    /// The column-index caches are primed first: a body that follows the drag through caches still
    /// holding the order it started from draws the selection on the wrong columns.
    @Test("A column reorder drag repaints the drawn cells before the mouse comes up")
    func reorderDragRepaintsBeforeMouseUp() throws {
        let rowViews = DrawCountingRowViewSource()
        let grid = makeDraggableGrid(rowViews: rowViews)
        let columnIndex = try #require(grid.coordinator.firstPresentedColumnIndex())
        let dataIndices = Array(0 ..< Self.rows.columns.count)
        for dataIndex in dataIndices {
            _ = grid.coordinator.tableColumnIndex(for: dataIndex)
        }
        let coordinator = grid.coordinator
        let tableView = grid.tableView
        let drag = HeaderDividerDrag(
            window: grid.window,
            header: grid.header,
            tableView: grid.tableView,
            columnIndex: columnIndex,
            rowViews: rowViews,
            startX: grid.header.headerRect(ofColumn: columnIndex).midX,
            cacheAgrees: {
                dataIndices.allSatisfy { dataIndex in
                    guard let identifier = coordinator.columnIdentifier(for: dataIndex) else { return false }
                    return coordinator.tableColumnIndex(for: dataIndex) == tableView.column(withIdentifier: identifier)
                }
            }
        )

        try drag.run()

        let samples = drag.samples
        try #require(
            samples.contains { $0.rowDraws > 0 },
            "The rows never drew, so this host cannot show whether a drag step repaints them"
        )
        let midDrag = samples.filter { $0.draggedColumn >= 0 }
        try #require(midDrag.count >= 2, "The tracking loop ended before a second drag step: \(samples)")
        try #require(
            midDrag.contains { $0.draggedColumn != columnIndex },
            "The drag never passed a neighbour: \(midDrag.map { $0.draggedColumn })"
        )
        #expect(midDrag.allSatisfy { $0.moveNotifications == 0 })
        #expect(midDrag.allSatisfy { $0.cacheAgrees })
        let repaintedSteps = zip(midDrag, midDrag.dropFirst()).filter { previous, current in
            current.rowDraws > previous.rowDraws
        }
        #expect(!repaintedSteps.isEmpty, "Row draws during the drag: \(midDrag.map { $0.rowDraws })")
        #expect(drag.moveNotifications == 1)
    }

    /// A selection is held in display positions, and a reorder that commits moves them, so mouse-up
    /// clears it then. A drag that passes a neighbour and comes back commits nothing, and clearing
    /// the selection at the first pass lost it for a reorder that never happened.
    @Test("A reorder dragged past a neighbour and back keeps the cell selection")
    func reorderDraggedBackKeepsTheSelection() throws {
        let rowViews = DrawCountingRowViewSource()
        let grid = makeDraggableGrid(rowViews: rowViews)
        let columnIndex = try #require(grid.coordinator.firstPresentedColumnIndex())
        grid.coordinator.selectionController.selectEntireColumn(1, totalRows: grid.tableView.numberOfRows)
        let selection = grid.coordinator.selectionController.selection
        try #require(!selection.isEmpty)
        let heading = grid.header.headerRect(ofColumn: columnIndex)
        let outward = (1...6).map { CGFloat($0) * heading.width / 4 }
        let drag = HeaderDividerDrag(
            window: grid.window,
            header: grid.header,
            tableView: grid.tableView,
            columnIndex: columnIndex,
            rowViews: rowViews,
            startX: heading.midX,
            offsets: outward + outward.reversed().dropFirst() + [0]
        )

        try drag.run()

        try #require(
            drag.samples.contains { $0.draggedColumn > columnIndex },
            "The drag never passed a neighbour: \(drag.samples.map { $0.draggedColumn })"
        )
        #expect(drag.moveNotifications == 0)
        #expect(grid.coordinator.selectionController.selection == selection)
    }

    /// While the drag lasts the body draws the column at the pointer. A reorder released before the
    /// column passes a neighbour posts no notification at all, so without a pass of its own the
    /// body kept drawing it there.
    @Test("A reorder released before passing a neighbour repaints the body once it ends")
    func shortReorderRepaintsAfterRelease() throws {
        let rowViews = DrawCountingRowViewSource()
        let grid = makeDraggableGrid(rowViews: rowViews)
        let columnIndex = try #require(grid.coordinator.firstPresentedColumnIndex())
        let drag = HeaderDividerDrag(
            window: grid.window,
            header: grid.header,
            tableView: grid.tableView,
            columnIndex: columnIndex,
            rowViews: rowViews,
            startX: grid.header.headerRect(ofColumn: columnIndex).midX,
            stepDistance: 4
        )

        try drag.run()
        grid.window.displayIfNeeded()

        let samples = drag.samples
        let lastSample = try #require(samples.last)
        try #require(
            samples.contains { $0.draggedColumn == columnIndex },
            "The press never started a reorder: \(samples.map { $0.draggedColumn })"
        )
        #expect(drag.moveNotifications == 0)
        #expect(grid.header.draggedColumn == -1)
        #expect(rowViews.rowDraws > lastSample.rowDraws)
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
