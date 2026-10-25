//
//  DataGridViewportTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct DataGridViewportTests {
    private func makeGrid() -> HostedDataGrid {
        HostedDataGrid(rows: GridFixtureRows.wide(rows: 300), size: NSSize(width: 500, height: 300))
    }

    private func scroll(_ grid: HostedDataGrid, toRow row: Int, offset: CGFloat = 0, horizontal: CGFloat = 0) {
        let table = grid.main
        table.scroll(NSPoint(x: horizontal, y: table.rect(ofRow: row).minY + offset - grid.controller.headerInset))
    }

    private func placement(row: Int?, offset: CGFloat = 0, selecting: [RowID] = [], reveals: Bool = false) -> GridViewportPlacement {
        GridViewportPlacement(
            firstVisibleRow: row.map { RowID.existing($0) },
            firstVisibleOffset: offset,
            selectedRows: selecting,
            revealsSelection: reveals
        )
    }

    @Test("The grid carries the header inset AppKit puts on the clip view")
    func gridHasAHeaderInset() {
        let grid = makeGrid()
        defer { grid.close() }

        #expect(grid.main.headerView != nil)
        #expect(grid.controller.headerInset > 0)
    }

    @Test("The sample names the first row the header does not cover and how far it is scrolled past")
    func sampleReadsTheFirstVisibleRow() throws {
        let grid = makeGrid()
        defer { grid.close() }
        scroll(grid, toRow: 50, offset: 5)

        let sample = try #require(grid.controller.viewportSample())

        #expect(sample.row == 50)
        #expect(sample.offset == 5)
        #expect(grid.model.viewportSample()?.row == 50)
    }

    @Test("The first row placement puts row 0 below the header and keeps the horizontal position")
    func firstRowSitsBelowTheHeader() throws {
        let grid = makeGrid()
        defer { grid.close() }
        scroll(grid, toRow: 80, horizontal: 120)
        let clip = grid.mainScrollView.contentView
        let horizontal = clip.bounds.origin.x
        try #require(horizontal > 0)

        grid.model.store.viewportAnchor = .firstRow
        grid.controller.applyStagedViewport()

        #expect(clip.bounds.origin.y == -grid.controller.headerInset)
        #expect(grid.controller.viewportSample()?.row == 0)
        #expect(clip.bounds.origin.x == horizontal)
        #expect(grid.model.store.viewportAnchor == nil)
    }

    @Test("An anchored placement puts its row back where the reader had it")
    func anchoredPlacementRestoresTheRowAndOffset() throws {
        let grid = makeGrid()
        defer { grid.close() }

        grid.model.store.viewportAnchor = placement(row: 120, offset: 4)
        grid.controller.applyStagedViewport()

        let sample = try #require(grid.controller.viewportSample())
        #expect(sample.row == 120)
        #expect(sample.offset == 4)
    }

    @Test("A placement staged before a reload is applied by that reload, once")
    func stagedPlacementLandsOnReload() throws {
        let grid = makeGrid()
        defer { grid.close() }

        grid.model.store.viewportAnchor = placement(row: 120)
        grid.model.reloadRows()

        #expect(grid.controller.viewportSample()?.row == 120)
        #expect(grid.model.store.viewportAnchor == nil)
    }

    @Test("A taller header inset is honoured the same way")
    func tallerInsetIsHonoured() throws {
        let grid = makeGrid()
        defer { grid.close() }
        grid.mainScrollView.automaticallyAdjustsContentInsets = false
        grid.mainScrollView.contentInsets = NSEdgeInsets(top: 14, left: 0, bottom: 0, right: 0)
        grid.layout()
        let inset = grid.controller.headerInset
        try #require(inset > 0)

        grid.model.store.viewportAnchor = placement(row: 60)
        grid.controller.applyStagedViewport()
        #expect(grid.controller.viewportSample()?.row == 60)

        grid.model.store.viewportAnchor = .firstRow
        grid.controller.applyStagedViewport()
        #expect(grid.mainScrollView.contentView.bounds.origin.y == -inset)
    }

    @Test("A placement that reveals its selection selects the row and scrolls it into view")
    func revealedRowIsSelectedAndVisible() async throws {
        let grid = makeGrid()
        defer { grid.close() }

        grid.model.store.viewportAnchor = placement(row: nil, selecting: [.existing(250)], reveals: true)
        grid.controller.applyStagedViewport()

        try await waitUntil { grid.main.selectedRowIndexes == IndexSet(integer: 250) }
        #expect(grid.model.selectedRowIDs == [.existing(250)])
        #expect(NSLocationInRange(250, grid.main.rows(in: grid.main.visibleRect)))
    }

    @Test("Revealing a row scrolls the frozen pane with it")
    func revealScrollsBothPanes() async throws {
        let grid = makeGrid()
        defer { grid.close() }

        grid.model.reveal(rowID: .existing(200))

        let mainClip = grid.mainScrollView.contentView
        let frozenClip = grid.frozenScrollView.contentView
        #expect(NSLocationInRange(200, grid.main.rows(in: grid.main.visibleRect)))
        try await waitUntil { frozenClip.bounds.origin.y == mainClip.bounds.origin.y }
    }
}
