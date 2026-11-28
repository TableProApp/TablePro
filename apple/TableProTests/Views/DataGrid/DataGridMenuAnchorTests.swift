//
//  DataGridMenuAnchorTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct DataGridMenuAnchorTests {
    @Test("A menu opened without a pointer opens on the active cell and acts on the selection around it")
    func anchorIsTheActiveCell() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let start = GridCoord(row: 1, displayColumn: 1)
        let active = GridCoord(row: 3, displayColumn: 2)
        grid.model.setSelection(GridSelection(rectangles: [GridRect.between(start, active)], activeCell: active, anchor: start))
        let column = try #require(grid.tableIndex(ofDisplayPosition: 2))

        let anchor = try #require(grid.main.contextMenuAnchor)
        #expect(anchor.row == 3)
        #expect(anchor.column == column)

        let event = try #require(grid.main.contextMenuEvent(row: anchor.row, column: anchor.column))
        let menu = try #require(grid.main.menu(for: event))
        #expect(grid.main.clickedRow == 3)
        #expect(grid.main.clickedColumn == column)
        grid.controller.menuNeedsUpdate(menu)
        let context = try #require(menu.items.lazy.compactMap { $0.representedObject as? DataGridMenuContext }.first)
        #expect(context.isCurrentSelection)
    }

    @Test("A deferred menu recognizes a grid row by the row it shows, not its position")
    func rowIdentityIsTheRowID() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let first = try #require(grid.model.rowID(at: 0))

        #expect(grid.main.contextMenuIdentity(ofRow: 0) == AnyHashable(first))
        #expect(grid.main.contextMenuIdentity(ofRow: 1) != grid.main.contextMenuIdentity(ofRow: 0))
    }

    @Test("With nothing selected the grid has no anchor and leaves Show Menu to AppKit")
    func noSelectionHasNoAnchor() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        grid.model.setSelection(.empty)

        #expect(grid.main.contextMenuAnchor == nil)
        #expect(grid.frozen.contextMenuAnchor == nil)
    }
}
