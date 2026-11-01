//
//  DataGridAccessibilityMountTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
private final class FlippedPage: NSView {
    override var isFlipped: Bool { true }
}

// A fitsRows grid on a page that scrolls, placed by hand the way the Definition page places it.
@MainActor
private final class FittedGridOnPage {
    let grid: HostedDataGrid
    private let page = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    private let document = FlippedPage(frame: .zero)

    init(rows: TableRows, top: CGFloat, height: CGFloat) {
        var configuration = DataGridConfiguration()
        configuration.fitsRows = true
        grid = HostedDataGrid(rows: rows, configuration: configuration)
        page.hasVerticalScroller = true
        page.documentView = document
        grid.window.contentView = page
        let gridView = grid.controller.view
        gridView.removeFromSuperview()
        gridView.autoresizingMask = []
        document.addSubview(gridView)
        place(top: top, height: height)
        // HostedDataGrid first laid the grid out in a plain window; a reload starts it over where it now sits.
        grid.model.reloadRows()
        grid.layout()
    }

    var fittedHeight: CGFloat { grid.controller.measuredFittingHeight }

    func place(top: CGFloat, height: CGFloat) {
        document.frame = NSRect(x: 0, y: 0, width: page.bounds.width, height: max(page.bounds.height, top + height))
        grid.controller.view.frame = NSRect(x: 0, y: top, width: page.bounds.width, height: height)
        grid.layout()
    }

    // What an assistive client does on its first look: down to each cell's children, which prepares the cell's row.
    func readEveryRow() {
        let rows = grid.main.accessibilityAttributeValue(.children) as? [NSObject] ?? []
        for row in rows {
            let cells = row.accessibilityAttributeValue(.children) as? [NSObject] ?? []
            for cell in cells {
                _ = cell.accessibilityAttributeValue(.children)
            }
        }
    }

    var preparedRows: IndexSet {
        IndexSet((0..<grid.main.numberOfRows).filter { grid.main.rowView(atRow: $0, makeIfNecessary: false) != nil })
    }

    var mountedRows: IndexSet {
        IndexSet((0..<grid.main.numberOfRows).filter {
            grid.main.view(atColumn: 0, row: $0, makeIfNecessary: false) is DataGridAccessibilityCellView
        })
    }

    var visibleRows: IndexSet {
        let range = grid.main.rows(in: grid.main.visibleRect)
        return IndexSet(integersIn: range.location..<(range.location + range.length))
    }

    func close() {
        grid.close()
    }
}

extension GlobalStateSuites {
    @MainActor
    struct DataGridAccessibilityMountTests {
        private let everyRow = IndexSet(integersIn: 0..<5)

        // A fitted grid mounts at height 0 and grows once it has measured its rows. A client that reads it in
        // between prepares every row while none is on screen, so none got a stand-in, and growing is no scroll.
        @Test("A fitted grid read before it grows publishes every row once it has grown")
        func rowsReadBeforeTheGridGrowsMount() async throws {
            let wasActive = DataGridAccessibility.isActive
            DataGridAccessibility.isActive = true
            defer { DataGridAccessibility.isActive = wasActive }
            let page = FittedGridOnPage(rows: GridFixtureRows.people, top: 40, height: 0)
            defer { page.close() }

            page.readEveryRow()
            try #require(page.preparedRows == everyRow)
            try #require(page.mountedRows.isEmpty)

            page.place(top: 40, height: page.fittedHeight)
            #expect(page.visibleRows == everyRow)

            try await waitUntil { page.mountedRows == everyRow }
        }

        // The page moves a grid when a section above it collapses, which neither scrolls nor resizes the grid.
        @Test("A grid moved onto the page publishes its rows to the next read")
        func rowsMovedOntoThePageMountOnTheNextRead() async throws {
            let wasActive = DataGridAccessibility.isActive
            DataGridAccessibility.isActive = true
            defer { DataGridAccessibility.isActive = wasActive }
            let page = FittedGridOnPage(rows: GridFixtureRows.people, top: 40, height: 0)
            defer { page.close() }
            let height = page.fittedHeight
            page.place(top: 1_000, height: height)
            page.readEveryRow()
            try #require(page.visibleRows.isEmpty)

            page.place(top: 40, height: height)
            try #require(page.visibleRows == everyRow)
            page.readEveryRow()

            try await waitUntil { page.mountedRows == everyRow }
        }

        @Test("Only the rows on the page get a stand-in, however many a client reads")
        func onlyRowsOnThePageMount() async throws {
            let wasActive = DataGridAccessibility.isActive
            DataGridAccessibility.isActive = true
            defer { DataGridAccessibility.isActive = wasActive }
            let page = FittedGridOnPage(rows: GridFixtureRows.wide(rows: 80, columns: 3), top: 0, height: 0)
            defer { page.close() }
            page.place(top: 0, height: page.fittedHeight)
            let onPage = page.visibleRows
            try #require(!onPage.isEmpty && onPage.count < 80)

            page.readEveryRow()
            try await waitUntil { page.mountedRows == onPage }
        }
    }
}
