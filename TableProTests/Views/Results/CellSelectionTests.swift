import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
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

@MainActor
private final class OneRowTableSource: NSObject, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { 1 }
}

struct GridSelectionColumnMarkerTests {
    /// A marker whose block no longer reaches the last row is not a whole column any more. Keeping
    /// it told the heading and the column commands otherwise, while the fill, the copy and the
    /// affected rows stopped short, and nothing could take the stale block back off.
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

struct GridSelectionRowShiftTests {
    private let block = GridSelection.single(
        GridRect(rows: 2...4, columns: 1...1),
        anchor: GridCoord(row: 2, displayColumn: 1),
        active: GridCoord(row: 4, displayColumn: 1)
    )

    @Test("a row inserted inside a block grows it")
    func insertInsideGrows() {
        let result = block.insertingRows(IndexSet(integer: 3), newRowCount: 11)

        #expect(result.rectangles == [GridRect(rows: 2...5, columns: 1...1)])
        #expect(result.anchor == GridCoord(row: 2, displayColumn: 1))
        #expect(result.activeCell == GridCoord(row: 5, displayColumn: 1))
    }

    @Test("rows inserted at or above a block push it down")
    func insertAboveShifts() {
        #expect(block.insertingRows(IndexSet(integer: 2), newRowCount: 11).rectangles == [GridRect(rows: 3...5, columns: 1...1)])
        #expect(block.insertingRows(IndexSet([0, 1]), newRowCount: 12).rectangles == [GridRect(rows: 4...6, columns: 1...1)])
    }

    @Test("a row inserted below a block leaves it alone")
    func insertBelowKeeps() {
        #expect(block.insertingRows(IndexSet(integer: 5), newRowCount: 11) == block)
    }

    @Test("a picked column grows over appended rows and keeps its marker")
    func pickedColumnGrowsOnAppend() {
        let picked = GridSelection.column(1, totalRows: 4)

        let result = picked.insertingRows(IndexSet(integersIn: 4...6), newRowCount: 7)

        #expect(result.rectangles == [GridRect(rows: 0...6, columns: 1...1)])
        #expect(result.columns == IndexSet(integer: 1))
    }

    @Test("a picked column covers a row inserted at the top")
    func pickedColumnCoversInsertAtTop() {
        let picked = GridSelection.column(1, totalRows: 4)

        let result = picked.insertingRows(IndexSet(integer: 0), newRowCount: 5)

        #expect(result.rectangles == [GridRect(rows: 0...4, columns: 1...1)])
        #expect(result.columns == IndexSet(integer: 1))
    }

    @Test("a swept block that reaches every row does not grow over appended rows")
    func sweptBlockDoesNotGrow() {
        let corner = GridCoord(row: 0, displayColumn: 1)
        let swept = GridSelection.single(GridRect(rows: 0...3, columns: 1...1), anchor: corner, active: corner)

        let result = swept.insertingRows(IndexSet(integersIn: 4...5), newRowCount: 6)

        #expect(result.rectangles == [GridRect(rows: 0...3, columns: 1...1)])
        #expect(result.columns.isEmpty)
    }

    @Test("removed rows shift a block up and shrink it")
    func removeShiftsAndShrinks() {
        let selection = GridSelection.single(
            GridRect(rows: 2...6, columns: 0...1),
            anchor: GridCoord(row: 2, displayColumn: 0),
            active: GridCoord(row: 6, displayColumn: 1)
        )

        let result = selection.removingRows(IndexSet([0, 3, 8]), newRowCount: 7)

        #expect(result.rectangles == [GridRect(rows: 1...4, columns: 0...1)])
        #expect(result.anchor == GridCoord(row: 1, displayColumn: 0))
        #expect(result.activeCell == GridCoord(row: 4, displayColumn: 1))
    }

    @Test("a block whose rows are all removed is dropped and the cursor moves to what is left")
    func removeDropsEmptiedRectangle() {
        let selection = GridSelection(
            rectangles: [GridRect(rows: 0...1, columns: 0...0), GridRect(rows: 5...6, columns: 0...0)],
            activeCell: GridCoord(row: 6, displayColumn: 0),
            anchor: GridCoord(row: 5, displayColumn: 0)
        )

        let result = selection.removingRows(IndexSet([5, 6]), newRowCount: 8)

        #expect(result.rectangles == [GridRect(rows: 0...1, columns: 0...0)])
        #expect(result.activeCell == GridCoord(row: 0, displayColumn: 0))
        #expect(result.anchor == GridCoord(row: 0, displayColumn: 0))
    }

    @Test("removing every selected row empties the selection")
    func removeEverythingEmpties() {
        #expect(block.removingRows(IndexSet(integersIn: 2...4), newRowCount: 8) == .empty)
        #expect(block.removingRows(IndexSet(integersIn: 0...10), newRowCount: 0) == .empty)
    }

    @Test("a picked column keeps its marker after a removal")
    func pickedColumnSurvivesRemoval() {
        let picked = GridSelection.column(0, totalRows: 5)

        let result = picked.removingRows(IndexSet(integer: 1), newRowCount: 4)

        #expect(result.rectangles == [GridRect(rows: 0...3, columns: 0...0)])
        #expect(result.columns == IndexSet(integer: 0))
    }
}

@MainActor
struct GridSelectionControllerTests {
    @Test("plain click without drag leaves the selection empty")
    func plainClickWithoutDragHasNoSelection() {
        let controller = GridSelectionController()
        let coord = GridCoord(row: 2, displayColumn: 3)
        _ = controller.beginDrag(at: coord, modifiers: [])
        controller.endDrag(dragged: false, originalCoord: coord)
        #expect(controller.selection.isEmpty)
    }

    @Test("plain click on an existing selection clears it without creating a new rect")
    func plainClickClearsPreviousSelection() {
        let controller = GridSelectionController()
        let first = GridCoord(row: 0, displayColumn: 0)
        let second = GridCoord(row: 3, displayColumn: 4)
        _ = controller.beginDrag(at: first, modifiers: [])
        controller.continueDrag(to: GridCoord(row: 1, displayColumn: 2))
        controller.endDrag(dragged: true, originalCoord: first)
        #expect(!controller.selection.isEmpty)

        _ = controller.beginDrag(at: second, modifiers: [])
        controller.endDrag(dragged: false, originalCoord: second)
        #expect(controller.selection.isEmpty)
    }

    @Test("drag extends to a rectangle anchored at the mousedown coord")
    func dragBuildsRectangle() {
        let controller = GridSelectionController()
        let origin = GridCoord(row: 1, displayColumn: 1)
        let target = GridCoord(row: 4, displayColumn: 3)
        _ = controller.beginDrag(at: origin, modifiers: [])
        controller.continueDrag(to: target)
        controller.endDrag(dragged: true, originalCoord: origin)
        #expect(controller.selection.rectangles == [GridRect(rows: 1...4, columns: 1...3)])
        #expect(controller.selection.anchor == origin)
        #expect(controller.selection.activeCell == target)
    }

    @Test("shift extends the existing selection from the anchor across columns")
    func shiftExtendsAcrossColumns() {
        let controller = GridSelectionController()
        let origin = GridCoord(row: 2, displayColumn: 2)
        let dragTo = GridCoord(row: 2, displayColumn: 2)
        _ = controller.beginDrag(at: origin, modifiers: [])
        controller.continueDrag(to: dragTo)
        controller.endDrag(dragged: true, originalCoord: origin)

        let shiftTarget = GridCoord(row: 5, displayColumn: 6)
        _ = controller.beginDrag(at: shiftTarget, modifiers: .shift)
        #expect(controller.selection.rectangles == [GridRect(rows: 2...5, columns: 2...6)])
        #expect(controller.selection.anchor == origin)
        #expect(controller.selection.activeCell == shiftTarget)
    }

    @Test("cmd+click without drag toggles a single cell")
    func cmdClickTogglesCell() {
        let controller = GridSelectionController()
        let first = GridCoord(row: 0, displayColumn: 0)
        let second = GridCoord(row: 3, displayColumn: 4)

        _ = controller.beginDrag(at: first, modifiers: .command)
        controller.endDrag(dragged: false, originalCoord: first)
        #expect(controller.selection.rectangles == [GridRect(cell: first)])

        _ = controller.beginDrag(at: second, modifiers: .command)
        controller.endDrag(dragged: false, originalCoord: second)
        #expect(controller.selection.rectangles == [GridRect(cell: first), GridRect(cell: second)])

        _ = controller.beginDrag(at: second, modifiers: .command)
        controller.endDrag(dragged: false, originalCoord: second)
        #expect(controller.selection.rectangles == [GridRect(cell: first)])
    }

    @Test("cmd+drag appends a fresh rectangle without clobbering the base selection")
    func cmdDragAppendsRectangle() {
        let controller = GridSelectionController()
        let baseOrigin = GridCoord(row: 0, displayColumn: 0)
        let baseTarget = GridCoord(row: 1, displayColumn: 1)
        _ = controller.beginDrag(at: baseOrigin, modifiers: [])
        controller.continueDrag(to: baseTarget)
        controller.endDrag(dragged: true, originalCoord: baseOrigin)

        let cmdOrigin = GridCoord(row: 5, displayColumn: 5)
        let cmdTarget = GridCoord(row: 7, displayColumn: 7)
        _ = controller.beginDrag(at: cmdOrigin, modifiers: .command)
        controller.continueDrag(to: cmdTarget)
        controller.endDrag(dragged: true, originalCoord: cmdOrigin)

        #expect(controller.selection.rectangles == [
            GridRect(rows: 0...1, columns: 0...1),
            GridRect(rows: 5...7, columns: 5...7)
        ])
        #expect(controller.selection.activeCell == cmdTarget)
    }

    /// A block that happens to reach both ends of the page is not a column selection. Reading the
    /// intent back out of the geometry tinted the heading of any column a drag swept end to end,
    /// and in a one-row result of every column a single cell was clicked in.
    @Test("only a heading click marks a column as picked")
    func onlyHeadingClicksPickColumns() {
        let controller = GridSelectionController()
        let whole = GridCoord(row: 0, displayColumn: 1)

        controller.update(.single(GridRect(rows: 0...3, columns: 1...1), anchor: whole, active: whole))
        #expect(controller.selectedFullColumns().isEmpty)

        controller.selectEntireColumn(1, totalRows: 4)
        #expect(controller.selectedFullColumns() == IndexSet(integer: 1))
    }

    /// A one-row result is the sharpest case: every rectangle in it spans every row, so the old
    /// predicate read one clicked cell as a picked column. The table view is real here because that
    /// predicate consulted `numberOfRows`, and without one the check passes for the wrong reason.
    @Test("a single cell in a one-row result picks no column")
    func singleCellInOneRowResultPicksNoColumn() {
        let controller = GridSelectionController()
        let source = OneRowTableSource()
        let tableView = NSTableView()
        tableView.addTableColumn(NSTableColumn(identifier: .init("c")))
        tableView.dataSource = source
        tableView.reloadData()
        controller.tableView = tableView
        #expect(tableView.numberOfRows == 1)
        let cell = GridCoord(row: 0, displayColumn: 0)

        controller.update(.single(GridRect(cell: cell), anchor: cell, active: cell))

        #expect(controller.selectedFullColumns().isEmpty)
    }

    @Test("Cmd+clicking a picked heading gives the column back")
    func headingCmdClickToggles() {
        let controller = GridSelectionController()
        controller.selectEntireColumn(0, totalRows: 4)

        controller.addEntireColumn(2, totalRows: 4)
        #expect(controller.selectedFullColumns() == IndexSet([0, 2]))

        controller.addEntireColumn(2, totalRows: 4)
        #expect(controller.selectedFullColumns() == IndexSet(integer: 0))
        #expect(controller.selection.rectangles == [GridRect(rows: 0...3, columns: 0...0)])
    }

    /// An additive body gesture rebuilds the selection from the drag's base rectangles, and used to
    /// rebuild it without the picked columns, so a Cmd+click in the body unpainted a heading the
    /// user had picked and took its column out of the column commands.
    @Test("a Cmd+click in the body keeps a picked heading")
    func additiveCellGestureKeepsPickedColumns() {
        let controller = GridSelectionController()
        controller.selectEntireColumn(1, totalRows: 4)

        let elsewhere = GridCoord(row: 2, displayColumn: 3)
        _ = controller.beginDrag(at: elsewhere, modifiers: [.command])
        controller.endDrag(dragged: false, originalCoord: elsewhere)

        #expect(controller.selectedFullColumns() == IndexSet(integer: 1))
        #expect(controller.selection.contains(elsewhere))
    }

    @Test("a Cmd+drag in the body keeps a picked heading")
    func additiveCellDragKeepsPickedColumns() {
        let controller = GridSelectionController()
        controller.selectEntireColumn(1, totalRows: 4)

        let start = GridCoord(row: 1, displayColumn: 3)
        _ = controller.beginDrag(at: start, modifiers: [.command])
        controller.continueDrag(to: GridCoord(row: 3, displayColumn: 4))
        controller.endDrag(dragged: true, originalCoord: start)

        #expect(controller.selectedFullColumns() == IndexSet(integer: 1))
    }

    /// `union` concatenates, so re-adding one heading used to leave a second identical rectangle
    /// behind, and the overlay and the row fill walk every rectangle for every visible row.
    @Test("re-picking a heading never duplicates its rectangle")
    func headingPickNeverDuplicates() {
        let controller = GridSelectionController()
        controller.selectEntireColumn(1, totalRows: 4)

        controller.addEntireColumn(1, totalRows: 4)
        controller.addEntireColumn(1, totalRows: 4)

        #expect(controller.selection.rectangles.count <= 1)
    }

    @Test("selectEntireColumn covers all rows in that column")
    func selectColumnSpansAllRows() {
        let controller = GridSelectionController()
        controller.selectEntireColumn(2, totalRows: 5)
        #expect(controller.selection.rectangles == [GridRect(rows: 0...4, columns: 2...2)])
        #expect(controller.selection.activeCell == GridCoord(row: 0, displayColumn: 2))
        #expect(controller.selection.anchor == GridCoord(row: 0, displayColumn: 2))
    }

    @Test("selectEntireRow covers all columns in that row")
    func selectRowSpansAllColumns() {
        let controller = GridSelectionController()
        controller.selectEntireRow(3, totalColumns: 6)
        #expect(controller.selection.rectangles == [GridRect(rows: 3...3, columns: 0...5)])
        #expect(controller.selection.activeCell == GridCoord(row: 3, displayColumn: 0))
    }

    @Test("extendActiveCell moves the active cell and grows the rectangle from the anchor")
    func extendActiveCellGrowsRectangle() {
        let controller = GridSelectionController()
        let origin = GridCoord(row: 2, displayColumn: 2)
        _ = controller.beginDrag(at: origin, modifiers: [])
        controller.continueDrag(to: GridCoord(row: 3, displayColumn: 3))
        controller.endDrag(dragged: true, originalCoord: origin)

        controller.extendActiveCell(direction: .down, jumpToEdge: false, totalRows: 10, totalColumns: 10)
        #expect(controller.selection.rectangles == [GridRect(rows: 2...4, columns: 2...3)])
        #expect(controller.selection.activeCell == GridCoord(row: 4, displayColumn: 3))
        #expect(controller.selection.anchor == origin)
    }

    @Test("extendActiveCell with jumpToEdge jumps to the grid edge")
    func extendActiveCellJumpsToEdge() {
        let controller = GridSelectionController()
        let origin = GridCoord(row: 2, displayColumn: 2)
        _ = controller.beginDrag(at: origin, modifiers: [])
        controller.continueDrag(to: origin)
        controller.endDrag(dragged: true, originalCoord: origin)

        controller.extendActiveCell(direction: .right, jumpToEdge: true, totalRows: 10, totalColumns: 10)
        #expect(controller.selection.activeCell == GridCoord(row: 2, displayColumn: 9))
        #expect(controller.selection.rectangles == [GridRect(rows: 2...2, columns: 2...9)])
    }

    @Test("extendActiveCell without a seed is a no-op when the selection is empty")
    func extendActiveCellNoOpEmpty() {
        let controller = GridSelectionController()
        controller.extendActiveCell(direction: .down, jumpToEdge: false, totalRows: 10, totalColumns: 10)
        #expect(controller.selection.isEmpty)
    }

    @Test("extendActiveCell with a seed begins a range anchored at the focused cell")
    func extendActiveCellSeedsFromFocusedCell() {
        let controller = GridSelectionController()
        let focused = GridCoord(row: 3, displayColumn: 4)

        controller.extendActiveCell(from: focused, direction: .down, jumpToEdge: false, totalRows: 10, totalColumns: 10)

        #expect(controller.selection.rectangles == [GridRect(rows: 3...4, columns: 4...4)])
        #expect(controller.selection.anchor == focused)
        #expect(controller.selection.activeCell == GridCoord(row: 4, displayColumn: 4))
    }

    @Test("a seeded extend grows by one cell in each direction from the focused cell")
    func extendActiveCellSeedsInEveryDirection() {
        let focused = GridCoord(row: 3, displayColumn: 3)
        let cases: [(GridSelectionController.Direction, GridRect, GridCoord)] = [
            (.up, GridRect(rows: 2...3, columns: 3...3), GridCoord(row: 2, displayColumn: 3)),
            (.down, GridRect(rows: 3...4, columns: 3...3), GridCoord(row: 4, displayColumn: 3)),
            (.left, GridRect(rows: 3...3, columns: 2...3), GridCoord(row: 3, displayColumn: 2)),
            (.right, GridRect(rows: 3...3, columns: 3...4), GridCoord(row: 3, displayColumn: 4))
        ]
        for (direction, expectedRect, expectedActive) in cases {
            let controller = GridSelectionController()
            controller.extendActiveCell(from: focused, direction: direction, jumpToEdge: false, totalRows: 10, totalColumns: 10)
            #expect(controller.selection.rectangles == [expectedRect])
            #expect(controller.selection.anchor == focused)
            #expect(controller.selection.activeCell == expectedActive)
        }
    }

    @Test("repeated seeded extend keeps the anchor fixed and reverses by shrinking")
    func extendActiveCellAnchorStaysFixedOnReverse() {
        let controller = GridSelectionController()
        let focused = GridCoord(row: 2, displayColumn: 2)

        controller.extendActiveCell(from: focused, direction: .down, jumpToEdge: false, totalRows: 10, totalColumns: 10)
        controller.extendActiveCell(direction: .down, jumpToEdge: false, totalRows: 10, totalColumns: 10)
        #expect(controller.selection.rectangles == [GridRect(rows: 2...4, columns: 2...2)])

        controller.extendActiveCell(direction: .up, jumpToEdge: false, totalRows: 10, totalColumns: 10)
        #expect(controller.selection.rectangles == [GridRect(rows: 2...3, columns: 2...2)])
        #expect(controller.selection.anchor == focused)
        #expect(controller.selection.activeCell == GridCoord(row: 3, displayColumn: 2))
    }

    @Test("a seeded extend with jumpToEdge runs from the focused cell to the grid edge")
    func extendActiveCellSeedsToEdge() {
        let controller = GridSelectionController()
        let focused = GridCoord(row: 2, displayColumn: 2)

        controller.extendActiveCell(from: focused, direction: .right, jumpToEdge: true, totalRows: 10, totalColumns: 10)

        #expect(controller.selection.rectangles == [GridRect(rows: 2...2, columns: 2...9)])
        #expect(controller.selection.anchor == focused)
        #expect(controller.selection.activeCell == GridCoord(row: 2, displayColumn: 9))
    }

    @Test("the seed is ignored when a selection already exists")
    func extendActiveCellIgnoresSeedWhenSelectionExists() {
        let controller = GridSelectionController()
        let origin = GridCoord(row: 2, displayColumn: 2)
        _ = controller.beginDrag(at: origin, modifiers: [])
        controller.continueDrag(to: origin)
        controller.endDrag(dragged: true, originalCoord: origin)

        controller.extendActiveCell(from: GridCoord(row: 9, displayColumn: 9), direction: .down, jumpToEdge: false, totalRows: 10, totalColumns: 10)

        #expect(controller.selection.rectangles == [GridRect(rows: 2...3, columns: 2...2)])
        #expect(controller.selection.anchor == origin)
    }

    @Test("clear empties the selection")
    func clearEmpties() {
        let controller = GridSelectionController()
        let coord = GridCoord(row: 0, displayColumn: 0)
        _ = controller.beginDrag(at: coord, modifiers: [])
        controller.endDrag(dragged: false, originalCoord: coord)
        controller.clear()
        #expect(controller.selection.isEmpty)
    }

    /// A plain click leaves no cell selection behind, only a focused cell, so Shift+click used to
    /// select the target alone.
    @Test("Shift+click after a plain click ranges from the clicked cell")
    func shiftClickAfterPlainClickAnchorsAtFocus() {
        let controller = GridSelectionController()
        let first = GridCoord(row: 0, displayColumn: 1)
        let target = GridCoord(row: 4, displayColumn: 1)
        _ = controller.beginDrag(at: first, modifiers: [])
        controller.endDrag(dragged: false, originalCoord: first)
        #expect(controller.selection.isEmpty)

        _ = controller.beginDrag(at: target, modifiers: .shift, focus: first)
        controller.endDrag(dragged: false, originalCoord: target)

        #expect(controller.selection.rectangles == [GridRect(rows: 0...4, columns: 1...1)])
        #expect(controller.selection.anchor == first)
        #expect(controller.selection.activeCell == target)
    }

    @Test("Cmd+click after a plain click keeps the clicked cell")
    func cmdClickAfterPlainClickKeepsFocus() {
        let controller = GridSelectionController()
        let first = GridCoord(row: 0, displayColumn: 0)
        let second = GridCoord(row: 2, displayColumn: 0)
        let third = GridCoord(row: 4, displayColumn: 0)
        _ = controller.beginDrag(at: first, modifiers: [])
        controller.endDrag(dragged: false, originalCoord: first)

        _ = controller.beginDrag(at: second, modifiers: .command, focus: first)
        controller.endDrag(dragged: false, originalCoord: second)
        _ = controller.beginDrag(at: third, modifiers: .command)
        controller.endDrag(dragged: false, originalCoord: third)

        #expect(controller.selection.rectangles == [GridRect(cell: first), GridRect(cell: second), GridRect(cell: third)])
        #expect(controller.selection.uniqueCellCount == 3)
        #expect(controller.selection.activeCell == third)
    }

    @Test("Cmd+drag after a plain click keeps the clicked cell")
    func cmdDragAfterPlainClickKeepsFocus() {
        let controller = GridSelectionController()
        let first = GridCoord(row: 0, displayColumn: 0)
        let start = GridCoord(row: 3, displayColumn: 2)
        _ = controller.beginDrag(at: first, modifiers: [])
        controller.endDrag(dragged: false, originalCoord: first)

        _ = controller.beginDrag(at: start, modifiers: .command, focus: first)
        controller.continueDrag(to: GridCoord(row: 4, displayColumn: 2))
        controller.endDrag(dragged: true, originalCoord: start)

        #expect(controller.selection.rectangles == [GridRect(cell: first), GridRect(rows: 3...4, columns: 2...2)])
    }

    @Test("the focus is ignored once a cell selection exists")
    func focusIgnoredWithSelection() {
        let controller = GridSelectionController()
        let origin = GridCoord(row: 1, displayColumn: 1)
        let stale = GridCoord(row: 9, displayColumn: 9)
        _ = controller.beginDrag(at: origin, modifiers: [])
        controller.continueDrag(to: GridCoord(row: 2, displayColumn: 1))
        controller.endDrag(dragged: true, originalCoord: origin)

        let target = GridCoord(row: 5, displayColumn: 1)
        _ = controller.beginDrag(at: target, modifiers: .shift, focus: stale)
        controller.endDrag(dragged: false, originalCoord: target)
        #expect(controller.selection.rectangles == [GridRect(rows: 1...5, columns: 1...1)])

        let added = GridCoord(row: 7, displayColumn: 3)
        _ = controller.beginDrag(at: added, modifiers: .command, focus: stale)
        controller.endDrag(dragged: false, originalCoord: added)
        #expect(!controller.selection.contains(stale))
        #expect(controller.selection.contains(added))
    }

    @Test("Cmd+click on the only selected cell clears the selection")
    func cmdClickOnOnlyCellClears() {
        let controller = GridSelectionController()
        let cell = GridCoord(row: 3, displayColumn: 2)
        _ = controller.beginDrag(at: cell, modifiers: .command)
        controller.endDrag(dragged: false, originalCoord: cell)
        #expect(controller.selection.rectangles == [GridRect(cell: cell)])

        _ = controller.beginDrag(at: cell, modifiers: .command)
        controller.endDrag(dragged: false, originalCoord: cell)
        #expect(controller.selection.isEmpty)

        _ = controller.beginDrag(at: cell, modifiers: .command, focus: cell)
        controller.endDrag(dragged: false, originalCoord: cell)
        #expect(controller.selection.isEmpty)
    }

    /// The toggle used to remove only a rectangle equal to the clicked cell and otherwise append
    /// one, so the cell stayed selected and was counted twice.
    @Test("Cmd+click inside a dragged block removes only that cell")
    func cmdClickInsideBlockRemovesCell() {
        let controller = GridSelectionController()
        let top = GridCoord(row: 0, displayColumn: 0)
        let bottom = GridCoord(row: 4, displayColumn: 0)
        let middle = GridCoord(row: 2, displayColumn: 0)
        _ = controller.beginDrag(at: top, modifiers: [])
        controller.continueDrag(to: bottom)
        controller.endDrag(dragged: true, originalCoord: top)

        _ = controller.beginDrag(at: middle, modifiers: .command)
        controller.endDrag(dragged: false, originalCoord: middle)

        #expect(!controller.selection.contains(middle))
        #expect(controller.selection.uniqueCellCount == 4)
        for row in [0, 1, 3, 4] {
            #expect(controller.selection.contains(row: row, displayColumn: 0))
        }
        #expect(controller.selection.activeCell == bottom)
    }

    @Test("Cmd+click inside a picked column gives the heading back")
    func cmdClickInsidePickedColumnDropsMarker() {
        let controller = GridSelectionController()
        controller.selectEntireColumn(1, totalRows: 4)
        let cell = GridCoord(row: 2, displayColumn: 1)

        _ = controller.beginDrag(at: cell, modifiers: .command)
        controller.endDrag(dragged: false, originalCoord: cell)

        #expect(controller.selectedFullColumns().isEmpty)
        #expect(!controller.selection.contains(cell))
        #expect(controller.selection.uniqueCellCount == 3)
    }

    @Test("the announcement counts overlapping cells once")
    func announcementCountsUniqueCells() {
        let controller = GridSelectionController()
        let top = GridCoord(row: 0, displayColumn: 0)
        let overlapStart = GridCoord(row: 2, displayColumn: 0)
        _ = controller.beginDrag(at: top, modifiers: [])
        controller.continueDrag(to: GridCoord(row: 4, displayColumn: 0))
        controller.endDrag(dragged: true, originalCoord: top)
        _ = controller.beginDrag(at: overlapStart, modifiers: .command)
        controller.continueDrag(to: GridCoord(row: 6, displayColumn: 0))
        controller.endDrag(dragged: true, originalCoord: overlapStart)

        #expect(controller.selection.rectangles.count == 2)
        #expect(controller.selection.uniqueCellCount == 7)
        let expected = String(
            format: String(localized: "%d cells selected, rows %d to %d, columns %d to %d"),
            7, 1, 7, 1, 1
        )
        #expect(GridSelectionController.accessibilityAnnouncement(for: controller.selection) == expected)
        #expect(GridSelectionController.accessibilityAnnouncement(for: .empty) == String(localized: "Cell selection cleared"))
    }

    @Test("inserted rows go through update and grow a picked column")
    func applyInsertedRowsPublishes() {
        let controller = GridSelectionController()
        controller.selectEntireColumn(1, totalRows: 4)
        var published: [GridSelection] = []
        controller.onSelectionChange = { published.append($0) }

        controller.applyInsertedRows(IndexSet(integersIn: 4...9), newRowCount: 10)

        #expect(controller.selection.rectangles == [GridRect(rows: 0...9, columns: 1...1)])
        #expect(controller.selectedFullColumns() == IndexSet(integer: 1))
        #expect(published == [controller.selection])
    }

    @Test("removed rows go through update and can empty the selection")
    func applyRemovedRowsPublishes() {
        let controller = GridSelectionController()
        let top = GridCoord(row: 2, displayColumn: 0)
        _ = controller.beginDrag(at: top, modifiers: [])
        controller.continueDrag(to: GridCoord(row: 3, displayColumn: 1))
        controller.endDrag(dragged: true, originalCoord: top)
        var published: [GridSelection] = []
        controller.onSelectionChange = { published.append($0) }

        controller.applyRemovedRows(IndexSet(integer: 0), newRowCount: 9)
        #expect(controller.selection.rectangles == [GridRect(rows: 1...2, columns: 0...1)])

        controller.applyRemovedRows(IndexSet(integersIn: 1...2), newRowCount: 7)
        #expect(controller.selection.isEmpty)
        #expect(published.count == 2)
    }
}

@MainActor
private final class PointerSeedLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

@MainActor
private struct PointerSeedGrid {
    let coordinator: TableViewCoordinator
    let tableView: KeyHandlingTableView
    let gutter: DataGridRowGutterView

    init(rowCount: Int = 10) {
        let columns = ["id", "name", "age", "city"]
        let columnTypes = Array(repeating: ColumnType.text(rawType: "TEXT"), count: columns.count)
        let tableRows = TableRows.from(
            queryRows: (0..<rowCount).map { row in columns.map { PluginCellValue.text("\($0)-\(row)") } },
            columns: columns,
            columnTypes: columnTypes
        )
        coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: PointerSeedLayoutPersister()
        )
        coordinator.tableRowsProvider = { tableRows }

        tableView = KeyHandlingTableView()
        tableView.coordinator = coordinator
        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())
        coordinator.tableView = tableView
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: coordinator.identitySchema,
            columnTypes: columnTypes,
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            firstClickSortDirection: .ascending,
            widthCalculator: { _, _ in 100 }
        )
        coordinator.updateCache()
        tableView.reloadData()

        gutter = DataGridRowGutterView(frame: .zero)
        gutter.coordinator = coordinator
    }

    /// A gutter click as the grid sees it: the row selection, then the cursor the selection change
    /// seeds. Delivered by hand as well, so the seed does not depend on how the notification arrives.
    func clickGutter(row: Int) {
        gutter.selectRows(clickedRow: row, modifiers: [])
        coordinator.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: tableView)
        )
    }

    func press(_ key: KeyCode, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: key.rawValue
        ))
        tableView.keyDown(with: event)
    }
}

@MainActor
struct GridPointerSeedTests {
    /// The gutter clears the cursor, and the selection change it makes seeds one again on the first
    /// column. Seeding a click from that cursor made it a selected cell the user never picked.
    @Test("Cmd+click after a gutter row selection selects only the clicked cell")
    func cmdClickAfterGutterSelectsOnlyClickedCell() {
        let grid = PointerSeedGrid()
        grid.clickGutter(row: 6)
        #expect(grid.tableView.focusedRow == 6)
        #expect(grid.tableView.presentsDataColumn(at: grid.tableView.focusedColumn))

        #expect(grid.tableView.pointerSelectionSeed() == nil)

        let controller = grid.coordinator.selectionController
        let target = GridCoord(row: 8, displayColumn: 3)
        _ = controller.beginDrag(at: target, modifiers: .command, focus: grid.tableView.pointerSelectionSeed())
        controller.endDrag(dragged: false, originalCoord: target)
        #expect(controller.selection.rectangles == [GridRect(cell: target)])
    }

    @Test("Shift+click after a gutter row selection does not range from the seeded cursor")
    func shiftClickAfterGutterIgnoresSeededCursor() {
        let grid = PointerSeedGrid()
        grid.clickGutter(row: 6)

        let controller = grid.coordinator.selectionController
        let target = GridCoord(row: 8, displayColumn: 3)
        _ = controller.beginDrag(at: target, modifiers: .shift, focus: grid.tableView.pointerSelectionSeed())
        controller.endDrag(dragged: false, originalCoord: target)
        #expect(controller.selection.rectangles == [GridRect(cell: target)])
    }

    @Test("Shift+Arrow after a gutter row selection still starts a range at the cursor")
    func shiftArrowAfterGutterStillExtends() throws {
        let grid = PointerSeedGrid()
        grid.clickGutter(row: 6)

        try grid.press(.downArrow, modifiers: .shift)

        #expect(grid.coordinator.selectionController.selection.rectangles == [GridRect(rows: 6...7, columns: 0...0)])
    }

    @Test("moving the cursor with an arrow key after a gutter row selection makes it the user's")
    func arrowAfterGutterMakesCursorSeedable() throws {
        let grid = PointerSeedGrid()
        grid.clickGutter(row: 6)

        try grid.press(.rightArrow)

        #expect(grid.tableView.pointerSelectionSeed() == GridCoord(row: 6, displayColumn: 1))
    }

    @Test("a cursor moved by Tab seeds a click")
    func keyboardCursorSeeds() throws {
        let grid = PointerSeedGrid()
        let column = try #require(grid.coordinator.tableColumnIndex(for: 2))

        grid.tableView.focusCell(row: 3, column: column)

        #expect(grid.tableView.pointerSelectionSeed() == GridCoord(row: 3, displayColumn: 2))
    }

    @Test("Select All leaves no cursor to seed a click from")
    func selectAllLeavesNoSeed() {
        let grid = PointerSeedGrid()
        grid.tableView.focusCell(row: 3, column: grid.coordinator.tableColumnIndex(for: 1) ?? -1)

        grid.tableView.selectAll(nil)

        #expect(grid.tableView.pointerSelectionSeed() == nil)
    }
}
