//
//  DataGridEmptyResultColumnsTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

// A failed run leaves an error result with no columns and no rows under the banner, over the grid
// that showed the previous result.
@MainActor
struct DataGridEmptyResultColumnsTests {
    private static func result(_ columns: [String], rowCount: Int = 1) -> TableRows {
        TableRows.from(
            queryRows: (0..<rowCount).map { row in columns.map { PluginCellValue.text("\($0)-\(row)") } },
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: columns.count)
        )
    }

    private func headings(of grid: HostedDataGrid) -> [String] {
        grid.main.tableColumns
            .filter { $0.identifier != DataGridPane.rowNumberIdentifier }
            .map { $0.headerCell.stringValue }
    }

    private func show(_ rows: TableRows, in grid: HostedDataGrid) {
        grid.owner.tableRows = rows
        grid.model.reloadRows()
        grid.layout()
    }

    @Test("An error result takes down the headings of the result before it")
    func errorResultDropsThePreviousHeadings() throws {
        let grid = HostedDataGrid(rows: Self.result(["first_col", "second_col"]))
        defer { grid.close() }
        show(Self.result(["third_col"]), in: grid)
        try #require(headings(of: grid) == ["third_col"])

        show(TableRows(), in: grid)

        #expect(headings(of: grid).isEmpty)
        #expect(grid.main.numberOfRows == 0)
        #expect(grid.model.columns.isEmpty)
    }

    @Test("Updating to an error result leaves what a fresh mount over it shows")
    func updateMatchesAFreshMount() throws {
        let updated = HostedDataGrid(rows: Self.result(["third_col"]))
        defer { updated.close() }
        let fresh = HostedDataGrid(rows: TableRows())
        defer { fresh.close() }
        try #require(fresh.main.tableColumns.map { $0.identifier } == [DataGridPane.rowNumberIdentifier])

        show(TableRows(), in: updated)

        #expect(updated.main.tableColumns.map { $0.identifier } == fresh.main.tableColumns.map { $0.identifier })
        #expect(updated.frozen.tableColumns.map { $0.identifier } == fresh.frozen.tableColumns.map { $0.identifier })
    }

    @Test("The headings come back when a result with columns follows an error result")
    func headingsReturnAfterAnErrorResult() {
        let grid = HostedDataGrid(rows: Self.result(["third_col"]))
        defer { grid.close() }
        show(TableRows(), in: grid)

        show(Self.result(["x"], rowCount: 2), in: grid)

        #expect(headings(of: grid) == ["x"])
        #expect(grid.main.numberOfRows == 2)
        #expect(grid.frozen.numberOfRows == 2)
    }
}
