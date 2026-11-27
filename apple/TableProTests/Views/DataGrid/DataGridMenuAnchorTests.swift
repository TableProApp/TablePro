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
        let active = GridCoord(row: 3, displayColumn: 2)
        grid.model.setSelection(GridSelectionReducer.range(from: GridCoord(row: 1, displayColumn: 1), to: active))
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

    @Test("The keyboard's menu key anchors on the active cell, not the middle of its row")
    func keyboardAnchorRectIsTheActiveCell() throws {
        guard #available(macOS 15.0, *) else { return }
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        grid.model.setSelection(GridSelectionReducer.single(GridCoord(row: 2, displayColumn: 0)))
        let column = try #require(grid.tableIndex(ofDisplayPosition: 0))

        #expect(grid.main.selectionAnchorRect == grid.main.frameOfCell(atColumn: column, row: 2))
    }

    @Test("With nothing selected the grid has no anchor, so Show Menu opens its empty-space menu")
    func noSelectionHasNoAnchor() {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        grid.model.setSelection(.empty)

        #expect(grid.main.contextMenuAnchor == nil)
        #expect(grid.frozen.contextMenuAnchor == nil)
    }
}
