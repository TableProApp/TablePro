//
//  GridSelectionRestoreTests.swift
//  TableProTests
//
//  A restored selection is clamped to the result now on screen. `NSTableView.selectRowIndexes` is
//  all-or-nothing on an out-of-range member, measured, so an unclamped push selects nothing at all
//  rather than the rows that do still exist.
//

import Foundation
import Testing

@testable import TablePro

@Suite("GridSelectionRestore")
struct GridSelectionRestoreTests {
    private func rect(rows: ClosedRange<Int>, columns: ClosedRange<Int>) -> GridSelection {
        GridSelection(
            rectangles: [GridRect(rows: rows, columns: columns)],
            activeCell: GridCoord(row: rows.upperBound, displayColumn: columns.upperBound),
            anchor: GridCoord(row: rows.lowerBound, displayColumn: columns.lowerBound)
        )
    }

    @Test("a row selection that still fits is restored whole")
    func rowsThatFitAreRestored() {
        let resolved = GridSelectionRestore.resolve(
            storedRows: [2, 5, 7],
            storedCells: .empty,
            rowLimit: 10,
            columnLimit: 4
        )

        #expect(resolved.publishedRows == [2, 5, 7])
        #expect(resolved.nativeRows == [2, 5, 7])
        #expect(resolved.cells.isEmpty)
    }

    @Test("rows past the end are dropped and the rest survive")
    func rowsPastTheEndAreDropped() {
        let resolved = GridSelectionRestore.resolve(
            storedRows: [2, 900],
            storedCells: .empty,
            rowLimit: 10,
            columnLimit: 4
        )

        #expect(resolved.publishedRows == [2])
    }

    @Test("a result with no rows restores nothing")
    func emptyResultRestoresNothing() {
        let resolved = GridSelectionRestore.resolve(
            storedRows: [0, 1],
            storedCells: rect(rows: 0...1, columns: 0...1),
            rowLimit: 0,
            columnLimit: 4
        )

        #expect(resolved == .none)
    }

    @Test("a cell rectangle restores as a rectangle, not as whole rows")
    func cellRectangleKeepsItsColumns() {
        let resolved = GridSelectionRestore.resolve(
            storedRows: [1],
            storedCells: rect(rows: 1...3, columns: 2...4),
            rowLimit: 10,
            columnLimit: 8
        )

        #expect(resolved.publishedRows == [1, 2, 3])
        #expect(resolved.cells.rectangles == [GridRect(rows: 1...3, columns: 2...4)])
        /// AppKit fills a natively selected row edge to edge, so only the anchor the table view
        /// actually held goes back, or the rectangle is painted and navigated as whole rows.
        #expect(resolved.nativeRows == [1])
    }

    /// The rows the table view reports during a cell drag are the anchor alone, so restoring from
    /// them would shrink the reader's block to one row.
    @Test("a cell rectangle outranks the anchor row the table view reported")
    func cellRectangleOutranksStoredRows() {
        let resolved = GridSelectionRestore.resolve(
            storedRows: [1],
            storedCells: rect(rows: 1...4, columns: 0...0),
            rowLimit: 10,
            columnLimit: 8
        )

        #expect(resolved.publishedRows == [1, 2, 3, 4])
        #expect(resolved.nativeRows == [1])
    }

    @Test("a rectangle overhanging the result is trimmed to what fits")
    func rectangleIsTrimmedToFit() {
        let resolved = GridSelectionRestore.resolve(
            storedRows: [],
            storedCells: rect(rows: 1...9, columns: 0...6),
            rowLimit: 5,
            columnLimit: 3
        )

        #expect(resolved.cells.rectangles == [GridRect(rows: 1...4, columns: 0...2)])
        #expect(resolved.publishedRows == [1, 2, 3, 4])
        #expect(resolved.nativeRows.isEmpty)
    }

    @Test("a rectangle entirely past the end restores nothing")
    func rectangleEntirelyPastTheEndRestoresNothing() {
        let resolved = GridSelectionRestore.resolve(
            storedRows: [],
            storedCells: rect(rows: 20...30, columns: 0...1),
            rowLimit: 5,
            columnLimit: 3
        )

        #expect(resolved == .none)
    }

    /// The row-number gutter is still there and still selectable when every data column is hidden,
    /// so a row selection is valid and must come back.
    @Test("a row selection is restored even with no data columns presented")
    func rowsRestoreWithNoPresentedColumns() {
        let resolved = GridSelectionRestore.resolve(
            storedRows: [1, 2],
            storedCells: rect(rows: 1...2, columns: 0...0),
            rowLimit: 10,
            columnLimit: 0
        )

        #expect(resolved.publishedRows == [1, 2])
        #expect(resolved.cells.isEmpty)
    }

    @Test("an active cell outside the trimmed result is dropped rather than restored")
    func activeCellOutsideResultIsDropped() {
        let selection = GridSelection(
            rectangles: [GridRect(rows: 0...9, columns: 0...0)],
            activeCell: GridCoord(row: 9, displayColumn: 0),
            anchor: GridCoord(row: 0, displayColumn: 0)
        )

        let resolved = GridSelectionRestore.resolve(
            storedRows: [],
            storedCells: selection,
            rowLimit: 4,
            columnLimit: 2
        )

        #expect(resolved.cells.activeCell == nil)
        #expect(resolved.cells.anchor == GridCoord(row: 0, displayColumn: 0))
    }
}
