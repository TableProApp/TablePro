//
//  DataGridTrailingSpaceTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class TrailingSpaceLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// AppKit sizes the table to its columns, so scrolled fully right the last column's divider sat on the
/// viewport's last point, where a resizable window takes the press for its own edge resize. Revealing
/// the last column from the keyboard, Find or Jump to Column put the divider back there.
@Suite("Data grid trailing space", .serialized)
@MainActor
struct DataGridTrailingSpaceTests {
    @MainActor
    private struct Grid {
        let window: NSWindow
        let scrollView: NSScrollView
        let tableView: KeyHandlingTableView
        let coordinator: TableViewCoordinator
        let header: SortableHeaderView

        var clipView: NSClipView { scrollView.contentView }

        var bodyTrailingGap: CGFloat? {
            guard let last = coordinator.lastPresentedColumnIndex() else { return nil }
            let column = clipView.convert(tableView.rect(ofColumn: last), from: tableView)
            return clipView.bounds.maxX - column.maxX
        }

        var headerTrailingGap: CGFloat? {
            guard let last = coordinator.lastPresentedColumnIndex(),
                  let headerClip = header.superview as? NSClipView else { return nil }
            let heading = headerClip.convert(header.headerRect(ofColumn: last), from: header)
            return headerClip.bounds.maxX - heading.maxX
        }

        var documentTrailingRoom: CGFloat? {
            guard let last = coordinator.lastPresentedColumnIndex() else { return nil }
            return tableView.bounds.maxX - tableView.rect(ofColumn: last).maxX
        }

        func layout() {
            scrollView.tile()
            window.layoutIfNeeded()
        }

        func scrollFarRight() {
            tableView.scroll(NSPoint(x: .greatestFiniteMagnitude, y: clipView.bounds.minY))
            layout()
        }

        func scrollToLeadingEdge() {
            tableView.scroll(NSPoint(x: 0, y: clipView.bounds.minY))
            layout()
        }
    }

    private static func tableRows(columnCount: Int) -> TableRows {
        let columns = (0 ..< columnCount).map { "c\($0)" }
        let queryRows = (0 ..< 3).map { row in columns.map { PluginCellValue.text("\($0)-\(row)") } }
        return TableRows.from(
            queryRows: queryRows,
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: "TEXT"), count: columnCount)
        )
    }

    private static func present(
        _ tableRows: TableRows,
        in tableView: NSTableView,
        coordinator: TableViewCoordinator,
        hidden: Set<String> = [],
        columnWidth: CGFloat = 150
    ) {
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: tableRows.columnTypes,
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: hidden,
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in columnWidth }
        )
    }

    private func makeGrid(
        columnCount: Int = 12,
        columnWidth: CGFloat = 150,
        viewportWidth: CGFloat = 800,
        hidden: Set<String> = []
    ) -> Grid {
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: TrailingSpaceLayoutPersister()
        )

        let tableView = KeyHandlingTableView()
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
        tableView.rowHeight = 24
        tableView.usesAutomaticRowHeights = false
        tableView.allowsColumnResizing = true
        tableView.coordinator = coordinator
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView

        let header = SortableHeaderView(frame: NSRect(x: 0, y: 0, width: viewportWidth, height: 28))
        header.coordinator = coordinator
        tableView.headerView = header

        Self.present(
            Self.tableRows(columnCount: columnCount),
            in: tableView,
            coordinator: coordinator,
            hidden: hidden,
            columnWidth: columnWidth
        )

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: viewportWidth, height: 240))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        /// A legacy scroller narrows the clip view, and which style applies is a per-machine setting.
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = tableView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: viewportWidth, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView

        tableView.reloadData()
        let grid = Grid(
            window: window,
            scrollView: scrollView,
            tableView: tableView,
            coordinator: coordinator,
            header: header
        )
        grid.layout()
        return grid
    }

    // MARK: - Scrolled fully right

    @Test("Scrolled fully right, the body and the header end the trailing space past the last column")
    func farRightShowsTheTrailingSpace() throws {
        let grid = makeGrid()

        grid.scrollFarRight()

        try #require(grid.clipView.bounds.minX > 0)
        #expect(grid.bodyTrailingGap == DataGridMetrics.trailingSpace)
        #expect(grid.headerTrailingGap == DataGridMetrics.trailingSpace)
    }

    /// An inset on the clip view scrolls just as far, but leaves the space outside the table and the
    /// header, where no row paints its stripe, selection or tint and no heading paints its chrome.
    @Test("The trailing space is part of the table and the header, not a clip view inset")
    func trailingSpaceIsCoveredByTheTableAndHeader() throws {
        let grid = makeGrid()

        grid.scrollFarRight()

        let headerClip = try #require(grid.header.superview as? NSClipView)
        #expect(grid.documentTrailingRoom == DataGridMetrics.trailingSpace)
        #expect(grid.tableView.frame.maxX == grid.clipView.bounds.maxX)
        #expect(grid.header.frame.maxX == headerClip.bounds.maxX)
    }

    /// AppKit resizes a column from 3pt before its trailing edge to 1pt after it. Flush with the
    /// viewport, only the points before the edge were on screen, and the window's edge resize claims
    /// the last of them.
    @Test("Scrolled fully right, the last column's whole resize band is inside the header")
    func lastDividerResizeBandIsInsideTheHeader() throws {
        let grid = makeGrid()
        grid.scrollFarRight()
        let last = try #require(grid.coordinator.lastPresentedColumnIndex())
        let edge = grid.header.headerRect(ofColumn: last).maxX
        let visible = grid.header.visibleRect

        let divider = NSPoint(x: edge - 1, y: visible.midY)
        #expect(visible.contains(divider))
        #expect(grid.header.isInResizeZone(point: divider))
        for offset: CGFloat in [-3, -2, -1, 0, 1] {
            let point = NSPoint(x: edge + offset, y: visible.midY)
            #expect(visible.contains(point), "\(offset)pt from the last column's trailing edge")
            #expect(grid.header.isInResizeZone(point: point), "\(offset)pt from the last column's trailing edge")
        }
        #expect(visible.maxX - edge == DataGridMetrics.trailingSpace)
    }

    // MARK: - Holding through changes

    @Test("The trailing space survives a reload without moving the viewport")
    func trailingSpaceSurvivesReload() {
        let grid = makeGrid()
        grid.scrollFarRight()

        grid.tableView.reloadData()
        grid.layout()

        #expect(grid.bodyTrailingGap == DataGridMetrics.trailingSpace)
        #expect(grid.headerTrailingGap == DataGridMetrics.trailingSpace)
    }

    /// Measured off-screen on macOS 27, the content clip keeps its old origin after the document
    /// narrows until something scrolls it, while the header clip is clamped at once. Scrolling again
    /// measures the room the reader can reach.
    @Test("The trailing space follows the last column as it widens and narrows")
    func trailingSpaceFollowsTheLastColumnWidth() throws {
        let grid = makeGrid()
        let last = try #require(grid.coordinator.lastPresentedColumnIndex())
        let column = grid.tableView.tableColumns[last]
        grid.scrollFarRight()

        column.width += 60
        grid.layout()
        grid.scrollFarRight()

        #expect(grid.bodyTrailingGap == DataGridMetrics.trailingSpace)
        #expect(grid.headerTrailingGap == DataGridMetrics.trailingSpace)

        column.width -= 120
        grid.layout()
        grid.scrollFarRight()

        #expect(grid.bodyTrailingGap == DataGridMetrics.trailingSpace)
        #expect(grid.headerTrailingGap == DataGridMetrics.trailingSpace)
    }

    @Test("The trailing space survives the viewport growing wider")
    func trailingSpaceSurvivesAWiderViewport() throws {
        let grid = makeGrid(viewportWidth: 800)
        grid.scrollFarRight()

        grid.window.setContentSize(NSSize(width: 1_100, height: 240))
        grid.layout()

        try #require(grid.clipView.bounds.width > 800)
        #expect(grid.bodyTrailingGap == DataGridMetrics.trailingSpace)
        #expect(grid.headerTrailingGap == DataGridMetrics.trailingSpace)
    }

    /// The pool keeps a wider result's surplus slots attached and hidden after the presented columns,
    /// so the last attached column is not the last one the reader sees, and a hidden column's rect is
    /// zero.
    @Test("After a narrower result, the trailing space follows its last presented column")
    func trailingSpaceFollowsANarrowerResult() throws {
        let grid = makeGrid(columnCount: 12)
        grid.scrollFarRight()

        Self.present(Self.tableRows(columnCount: 8), in: grid.tableView, coordinator: grid.coordinator)
        grid.tableView.reloadData()
        grid.layout()
        grid.scrollFarRight()

        let lastAttached = try #require(grid.tableView.tableColumns.last)
        try #require(!grid.coordinator.presentsColumn(lastAttached))
        let lastSlot = grid.tableView.column(withIdentifier: ColumnIdentitySchema.slotIdentifier(7))
        #expect(grid.coordinator.lastPresentedColumnIndex() == lastSlot)
        #expect(grid.bodyTrailingGap == DataGridMetrics.trailingSpace)
        #expect(grid.headerTrailingGap == DataGridMetrics.trailingSpace)
    }

    @Test("Columns the user hid at the end leave the trailing space after the last shown column")
    func userHiddenTrailingColumnsMeasureFromTheLastShownColumn() throws {
        let grid = makeGrid(columnCount: 12, hidden: ["c10", "c11"])
        let last = try #require(grid.coordinator.lastPresentedColumnIndex())
        #expect(last == grid.tableView.column(withIdentifier: ColumnIdentitySchema.slotIdentifier(9)))

        grid.scrollFarRight()

        #expect(grid.bodyTrailingGap == DataGridMetrics.trailingSpace)
        #expect(grid.headerTrailingGap == DataGridMetrics.trailingSpace)
    }

    // MARK: - Revealing a column

    @Test("Revealing the last column shows the trailing space and stays put when repeated")
    func revealingTheLastColumnShowsTheTrailingSpace() throws {
        let grid = makeGrid()
        let last = try #require(grid.coordinator.lastPresentedColumnIndex())
        try #require(grid.clipView.bounds.minX == 0)

        grid.coordinator.scrollColumnToVisible(tableColumnIndex: last)
        grid.layout()

        #expect(grid.bodyTrailingGap == DataGridMetrics.trailingSpace)
        #expect(grid.headerTrailingGap == DataGridMetrics.trailingSpace)

        /// Every arrow key press on the last column reveals it again, so a correction that fought
        /// AppKit would move the viewport on each press.
        let settled = grid.clipView.bounds
        grid.coordinator.scrollColumnToVisible(tableColumnIndex: last)
        grid.layout()

        #expect(grid.clipView.bounds == settled)
        #expect(grid.bodyTrailingGap == DataGridMetrics.trailingSpace)
    }

    /// The trailing space exists after the last column only. A middle column revealed short of the
    /// edge would land unlike every other reveal AppKit makes.
    @Test("Revealing a column before the last one stops where AppKit puts it")
    func revealingAMiddleColumnKeepsAppKitPlacement() throws {
        let grid = makeGrid()
        let last = try #require(grid.coordinator.lastPresentedColumnIndex())
        try #require(grid.documentTrailingRoom == DataGridMetrics.trailingSpace)
        let middle = last - 4
        try #require(grid.coordinator.presentsColumn(atTableColumnIndex: middle))
        try #require(grid.tableView.rect(ofColumn: middle).minX > grid.clipView.bounds.maxX)

        grid.tableView.scrollColumnToVisible(middle)
        grid.layout()
        let appKitPlacement = grid.clipView.bounds
        grid.scrollToLeadingEdge()

        grid.coordinator.scrollColumnToVisible(tableColumnIndex: middle)
        grid.layout()

        let visible = grid.clipView.bounds
        let column = grid.tableView.rect(ofColumn: middle)
        #expect(visible == appKitPlacement)
        #expect(column.maxX <= visible.maxX)
        #expect(column.minX >= visible.minX + DataGridRowGutterView.width(of: grid.tableView))
    }

    // MARK: - Columns that fit

    @Test("Columns that fit with the trailing space to spare leave the grid unscrollable")
    func columnsWithRoomToSpareDoNotScroll() throws {
        let grid = makeGrid(columnCount: 3, columnWidth: 120, viewportWidth: 900)
        let last = try #require(grid.coordinator.lastPresentedColumnIndex())
        let spare = grid.clipView.bounds.width - grid.tableView.rect(ofColumn: last).maxX
        try #require(spare >= DataGridMetrics.trailingSpace)

        #expect(grid.tableView.frame.width == grid.clipView.bounds.width)

        grid.scrollFarRight()

        #expect(grid.clipView.bounds.minX == 0)
    }

    /// One rule for every width: a run that ends just short of the viewport would otherwise leave its
    /// last divider at the window's edge with nothing to scroll.
    @Test("Columns that end inside the trailing space scroll just far enough to show it")
    func columnsEndingNearTheEdgeScrollToTheTrailingSpace() throws {
        let grid = makeGrid(columnCount: 3, columnWidth: 120, viewportWidth: 900)
        let last = try #require(grid.coordinator.lastPresentedColumnIndex())
        let spare = grid.clipView.bounds.width - grid.tableView.rect(ofColumn: last).maxX
        grid.tableView.tableColumns[last].width += spare - 10
        grid.layout()
        try #require(grid.clipView.bounds.width - grid.tableView.rect(ofColumn: last).maxX == 10)

        grid.scrollFarRight()

        #expect(grid.clipView.bounds.minX == DataGridMetrics.trailingSpace - 10)
        #expect(grid.bodyTrailingGap == DataGridMetrics.trailingSpace)
        #expect(grid.headerTrailingGap == DataGridMetrics.trailingSpace)
    }
}
