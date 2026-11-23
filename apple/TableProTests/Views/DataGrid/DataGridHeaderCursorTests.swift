//
//  DataGridHeaderCursorTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

// Records what AppKit's own pass adds instead of installing it, so the grid's rects can be compared with it.
@MainActor
private final class RecordingHeaderView: NSTableHeaderView {
    private var recorded: [DataGridHeaderCursor.Resize] = []

    override func addCursorRect(_ rect: NSRect, cursor object: NSCursor) {
        recorded.append(DataGridHeaderCursor.Resize(rect: rect, cursor: object))
    }

    func stockRects() -> [DataGridHeaderCursor.Resize] {
        recorded = []
        resetCursorRects()
        return recorded
    }
}

@MainActor
private final class HeaderHost {
    let table = NSTableView(frame: .zero)
    let header = RecordingHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 28))
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
    let window: NSWindow
    let columns: [NSTableColumn]

    // The first column is fixed, as the grid's row numbers are.
    init(columns count: Int) {
        table.headerView = header
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.intercellSpacing = NSSize(width: 1, height: 0)
        columns = (0..<count).map { index in
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
            column.minWidth = 30
            column.maxWidth = 1_200
            column.width = 70
            column.resizingMask = index == 0 ? [] : .userResizingMask
            return column
        }
        columns.forEach(table.addTableColumn)
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.documentView = table
        window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        layout()
    }

    func layout() {
        table.tile()
        scrollView.tile()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func scroll(toX x: CGFloat) {
        table.scroll(NSPoint(x: x, y: 0))
        layout()
    }

    var gridRects: [DataGridHeaderCursor.Resize] {
        DataGridHeaderCursor.resizeRects(in: header, of: table)
    }

    func close() {
        window.orderOut(nil)
    }
}

@MainActor
struct DataGridHeaderCursorTests {
    @Test("The divider rects and cursors are AppKit's own, at min width, at max width and fixed")
    func matchesAppKitPerColumnState() {
        let host = HeaderHost(columns: 8)
        defer { host.close() }
        host.columns[2].width = host.columns[2].minWidth
        host.columns[3].maxWidth = host.columns[3].width
        host.columns[4].resizingMask = []
        host.layout()

        let stock = host.header.stockRects()

        #expect(!stock.isEmpty)
        #expect(host.gridRects == stock)
    }

    @Test("A table that refuses column resizing gets no divider rects, as with AppKit")
    func resizingOffAddsNone() {
        let host = HeaderHost(columns: 6)
        defer { host.close() }
        host.table.allowsColumnResizing = false

        #expect(host.header.stockRects().isEmpty)
        #expect(host.gridRects.isEmpty)
    }

    @Test("A hidden column gets what AppKit gives it")
    func hiddenColumnMatchesAppKit() {
        let host = HeaderHost(columns: 6)
        defer { host.close() }
        host.columns[3].isHidden = true
        host.layout()

        #expect(host.gridRects == host.header.stockRects())
    }

    @Test("A 500-column header scrolled to its middle adds a rect for the columns on screen and the divider before them")
    func wideHeaderAddsOnlyWhatIsShown() throws {
        let host = HeaderHost(columns: 500)
        defer { host.close() }
        host.scroll(toX: 250 * 71 + 20)

        let visible = host.header.visibleRect
        let shown = host.table.columnIndexes(in: NSRect(x: visible.minX, y: 0, width: visible.width, height: 1))
        let first = try #require(shown.first)
        let grid = host.gridRects
        let stock = host.header.stockRects()

        #expect(first > 1)
        #expect(stock.count == 499)
        #expect(grid.count == shown.count + 1)
        #expect(grid.allSatisfy { stock.contains($0) })
        #expect(grid.first == stock[first - 2])
    }

    @Test("On the grid's own header the rects cover only the columns on screen")
    func dataGridHeaderTakesTheVisibleRects() {
        let grid = HostedDataGrid(rows: GridFixtureRows.wide(rows: 5, columns: 60))
        defer { grid.close() }
        let header = grid.controller.main.headerView
        let visible = header.visibleRect
        let shown = grid.main.columnIndexes(in: NSRect(x: visible.minX, y: 0, width: visible.width, height: 1))
        let rects = DataGridHeaderCursor.resizeRects(in: header, of: grid.main)

        #expect(!rects.isEmpty)
        #expect(rects.count <= shown.count)
        #expect(rects.count < grid.main.tableColumns.count - 1)
    }
}
