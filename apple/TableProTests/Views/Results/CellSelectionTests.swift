import Foundation
@testable import TablePro
import Testing

struct GridRectTests {
    @Test("rect from two coords spans the bounding box regardless of order")
    func betweenCoordsHandlesOrder() {
        let a = GridCoord(row: 5, displayColumn: 2)
        let b = GridCoord(row: 1, displayColumn: 7)
        let rect = GridRect.between(a, b)
        #expect(rect.rows == 1...5)
        #expect(rect.columns == 2...7)
    }

    @Test("contains is inclusive on both bounds")
    func containsInclusiveBounds() {
        let rect = GridRect(rows: 2...4, columns: 1...3)
        #expect(rect.contains(GridCoord(row: 2, displayColumn: 1)))
        #expect(rect.contains(GridCoord(row: 4, displayColumn: 3)))
        #expect(!rect.contains(GridCoord(row: 1, displayColumn: 2)))
        #expect(!rect.contains(GridCoord(row: 5, displayColumn: 2)))
        #expect(!rect.contains(GridCoord(row: 3, displayColumn: 4)))
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

struct GridSelectionTests {
    private let rect = GridRect(rows: 0...2, columns: 0...1)
    private let active = GridCoord(row: 0, displayColumn: 0)

    @Test("empty selection contains nothing and has no bounding rect")
    func emptySelection() {
        let selection = GridSelection.empty
        #expect(selection.isEmpty)
        #expect(!selection.contains(GridCoord(row: 0, displayColumn: 0)))
        #expect(selection.boundingRectangle == nil)
        #expect(selection.affectedRows.isEmpty)
        #expect(selection.affectedColumns.isEmpty)
    }

    @Test("single rect selection reports its bounding box")
    func singleRectSelection() {
        let selection = GridSelection.single(rect, anchor: active, active: active)
        #expect(!selection.isEmpty)
        #expect(selection.contains(row: 1, displayColumn: 1))
        #expect(!selection.contains(row: 3, displayColumn: 0))
        #expect(selection.boundingRectangle == rect)
    }

    @Test("a cell-range spanning rows reports every covered row")
    func cellRangeAffectsEveryCoveredRow() {
        let selection = GridSelection.single(
            GridRect(rows: 2...5, columns: 1...3),
            anchor: GridCoord(row: 2, displayColumn: 1),
            active: GridCoord(row: 5, displayColumn: 3)
        )
        #expect(selection.affectedRows == IndexSet(integersIn: 2...5))
    }

    @Test("multiple rectangles report union of affected rows and columns")
    func multipleRectanglesUnion() {
        let selection = GridSelection(
            rectangles: [
                GridRect(rows: 0...0, columns: 0...0),
                GridRect(rows: 5...6, columns: 3...4)
            ],
            activeCell: GridCoord(row: 5, displayColumn: 3),
            anchor: GridCoord(row: 5, displayColumn: 3)
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
        #expect(selection.contains(row: 0, displayColumn: 0))
        #expect(selection.contains(row: 6, displayColumn: 4))
        #expect(!selection.contains(row: 2, displayColumn: 2))
    }

    @Test("union merges rectangles, taking the new active and anchor when present")
    func unionPrefersOtherActiveAndAnchor() {
        let lhs = GridSelection.single(GridRect(rows: 0...0, columns: 0...0), anchor: active, active: active)
        let other = GridCoord(row: 4, displayColumn: 4)
        let rhs = GridSelection.single(GridRect(rows: 4...4, columns: 4...4), anchor: other, active: other)
        let merged = lhs.union(rhs)
        #expect(merged.rectangles.count == 2)
        #expect(merged.activeCell == other)
        #expect(merged.anchor == other)
    }
}

struct GridSelectionColumnMarkerTests {
    @Test("a marker is dropped when the result gained rows")
    func markerDroppedWhenResultGrew() {
        let picked = GridSelection.column(1, totalRows: 4)

        let restored = picked.clamped(rowLimit: 10, columnLimit: 6)

        #expect(restored.columns.isEmpty)
        #expect(restored.rectangles == [GridRect(rows: 0...3, columns: 1...1)])
    }

    @Test("a marker survives a result of the same height")
    func markerSurvivesSameHeight() {
        let picked = GridSelection.column(1, totalRows: 4)

        #expect(picked.clamped(rowLimit: 4, columnLimit: 6).columns == IndexSet(integer: 1))
    }

    @Test("a marker is dropped when its column no longer exists")
    func markerDroppedWhenColumnGone() {
        let picked = GridSelection.column(5, totalRows: 4)

        #expect(picked.clamped(rowLimit: 4, columnLimit: 3).columns.isEmpty)
    }

    @Test("union merges the markers of both sides")
    func unionMergesMarkers() {
        let merged = GridSelection.column(0, totalRows: 4).union(.column(2, totalRows: 4))

        #expect(merged.columns == IndexSet([0, 2]))
    }
}

struct GridSelectionCellCountTests {
    private func bruteForceCount(_ selection: GridSelection) -> Int {
        var cells = Set<GridCoord>()
        for rect in selection.rectangles {
            for row in rect.rows {
                for column in rect.columns {
                    cells.insert(GridCoord(row: row, displayColumn: column))
                }
            }
        }
        return cells.count
    }

    @Test("three overlapping rectangles count each cell once")
    func overlappingRectanglesCountOnce() {
        let selection = GridSelection(
            rectangles: [
                GridRect(rows: 0...4, columns: 0...2),
                GridRect(rows: 2...6, columns: 1...3),
                GridRect(rows: 3...3, columns: 0...5)
            ],
            activeCell: nil,
            anchor: nil
        )

        #expect(selection.uniqueCellCount == 26)
        #expect(selection.uniqueCellCount == bruteForceCount(selection))
    }

    @Test("disjoint and identical rectangles count like the cells they cover")
    func disjointAndIdenticalRectangles() {
        let selection = GridSelection(
            rectangles: [
                GridRect(rows: 0...1, columns: 0...1),
                GridRect(rows: 0...1, columns: 0...1),
                GridRect(rows: 5...5, columns: 3...3),
                GridRect(rows: 9...10, columns: 2...4)
            ],
            activeCell: nil,
            anchor: nil
        )

        #expect(selection.uniqueCellCount == 11)
        #expect(selection.uniqueCellCount == bruteForceCount(selection))
        #expect(GridSelection.empty.uniqueCellCount == 0)
    }

    @Test("picked columns over a million rows count without a walk per row")
    func wholeColumnsCountByBand() {
        let rows = 1_000_000
        var selection = GridSelection.column(3, totalRows: rows).union(.column(4, totalRows: rows))
        selection.rectangles.append(GridRect(rows: 10...500_000, columns: 3...5))

        #expect(selection.uniqueCellCount == 2 * rows + 499_991)
    }

    @Test("hasMultipleCells is false for one cell however many times it is listed")
    func hasMultipleCellsIgnoresDuplicates() {
        let cell = GridRect(rows: 2...2, columns: 1...1)
        #expect(!GridSelection.empty.hasMultipleCells)
        #expect(!GridSelection(rectangles: [cell], activeCell: nil, anchor: nil).hasMultipleCells)
        #expect(!GridSelection(rectangles: [cell, cell], activeCell: nil, anchor: nil).hasMultipleCells)
        #expect(GridSelection(rectangles: [cell, GridRect(rows: 3...3, columns: 1...1)], activeCell: nil, anchor: nil).hasMultipleCells)
        #expect(GridSelection(rectangles: [GridRect(rows: 2...2, columns: 1...2)], activeCell: nil, anchor: nil).hasMultipleCells)
    }

    @Test("removing a cell from the middle of a block leaves the cells around it")
    func removingCellSplitsBlock() {
        let center = GridCoord(row: 1, displayColumn: 1)
        let block = GridSelection.single(
            GridRect(rows: 0...2, columns: 0...2),
            anchor: GridCoord(row: 0, displayColumn: 0),
            active: GridCoord(row: 2, displayColumn: 2)
        )

        let result = block.removing(cell: center)

        #expect(!result.contains(center))
        #expect(result.uniqueCellCount == 8)
        #expect(result.uniqueCellCount == bruteForceCount(result))
        #expect(result.anchor == GridCoord(row: 0, displayColumn: 0))
        #expect(result.activeCell == GridCoord(row: 2, displayColumn: 2))
    }

    @Test("removing a cell from every rectangle that covers it")
    func removingCellFromOverlappingRectangles() {
        let cell = GridCoord(row: 3, displayColumn: 0)
        let selection = GridSelection(
            rectangles: [GridRect(rows: 0...4, columns: 0...0), GridRect(rows: 2...6, columns: 0...0)],
            activeCell: cell,
            anchor: GridCoord(row: 0, displayColumn: 0)
        )

        let result = selection.removing(cell: cell)

        #expect(!result.contains(cell))
        #expect(result.uniqueCellCount == 6)
        if let active = result.activeCell {
            #expect(result.contains(active))
        } else {
            Issue.record("the active cell was dropped")
        }
    }

    @Test("removing a cell of a picked column drops its marker")
    func removingCellBreaksPickedColumn() {
        let picked = GridSelection.column(1, totalRows: 4).union(.column(3, totalRows: 4))

        let result = picked.removing(cell: GridCoord(row: 2, displayColumn: 1))

        #expect(result.columns == IndexSet(integer: 3))
        #expect(result.uniqueCellCount == 7)
    }

    @Test("removing the only cell empties the selection")
    func removingOnlyCellEmpties() {
        let cell = GridCoord(row: 4, displayColumn: 2)
        let selection = GridSelection.single(GridRect(cell: cell), anchor: cell, active: cell)

        #expect(selection.removing(cell: cell) == .empty)
        #expect(selection.removing(cell: GridCoord(row: 0, displayColumn: 0)) == selection)
    }
}
