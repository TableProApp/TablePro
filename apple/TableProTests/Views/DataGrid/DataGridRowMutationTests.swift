//
//  DataGridRowMutationTests.swift
//  TableProTests
//

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct DataGridRowMutationTests {
    private static func rows(_ count: Int) -> TableRows {
        TableRows.from(
            queryRows: (0..<count).map { [.text("\($0)"), .text("name-\($0)")] },
            columns: ["id", "name"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")]
        )
    }

    private static func block(rows: ClosedRange<Int>) -> GridSelection {
        .single(
            GridRect(rows: rows, columns: 0...1),
            anchor: GridCoord(row: rows.lowerBound, displayColumn: 0),
            active: GridCoord(row: rows.upperBound, displayColumn: 1)
        )
    }

    private func expectTablesCount(_ grid: HostedDataGrid, _ count: Int) {
        #expect(grid.model.rowCount == count)
        #expect(grid.main.numberOfRows == count)
        #expect(grid.frozen.numberOfRows == count)
    }

    // MARK: - Row count

    @Test("Both tables count the rows the owner holds once they load")
    func tablesCountLoadedRows() {
        let grid = HostedDataGrid(rows: Self.rows(3))
        defer { grid.close() }

        expectTablesCount(grid, 3)
        #expect(grid.controller.numberOfRows(in: grid.main) == grid.owner.tableRows.count)
    }

    @Test("Appended rows reach both tables")
    func appendedRowsReachBothTables() {
        let grid = HostedDataGrid(rows: Self.rows(0))
        defer { grid.close() }

        grid.model.apply(grid.owner.tableRows.appendInsertedRow(values: [.text("a"), .text("a")]))
        grid.model.apply(grid.owner.tableRows.appendInsertedRow(values: [.text("b"), .text("b")]))

        expectTablesCount(grid, 2)
    }

    @Test("Removed rows leave both tables")
    func removedRowsLeaveBothTables() {
        let grid = HostedDataGrid(rows: Self.rows(3))
        defer { grid.close() }

        grid.model.apply(grid.owner.tableRows.remove(rowIDs: [.existing(1)]))

        expectTablesCount(grid, 2)
        #expect(grid.model.rowID(at: 1) == .existing(2))
    }

    @Test("A full replace reaches both tables")
    func fullReplaceReachesBothTables() {
        let grid = HostedDataGrid(rows: Self.rows(1))
        defer { grid.close() }

        let replacement: [[PluginCellValue]] = ["x", "y", "z", "w"].map { [.text($0), .text($0)] }
        grid.model.apply(grid.owner.tableRows.replace(rows: replacement))

        expectTablesCount(grid, 4)
    }

    @Test("Both tables count only the rows a value filter keeps")
    func tablesCountFilteredRows() {
        let grid = HostedDataGrid(rows: Self.rows(3))
        defer { grid.close() }

        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: ["name-0", "name-2"], includesNull: false), columnName: "name", forColumn: 1)
        grid.model.setValueFilter(filter)

        expectTablesCount(grid, 2)
        #expect(grid.model.rowID(at: 0) == .existing(0))
        #expect(grid.model.rowID(at: 1) == .existing(2))
    }

    // MARK: - Selection follows its records

    @Test("Discarding an inserted row above the selection keeps it on the same records")
    func discardingInsertedRowShiftsSelection() {
        let grid = HostedDataGrid(rows: Self.rows(5))
        defer { grid.close() }
        let insertedID = RowID.inserted(UUID())
        grid.model.apply(grid.owner.tableRows.insertInsertedRow(at: 1, id: insertedID, values: [.text("9"), .text("new")]))
        grid.model.setSelection(Self.block(rows: 3...4))
        #expect(grid.model.selectedRowIDs == [.existing(2), .existing(3)])

        grid.model.apply(grid.owner.tableRows.remove(rowIDs: [insertedID]))

        #expect(grid.model.selection.rectangles == [GridRect(rows: 2...3, columns: 0...1)])
        #expect(grid.model.selectedRowIDs == [.existing(2), .existing(3)])
        #expect(grid.main.selectedRowIndexes == IndexSet(integersIn: 2...3))
        expectTablesCount(grid, 5)
    }

    @Test("A row added above the selection moves it down with its records")
    func insertingRowAboveShiftsSelection() {
        let grid = HostedDataGrid(rows: Self.rows(5))
        defer { grid.close() }
        grid.model.setSelection(Self.block(rows: 1...2))

        grid.model.apply(grid.owner.tableRows.insertInsertedRow(at: 0, values: [.text("9"), .text("new")]))

        #expect(grid.model.selection.rectangles == [GridRect(rows: 2...3, columns: 0...1)])
        #expect(grid.model.selectedRowIDs == [.existing(1), .existing(2)])
        #expect(grid.main.selectedRowIndexes == IndexSet(integersIn: 2...3))
        #expect(grid.frozen.selectedRowIndexes == IndexSet(integersIn: 2...3))
        expectTablesCount(grid, 6)
    }

    // The old grid dropped the selection here; the model now keeps it by identity.
    @Test("Under a value filter a row change keeps the selection on its records")
    func valueFilterKeepsSelection() {
        let grid = HostedDataGrid(rows: Self.rows(5))
        defer { grid.close() }
        var filter = GridValueFilterState()
        filter.set(
            ColumnValueFilter(selectedValues: ["name-1", "name-2", "name-3"], includesNull: false),
            columnName: "name",
            forColumn: 1
        )
        grid.model.setValueFilter(filter)
        grid.model.setSelection(Self.block(rows: 0...1))
        #expect(grid.model.selectedRowIDs == [.existing(1), .existing(2)])

        grid.model.apply(grid.owner.tableRows.remove(rowIDs: [.existing(4)]))

        #expect(grid.model.selectedRowIDs == [.existing(1), .existing(2)])
        #expect(grid.model.selection.rectangles == [GridRect(rows: 0...1, columns: 0...1)])
        #expect(grid.main.selectedRowIndexes == IndexSet(integersIn: 0...1))
        expectTablesCount(grid, 3)
    }

    @Test("A row added above the cursor moves the cursor with its record")
    func insertingRowAboveShiftsCursor() {
        let grid = HostedDataGrid(rows: Self.rows(5))
        defer { grid.close() }
        grid.model.setSelection(GridSelectionReducer.single(GridCoord(row: 2, displayColumn: 1)))

        grid.model.apply(grid.owner.tableRows.insertInsertedRow(at: 0, values: [.text("9"), .text("new")]))

        #expect(grid.model.selection.activeCell == GridCoord(row: 3, displayColumn: 1))
        #expect(grid.model.activeCell?.rowID == .existing(2))
        #expect(grid.main.selectedRowIndexes == IndexSet(integer: 3))
    }

    @Test("A row added below the cursor leaves it where it is")
    func insertingRowBelowKeepsCursor() {
        let grid = HostedDataGrid(rows: Self.rows(5))
        defer { grid.close() }
        grid.model.setSelection(GridSelectionReducer.single(GridCoord(row: 2, displayColumn: 1)))

        grid.model.apply(grid.owner.tableRows.insertInsertedRow(at: 4, values: [.text("9"), .text("new")]))

        #expect(grid.model.selection.activeCell == GridCoord(row: 2, displayColumn: 1))
        #expect(grid.model.activeCell?.rowID == .existing(2))
        #expect(grid.main.selectedRowIndexes == IndexSet(integer: 2))
    }

    @Test("Removing a row above the cursor moves it up, and removing its own row clears it")
    func removingRowsShiftsOrClearsCursor() {
        let grid = HostedDataGrid(rows: Self.rows(5))
        defer { grid.close() }
        grid.model.setSelection(GridSelectionReducer.single(GridCoord(row: 3, displayColumn: 1)))

        grid.model.apply(grid.owner.tableRows.remove(rowIDs: [.existing(0)]))

        #expect(grid.model.selection.activeCell == GridCoord(row: 2, displayColumn: 1))
        #expect(grid.model.activeCell?.rowID == .existing(3))
        #expect(grid.main.selectedRowIndexes == IndexSet(integer: 2))

        grid.model.apply(grid.owner.tableRows.remove(rowIDs: [.existing(3)]))

        #expect(grid.model.selection == .empty)
        #expect(grid.model.activeCell == nil)
        #expect(grid.main.selectedRowIndexes.isEmpty)
    }
}
