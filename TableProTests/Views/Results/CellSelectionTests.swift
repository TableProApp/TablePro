import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("GridRect")
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

@Suite("GridSelection")
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

@Suite("GridSelectionController gestures")
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
}
