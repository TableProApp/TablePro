//
//  DataGridColumnOrderTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct DataGridColumnOrderTests {
    private static func rows(_ columns: [String], count: Int = 3) -> TableRows {
        TableRows.from(
            queryRows: (0..<count).map { row in columns.map { PluginCellValue.text("\($0)\(row)") } },
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: columns.count)
        )
    }

    private static let base = ["id", "notes", "email"]

    private func tableIndex(of name: String, in grid: HostedDataGrid) throws -> Int {
        let column = try #require(grid.tableColumn(named: name))
        return grid.main.column(withIdentifier: column.identifier)
    }

    // Dragging a header moves the table column first; AppKit then posts the move the grid writes back.
    private func moveColumn(named name: String, toDisplayPosition position: Int, in grid: HostedDataGrid) throws {
        let from = try tableIndex(of: name, in: grid)
        let leading = grid.controller.main.hasRowNumberColumn ? 1 : 0
        grid.main.moveColumn(from, toColumn: leading + position)
    }

    // MARK: - Display positions

    @Test("Every display position maps to the table column after the row numbers")
    func displayPositionsFollowTheRowNumbers() {
        let grid = HostedDataGrid(rows: Self.rows(Self.base))
        defer { grid.close() }

        #expect(grid.tableIndex(ofDisplayPosition: 0) == 1)
        #expect(grid.tableIndex(ofDisplayPosition: 1) == 2)
        #expect(grid.tableIndex(ofDisplayPosition: 2) == 3)
        for _ in 0..<5 {
            #expect(grid.tableIndex(ofDisplayPosition: 1) == 2)
        }
    }

    @Test("A position past the presented columns maps to no table column")
    func outOfRangePositionResolvesNothing() {
        let grid = HostedDataGrid(rows: Self.rows(["only"]))
        defer { grid.close() }

        #expect(grid.tableIndex(ofDisplayPosition: 5) == nil)
        #expect(grid.model.columns.column(at: 5) == nil)
    }

    @Test("A result with fewer columns drops the positions it no longer has")
    func narrowerResultDropsPositions() {
        let grid = HostedDataGrid(rows: Self.rows(["a", "b"]))
        defer { grid.close() }
        #expect(grid.tableIndex(ofDisplayPosition: 1) == 2)

        grid.owner.tableRows = Self.rows(["a"])
        grid.model.reloadRows()

        #expect(grid.tableIndex(ofDisplayPosition: 1) == nil)
        #expect(grid.main.tableColumns.count == 2)
    }

    @Test("A header drag reorders the model's columns, and positions follow the drawn order")
    func headerDragReordersColumns() throws {
        let grid = HostedDataGrid(rows: Self.rows(Self.base))
        defer { grid.close() }
        #expect(grid.model.columns.orderedNames == ["id", "notes", "email"])

        try moveColumn(named: "email", toDisplayPosition: 0, in: grid)

        #expect(grid.model.columns.orderedNames == ["email", "id", "notes"])
        #expect(grid.model.columns.dataIndex(atDisplayPosition: 0) == 2)
        #expect(grid.model.columns.displayPosition(ofDataIndex: 2) == 0)
        #expect(grid.model.store.columnLayout.columnOrder == ["email", "id", "notes"])
        let emailIndex = try tableIndex(of: "email", in: grid)
        let idIndex = try tableIndex(of: "id", in: grid)
        #expect(emailIndex == 1)
        #expect(grid.tableIndex(ofDisplayPosition: 0) == emailIndex)
        #expect(grid.tableIndex(ofDisplayPosition: 1) == idIndex)
    }

    @Test("A swept block names the columns it crossed in the drawn order")
    func sweptBlockNamesTheColumnsCrossed() throws {
        let grid = HostedDataGrid(rows: Self.rows(Self.base))
        defer { grid.close() }
        try moveColumn(named: "email", toDisplayPosition: 0, in: grid)

        let names = GridRect(rows: 0...0, columns: 0...1).columns.compactMap { grid.model.columns.column(at: $0)?.name }

        #expect(names == ["email", "id"])
    }

    @Test("The presented count is the columns on screen")
    func presentedCountIsTheColumnsOnScreen() {
        let grid = HostedDataGrid(rows: Self.rows(Self.base))
        defer { grid.close() }

        #expect(grid.model.columns.count == 3)
        #expect(grid.model.columns.count == grid.model.rows.columns.count)
        #expect(grid.main.tableColumns.count == 4)
    }

    @Test("A hidden column leaves the display run and the table")
    func hiddenColumnLeavesTheRun() {
        let grid = HostedDataGrid(rows: Self.rows(Self.base))
        defer { grid.close() }

        grid.model.updateColumnLayout { $0.hiddenColumns = ["notes"] }

        #expect(grid.model.columns.orderedNames == ["id", "email"])
        #expect(grid.model.columns.count == 2)
        #expect(grid.model.columns.dataIndex(atDisplayPosition: 1) == 2)
        #expect(grid.model.columns.displayPosition(ofDataIndex: 1) == nil)
        #expect(grid.tableColumn(named: "notes") == nil)
        #expect(grid.main.tableColumns.count == 3)
    }

    // MARK: - Resolving a table column

    @Test("Every table column resolves to its own data column by identity")
    func everyColumnRoundTrips() throws {
        let names = ["id", "name", "customer_id", "total"]
        let grid = HostedDataGrid(rows: Self.rows(names))
        defer { grid.close() }

        for (dataIndex, name) in names.enumerated() {
            let column = try #require(grid.tableColumn(named: name))
            let id = try #require(grid.controller.main.columnID(of: column))
            #expect(id == DataGridColumnID(name: name, occurrence: 0))
            #expect(grid.model.columns.column(id: id)?.dataIndex == dataIndex)
        }
    }

    @Test("A moved column still resolves to the data column it shows")
    func movedColumnResolvesByIdentity() throws {
        let grid = HostedDataGrid(rows: Self.rows(["id", "name", "customer_id"]))
        defer { grid.close() }
        let before = try tableIndex(of: "customer_id", in: grid)

        try moveColumn(named: "customer_id", toDisplayPosition: 0, in: grid)

        let after = try tableIndex(of: "customer_id", in: grid)
        let id = try #require(grid.controller.main.columnID(of: grid.main.tableColumns[after]))
        #expect(after != before)
        #expect(grid.model.columns.column(id: id)?.dataIndex == 2)
        #expect(grid.model.columns.displayPosition(of: id) == 0)
    }

    @Test("The row-number column is not a data column")
    func rowNumberColumnIsNotData() {
        let grid = HostedDataGrid(rows: Self.rows(["id", "name"]))
        defer { grid.close() }
        let pane = grid.controller.main

        let chrome = grid.main.tableColumns.indices.filter { pane.slot(atTableIndex: $0, columns: grid.model.columns) == .rowNumber }

        #expect(chrome == [0])
        #expect(pane.columnID(of: grid.main.tableColumns[0]) == nil)
        #expect(pane.isRowNumber(grid.main.tableColumns[0]))
    }
}
