import Foundation
@testable import TablePro
import Testing

@Suite("CellSelection")
struct CellSelectionTests {
    // MARK: - contains

    @Test("none contains nothing")
    func noneContainsNothing() {
        let sel = CellSelection.none
        #expect(!sel.contains(row: 0, column: 0))
        #expect(!sel.contains(row: 5, column: 3))
    }

    @Test("column contains any row in that column")
    func columnContainsMatchingColumn() {
        let sel = CellSelection.column(2)
        #expect(sel.contains(row: 0, column: 2))
        #expect(sel.contains(row: 999, column: 2))
        #expect(!sel.contains(row: 0, column: 1))
        #expect(!sel.contains(row: 0, column: 3))
    }

    @Test("range contains rows within bounds in correct column")
    func rangeContainsWithinBounds() {
        let sel = CellSelection.range(column: 1, rows: 3...7)
        #expect(sel.contains(row: 3, column: 1))
        #expect(sel.contains(row: 5, column: 1))
        #expect(sel.contains(row: 7, column: 1))
        #expect(!sel.contains(row: 2, column: 1))
        #expect(!sel.contains(row: 8, column: 1))
        #expect(!sel.contains(row: 5, column: 0))
    }

    @Test("cells contains only listed positions")
    func cellsContainsExactPositions() {
        let sel = CellSelection.cells([
            CellPosition(row: 1, column: 2),
            CellPosition(row: 5, column: 3)
        ])
        #expect(sel.contains(row: 1, column: 2))
        #expect(sel.contains(row: 5, column: 3))
        #expect(!sel.contains(row: 1, column: 3))
        #expect(!sel.contains(row: 2, column: 2))
    }

    // MARK: - affectedColumns

    @Test("none has no affected columns")
    func noneAffectedColumns() {
        #expect(CellSelection.none.affectedColumns.isEmpty)
    }

    @Test("column reports single affected column")
    func columnAffectedColumns() {
        let sel = CellSelection.column(4)
        #expect(sel.affectedColumns == IndexSet(integer: 4))
    }

    @Test("range reports single affected column")
    func rangeAffectedColumns() {
        let sel = CellSelection.range(column: 2, rows: 0...10)
        #expect(sel.affectedColumns == IndexSet(integer: 2))
    }

    @Test("cells reports all unique columns")
    func cellsAffectedColumns() {
        let sel = CellSelection.cells([
            CellPosition(row: 0, column: 1),
            CellPosition(row: 2, column: 3),
            CellPosition(row: 4, column: 1)
        ])
        #expect(sel.affectedColumns == IndexSet([1, 3]))
    }

    // MARK: - affectedRows

    @Test("column has no affected rows")
    func columnAffectedRows() {
        #expect(CellSelection.column(0).affectedRows.isEmpty)
    }

    @Test("range reports all rows in bounds")
    func rangeAffectedRows() {
        let sel = CellSelection.range(column: 0, rows: 2...5)
        #expect(sel.affectedRows == IndexSet(integersIn: 2...5))
    }

    @Test("cells reports all unique rows")
    func cellsAffectedRows() {
        let sel = CellSelection.cells([
            CellPosition(row: 1, column: 0),
            CellPosition(row: 3, column: 2),
            CellPosition(row: 1, column: 5)
        ])
        #expect(sel.affectedRows == IndexSet([1, 3]))
    }

    // MARK: - isEmpty

    @Test("none is empty")
    func noneIsEmpty() {
        #expect(CellSelection.none.isEmpty)
    }

    @Test("column is not empty")
    func columnIsNotEmpty() {
        #expect(!CellSelection.column(0).isEmpty)
    }

    @Test("range is not empty")
    func rangeIsNotEmpty() {
        #expect(!CellSelection.range(column: 0, rows: 0...0).isEmpty)
    }

    @Test("cells with elements is not empty")
    func cellsNotEmpty() {
        #expect(!CellSelection.cells([CellPosition(row: 0, column: 0)]).isEmpty)
    }

    @Test("cells with empty set is empty")
    func cellsEmptySetIsEmpty() {
        #expect(CellSelection.cells(Set()).isEmpty)
    }
}

@Suite("TableSelection.reloadIndexes with cellSelection")
struct TableSelectionCellSelectionTests {
    @Test("returns nil when nothing changed")
    func noChangeReturnsNil() {
        let sel = TableSelection(focusedRow: 1, focusedColumn: 2, cellSelection: .column(3))
        #expect(sel.reloadIndexes(from: sel) == nil)
    }

    @Test("returns affected indexes when cellSelection changes from none to range")
    func noneToRangeReturnsIndexes() {
        let old = TableSelection(focusedRow: -1, focusedColumn: -1, cellSelection: .none)
        let new = TableSelection(focusedRow: -1, focusedColumn: -1, cellSelection: .range(column: 2, rows: 3...5))
        let result = new.reloadIndexes(from: old)
        #expect(result != nil)
        #expect(result?.rows == IndexSet(integersIn: 3...5))
        #expect(result?.columns == IndexSet(integer: 2))
    }

    @Test("column-only change has empty affectedRows so reload uses the visible-column side path")
    func columnChangeReturnsNilDueToEmptyRows() {
        let old = TableSelection(focusedRow: -1, focusedColumn: -1, cellSelection: .none)
        let new = TableSelection(focusedRow: -1, focusedColumn: -1, cellSelection: .column(1))
        #expect(new.reloadIndexes(from: old) == nil)
    }

    @Test("focus change combined with cell selection returns union of indexes")
    func focusAndCellSelectionChange() {
        let old = TableSelection(
            focusedRow: 0,
            focusedColumn: 0,
            cellSelection: .cells([CellPosition(row: 2, column: 1)])
        )
        let new = TableSelection(
            focusedRow: 3,
            focusedColumn: 1,
            cellSelection: .cells([CellPosition(row: 4, column: 2)])
        )
        guard let result = new.reloadIndexes(from: old) else {
            Issue.record("expected reload indexes for combined focus and cell selection change")
            return
        }
        #expect(result.rows.contains(0))
        #expect(result.rows.contains(2))
        #expect(result.rows.contains(3))
        #expect(result.rows.contains(4))
        #expect(result.columns.contains(0))
        #expect(result.columns.contains(1))
        #expect(result.columns.contains(2))
    }

    @Test("anchor-only change does not trigger a reload")
    func anchorOnlyChangeReturnsNil() {
        let old = TableSelection(
            focusedRow: -1,
            focusedColumn: -1,
            cellSelection: .cells([CellPosition(row: 1, column: 2)]),
            cellSelectionAnchor: CellPosition(row: 1, column: 2)
        )
        let new = TableSelection(
            focusedRow: -1,
            focusedColumn: -1,
            cellSelection: .cells([CellPosition(row: 1, column: 2)]),
            cellSelectionAnchor: CellPosition(row: 5, column: 2)
        )
        #expect(new.reloadIndexes(from: old) == nil)
    }

    @Test("default TableSelection has no anchor")
    func defaultHasNoAnchor() {
        #expect(TableSelection().cellSelectionAnchor == nil)
    }
}
