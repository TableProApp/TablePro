//
//  DataGridViewportPlacementTests.swift
//  TableProTests
//

import AppKit
import SwiftUI
import TableProPluginKit
import Testing

@testable import TablePro

@MainActor
private final class NoopViewportLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@Suite("Data grid viewport placement", .serialized)
@MainActor
struct DataGridViewportPlacementTests {
    private struct Grid {
        let window: NSWindow
        let scrollView: NSScrollView
        let tableView: KeyHandlingTableView
        let coordinator: TableViewCoordinator

        var headerInset: CGFloat { scrollView.contentView.contentInsets.top }
    }

    private static let rowCount = 300

    private static func rows() -> TableRows {
        TableRows.from(
            queryRows: (0 ..< rowCount).map { [.text("\($0)"), .text("name-\($0)")] },
            columns: ["id", "name"],
            columnTypes: [.text(rawType: "INTEGER"), .text(rawType: "TEXT")]
        )
    }

    private func makeGrid() -> Grid {
        let tableRows = Self.rows()
        let coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: NoopViewportLayoutPersister()
        )
        coordinator.tableRowsProvider = { tableRows }
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.updateCache()

        let tableView = KeyHandlingTableView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
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
            columnTypes: tableRows.columnTypes,
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in 400 }
        )

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.documentView = tableView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        tableView.reloadData()
        window.layoutIfNeeded()
        return Grid(window: window, scrollView: scrollView, tableView: tableView, coordinator: coordinator)
    }

    private func scroll(_ grid: Grid, toRow row: Int, offset: CGFloat = 0, horizontal: CGFloat = 0) {
        let rowOrigin = grid.tableView.rect(ofRow: row).minY
        grid.tableView.scroll(NSPoint(x: horizontal, y: rowOrigin + offset - grid.headerInset))
    }

    @Test("The grid under test carries the header inset AppKit puts on the clip view")
    func harnessHasAHeaderInset() {
        let grid = makeGrid()

        #expect(grid.tableView.headerView != nil)
        #expect(grid.headerInset > 0)
    }

    @Test("The sample names the first row the header does not cover and how far it is scrolled past")
    func sampleReadsTheFirstVisibleRow() throws {
        let grid = makeGrid()
        scroll(grid, toRow: 50, offset: 5)

        let sample = try #require(grid.coordinator.viewportSample())

        #expect(sample.firstVisibleRow == 50)
        #expect(sample.offset == 5)
    }

    @Test("The first row placement puts row 0 below the header and keeps the horizontal position")
    func firstRowSitsBelowTheHeader() throws {
        let grid = makeGrid()
        scroll(grid, toRow: 80, horizontal: 120)
        let horizontal = grid.scrollView.contentView.bounds.origin.x
        #expect(horizontal > 0)

        grid.coordinator.applyViewportPlacement(.firstRow)

        #expect(grid.scrollView.contentView.bounds.origin.y == -grid.headerInset)
        #expect(try #require(grid.coordinator.viewportSample()).firstVisibleRow == 0)
        #expect(grid.scrollView.contentView.bounds.origin.x == horizontal)
    }

    @Test("An anchored placement puts its row back where the reader had it")
    func anchoredPlacementRestoresTheRowAndOffset() throws {
        let grid = makeGrid()

        grid.coordinator.applyViewportPlacement(
            GridViewportPlacement(
                firstVisibleRow: .existing(120),
                firstVisibleOffset: 4,
                selectedRows: [],
                revealsSelection: false
            )
        )

        let sample = try #require(grid.coordinator.viewportSample())
        #expect(sample.firstVisibleRow == 120)
        #expect(sample.offset == 4)
    }

    @Test("A taller inset, as a header with column comments has, is honoured the same way")
    func tallerInsetIsHonoured() throws {
        let grid = makeGrid()
        grid.scrollView.automaticallyAdjustsContentInsets = false
        grid.scrollView.contentInsets = NSEdgeInsets(top: 14, left: 0, bottom: 0, right: 0)
        grid.window.layoutIfNeeded()
        let inset = grid.headerInset
        #expect(inset > 0)

        grid.coordinator.applyViewportPlacement(
            GridViewportPlacement(firstVisibleRow: .existing(60), firstVisibleOffset: 0, selectedRows: [], revealsSelection: false)
        )
        #expect(try #require(grid.coordinator.viewportSample()).firstVisibleRow == 60)

        grid.coordinator.applyViewportPlacement(.firstRow)
        #expect(grid.scrollView.contentView.bounds.origin.y == -inset)
    }

    @Test("A revealed row is selected and scrolled into view")
    func revealedRowIsSelectedAndVisible() {
        let grid = makeGrid()

        grid.coordinator.applyViewportPlacement(
            GridViewportPlacement(firstVisibleRow: nil, firstVisibleOffset: 0, selectedRows: [.existing(250)], revealsSelection: true)
        )

        #expect(grid.tableView.selectedRowIndexes == IndexSet(integer: 250))
        #expect(NSLocationInRange(250, grid.tableView.rows(in: grid.tableView.visibleRect)))
    }

    @Test("Reselecting by row identity puts back a selection a reload dropped")
    func reselectRestoresTheSelectionAfterAReload() {
        let grid = makeGrid()
        grid.coordinator.selectRowsProgrammatically(IndexSet([3, 7]), in: grid.tableView)
        let kept = grid.coordinator.selectedRowIDs()

        grid.tableView.reloadData()
        #expect(grid.tableView.selectedRowIndexes.isEmpty)

        grid.coordinator.reselectRows(kept)
        #expect(grid.tableView.selectedRowIndexes == IndexSet([3, 7]))
    }

    @Test("Replacing the rows closes an inline editor instead of leaving it over another record")
    func fullReplaceDismissesTheInlineEditor() {
        let grid = makeGrid()
        let editor = CellOverlayEditor()
        grid.coordinator.overlayEditor = editor
        editor.show(in: grid.tableView, row: 0, column: 1, columnIndex: 0, value: "0")
        #expect(editor.isActive)

        grid.coordinator.applyFullReplace()

        #expect(!editor.isActive)
    }
}
