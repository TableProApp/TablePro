import Foundation
@testable import TablePro
import Testing

@Suite("GridRect")
struct GridRectTests {
    @Test("rect from two coords spans the bounding box regardless of order")
    func betweenCoordsHandlesOrder() {
        let a = GridCoord(row: 5, column: 2)
        let b = GridCoord(row: 1, column: 7)
        let rect = GridRect.between(a, b)
        #expect(rect.rows == 1...5)
        #expect(rect.columns == 2...7)
    }

    @Test("contains is inclusive on both bounds")
    func containsInclusiveBounds() {
        let rect = GridRect(rows: 2...4, columns: 1...3)
        #expect(rect.contains(GridCoord(row: 2, column: 1)))
        #expect(rect.contains(GridCoord(row: 4, column: 3)))
        #expect(!rect.contains(GridCoord(row: 1, column: 2)))
        #expect(!rect.contains(GridCoord(row: 5, column: 2)))
        #expect(!rect.contains(GridCoord(row: 3, column: 4)))
    }

    @Test("clamped returns nil when rect lies entirely outside the limits")
    func clampedOutsideReturnsNil() {
        let rect = GridRect(rows: 10...20, columns: 5...8)
        #expect(rect.clamped(rowLimit: 5, columnLimit: 10) == nil)
    }

    @Test("clamped reduces a partially outside rect to the visible window")
    func clampedPartialOverlap() {
        let rect = GridRect(rows: 3...12, columns: -2...4)
        let clamped = rect.clamped(rowLimit: 8, columnLimit: 6)
        #expect(clamped?.rows == 3...7)
        #expect(clamped?.columns == 0...4)
    }
}

@Suite("GridSelection")
struct GridSelectionTests {
    private let rect = GridRect(rows: 0...2, columns: 0...1)
    private let active = GridCoord(row: 0, column: 0)

    @Test("empty selection contains nothing and has no bounding rect")
    func emptySelection() {
        let selection = GridSelection.empty
        #expect(selection.isEmpty)
        #expect(!selection.contains(GridCoord(row: 0, column: 0)))
        #expect(selection.boundingRectangle == nil)
        #expect(selection.affectedRows.isEmpty)
        #expect(selection.affectedColumns.isEmpty)
    }

    @Test("single rect selection reports its bounding box")
    func singleRectSelection() {
        let selection = GridSelection.single(rect, anchor: active, active: active)
        #expect(!selection.isEmpty)
        #expect(selection.contains(row: 1, column: 1))
        #expect(!selection.contains(row: 3, column: 0))
        #expect(selection.boundingRectangle == rect)
    }

    @Test("multiple rectangles report union of affected rows and columns")
    func multipleRectanglesUnion() {
        let selection = GridSelection(
            rectangles: [
                GridRect(rows: 0...0, columns: 0...0),
                GridRect(rows: 5...6, columns: 3...4)
            ],
            activeCell: GridCoord(row: 5, column: 3),
            anchor: GridCoord(row: 5, column: 3)
        )
        #expect(selection.affectedRows == IndexSet([0, 5, 6]))
        #expect(selection.affectedColumns == IndexSet([0, 3, 4]))
    }

    @Test("bounding rectangle wraps disjoint rectangles")
    func boundingRectangleSpansDisjointRects() {
        let selection = GridSelection(
            rectangles: [
                GridRect(rows: 1...1, columns: 0...0),
                GridRect(rows: 7...8, columns: 5...6)
            ],
            activeCell: nil,
            anchor: nil
        )
        #expect(selection.boundingRectangle == GridRect(rows: 1...8, columns: 0...6))
    }

    @Test("columns(in:) reports only rects that include the row")
    func columnsInRowFiltersByRow() {
        let selection = GridSelection(
            rectangles: [
                GridRect(rows: 0...2, columns: 1...2),
                GridRect(rows: 5...6, columns: 4...4)
            ],
            activeCell: nil,
            anchor: nil
        )
        #expect(selection.columns(in: 1) == IndexSet([1, 2]))
        #expect(selection.columns(in: 6) == IndexSet(integer: 4))
        #expect(selection.columns(in: 3).isEmpty)
    }

    @Test("contains is true if any rectangle includes the coord")
    func containsAnyRectangle() {
        let selection = GridSelection(
            rectangles: [
                GridRect(rows: 0...0, columns: 0...0),
                GridRect(rows: 5...6, columns: 3...4)
            ],
            activeCell: nil,
            anchor: nil
        )
        #expect(selection.contains(row: 0, column: 0))
        #expect(selection.contains(row: 6, column: 4))
        #expect(!selection.contains(row: 2, column: 2))
    }

    @Test("union merges rectangles, taking the new active and anchor when present")
    func unionPrefersOtherActiveAndAnchor() {
        let lhs = GridSelection.single(GridRect(rows: 0...0, columns: 0...0), anchor: active, active: active)
        let other = GridCoord(row: 4, column: 4)
        let rhs = GridSelection.single(GridRect(rows: 4...4, columns: 4...4), anchor: other, active: other)
        let merged = lhs.union(rhs)
        #expect(merged.rectangles.count == 2)
        #expect(merged.activeCell == other)
        #expect(merged.anchor == other)
    }
}
