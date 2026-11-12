//
//  DataGridContextMenuTransientTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct DataGridContextMenuTransientTests {
    @Test("An open row menu holds the grid until it closes")
    func rowMenuHoldsTheGrid() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let menu = try #require(grid.main.menu)

        #expect(!grid.model.holdsTransientUI)
        grid.controller.menuWillOpen(menu)
        #expect(grid.model.holdsTransientUI)
        grid.controller.menuDidClose(menu)
        #expect(!grid.model.holdsTransientUI)
    }

    @Test("The header menu reports its opening to the grid and keeps the items it was built with")
    func headerMenuHoldsTheGrid() throws {
        let grid = HostedDataGrid(rows: GridFixtureRows.people)
        defer { grid.close() }
        let column = try #require(grid.tableColumn(named: "name"))
        let menu = try #require(grid.controller.headerMenu(forTableColumn: column, in: .main))
        let items = menu.items.count
        #expect(items > 0)
        #expect(menu.delegate === grid.controller)

        grid.controller.menuNeedsUpdate(menu)
        #expect(menu.items.count == items)

        grid.controller.menuWillOpen(menu)
        #expect(grid.model.holdsTransientUI)
        grid.controller.menuDidClose(menu)
        #expect(!grid.model.holdsTransientUI)
    }
}
