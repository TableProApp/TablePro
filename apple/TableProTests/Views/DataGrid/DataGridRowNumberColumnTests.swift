//
//  DataGridRowNumberColumnTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct DataGridRowNumberColumnTests {
    private static func rows(_ count: Int) -> TableRows {
        TableRows.from(
            queryRows: (0..<count).map { [PluginCellValue.text("value \($0)")] },
            columns: ["name"],
            columnTypes: [.text(rawType: "TEXT")]
        )
    }

    private func rowNumberColumns(of grid: HostedDataGrid) -> [NSTableColumn] {
        [grid.main, grid.frozen].compactMap { table in
            table.tableColumns.first { $0.identifier == DataGridPane.rowNumberIdentifier }
        }
    }

    private func rowNumberWidth(rowCount: Int, offset: Int) throws -> CGFloat {
        let grid = HostedDataGrid(rows: Self.rows(rowCount)) { owner, _ in owner.rowNumberOffset = offset }
        defer { grid.close() }
        return try #require(rowNumberColumns(of: grid).first).width
    }

    @Test("Both panes carry the row numbers first, at one width")
    func bothPanesShowRowNumbers() throws {
        let grid = HostedDataGrid(rows: Self.rows(3))
        defer { grid.close() }

        let columns = rowNumberColumns(of: grid)
        try #require(columns.count == 2)
        #expect(grid.main.tableColumns.first === columns[0])
        #expect(grid.frozen.tableColumns.first === columns[1])
        #expect(columns[0].width == columns[1].width)
        #expect(!grid.frozenScrollView.isHidden)
    }

    @Test("A single-digit row count sizes to the floor, pinned at that width")
    func singleDigitHonoursTheFloor() throws {
        let grid = HostedDataGrid(rows: Self.rows(1))
        defer { grid.close() }

        for column in rowNumberColumns(of: grid) {
            #expect(column.width == DataGridMetrics.rowNumberColumnMinWidth)
            #expect(column.minWidth == column.width)
            #expect(column.maxWidth == column.width)
            #expect(column.resizingMask.isEmpty)
        }
    }

    @Test("A five-digit row number grows the column past the floor")
    func fiveDigitsGrowPastTheFloor() throws {
        #expect(try rowNumberWidth(rowCount: 1, offset: 14_000) > DataGridMetrics.rowNumberColumnMinWidth)
    }

    @Test("The width grows with the digits of the last row number on the page")
    func widthGrowsWithDigits() throws {
        let two = try rowNumberWidth(rowCount: 1, offset: 98)
        let four = try rowNumberWidth(rowCount: 1, offset: 9_998)
        let seven = try rowNumberWidth(rowCount: 1, offset: 1_234_566)

        #expect(four >= two)
        #expect(seven > four)
    }

    @Test("A page with more rows widens the column on reload and stays pinned")
    func reloadWidensAndStaysPinned() throws {
        let grid = HostedDataGrid(rows: Self.rows(2))
        defer { grid.close() }
        let narrow = try #require(rowNumberColumns(of: grid).first).width

        grid.owner.rowNumberOffset = 1_000_000
        grid.model.reloadRows()

        let columns = rowNumberColumns(of: grid)
        try #require(columns.count == 2)
        #expect(columns[0].width > narrow)
        #expect(columns[0].width == columns[1].width)
        #expect(columns[0].minWidth == columns[0].width)
        #expect(columns[0].maxWidth == columns[0].width)
    }

    @Test("Turning row numbers off removes the column from both panes")
    func rowNumbersOff() {
        var configuration = DataGridConfiguration()
        configuration.showRowNumbers = false
        let grid = HostedDataGrid(rows: Self.rows(3), configuration: configuration)
        defer { grid.close() }

        #expect(rowNumberColumns(of: grid).isEmpty)
        #expect(grid.frozenScrollView.isHidden)
    }

    @Test("The row-number column is not a data column")
    func rowNumberIsNotData() throws {
        let grid = HostedDataGrid(rows: Self.rows(3))
        defer { grid.close() }
        let column = try #require(rowNumberColumns(of: grid).first)

        #expect(grid.controller.main.columnID(of: column) == nil)
        #expect(grid.controller.main.isRowNumber(column))
        #expect(column.sortDescriptorPrototype == nil)
    }
}
