import Foundation
@testable import TablePro
import Testing

struct GridSelectionReducerTests {
    private let grid = GridSelectionContext(rowCount: 10, columnCount: 6)

    private func cell(_ row: Int, _ column: Int) -> GridCoord {
        GridCoord(row: row, displayColumn: column)
    }

    private func single(_ row: Int, _ column: Int) -> GridSelection {
        GridSelectionReducer.single(cell(row, column))
    }

    private func cursorAt(_ row: Int, _ column: Int) -> GridSelection {
        GridSelectionReducer.cursor(cell(row, column), in: grid)
    }

    private func range(_ anchor: GridCoord, _ active: GridCoord) -> GridSelection {
        GridSelection(rectangles: [GridRect.between(anchor, active)], activeCell: active, anchor: anchor)
    }

    private func wholeRows(_ rows: ClosedRange<Int>) -> GridRect {
        GridRect(rows: rows, columns: 0...5)
    }

    // MARK: - Press and drag

    @Test("A plain press selects the cell's row with the cursor on the cell and starts a replacing drag")
    func plainPressSelectsCell() {
        let (selection, drag) = GridSelectionReducer.press(.empty, at: cell(2, 3), modifiers: [], in: grid)

        #expect(selection == cursorAt(2, 3))
        #expect(selection.rectangles == [wholeRows(2...2)])
        #expect(!selection.picksRows)
        #expect(drag == GridSelectionDrag(origin: cell(2, 3), base: .empty, mode: .replace))
    }

    @Test("A plain press replaces a range")
    func plainPressReplacesRange() {
        let (selection, _) = GridSelectionReducer.press(range(cell(1, 1), cell(4, 4)), at: cell(6, 2), modifiers: [], in: grid)

        #expect(selection == cursorAt(6, 2))
    }

    @Test("A drag builds a rectangle anchored where the press landed")
    func dragBuildsRectangle() {
        let (_, drag) = GridSelectionReducer.press(.empty, at: cell(2, 3), modifiers: [], in: grid)

        let dragged = GridSelectionReducer.drag(drag, to: cell(4, 1), in: grid)

        #expect(dragged.rectangles == [GridRect(rows: 2...4, columns: 1...3)])
        #expect(dragged.activeCell == cell(4, 1))
        #expect(dragged.anchor == cell(2, 3))
        #expect(GridSelectionReducer.drag(drag, to: cell(2, 3), in: grid) == cursorAt(2, 3))
    }

    @Test("A drag past either edge holds at that edge")
    func dragClampsToGrid() {
        let (_, drag) = GridSelectionReducer.press(.empty, at: cell(2, 3), modifiers: [], in: grid)

        let dragged = GridSelectionReducer.drag(drag, to: cell(50, 40), in: grid)

        #expect(dragged.rectangles == [GridRect(rows: 2...9, columns: 3...5)])
        #expect(dragged.activeCell == cell(9, 5))
    }

    @Test("Shift-press ranges from the anchor and the drag keeps that anchor")
    func shiftPressExtendsFromAnchor() {
        let (selection, drag) = GridSelectionReducer.press(single(1, 1), at: cell(3, 4), modifiers: .shift, in: grid)

        #expect(selection == range(cell(1, 1), cell(3, 4)))
        #expect(drag == GridSelectionDrag(origin: cell(1, 1), base: .empty, mode: .replace))
        #expect(GridSelectionReducer.drag(drag, to: cell(0, 0), in: grid) == range(cell(1, 1), cell(0, 0)))
    }

    @Test("Shift-press without an anchor ranges from the active cell")
    func shiftPressFallsBackToActiveCell() {
        let start = GridSelection(rectangles: [GridRect(cell: cell(2, 2))], activeCell: cell(2, 2), anchor: nil)

        let (selection, _) = GridSelectionReducer.press(start, at: cell(4, 0), modifiers: .shift, in: grid)

        #expect(selection == range(cell(2, 2), cell(4, 0)))
    }

    @Test("Shift-press on an empty selection puts the cursor on the cell")
    func shiftPressOnEmptySelectsCell() {
        let (selection, _) = GridSelectionReducer.press(.empty, at: cell(5, 5), modifiers: .shift, in: grid)

        #expect(selection == cursorAt(5, 5))
    }

    @Test("Command-press adds a cell and starts an additive drag over the old selection")
    func commandPressAddsCell() {
        let start = single(1, 1)

        let (selection, drag) = GridSelectionReducer.press(start, at: cell(3, 3), modifiers: .command, in: grid)

        #expect(selection.rectangles == [GridRect(cell: cell(1, 1)), GridRect(cell: cell(3, 3))])
        #expect(selection.activeCell == cell(3, 3))
        #expect(selection.anchor == cell(3, 3))
        #expect(drag == GridSelectionDrag(origin: cell(3, 3), base: start, mode: .additive))
    }

    @Test("Command-press on the only selected cell clears the selection")
    func commandPressOnOnlyCellClears() {
        let (selection, _) = GridSelectionReducer.press(single(1, 1), at: cell(1, 1), modifiers: .command, in: grid)

        #expect(selection == .empty)
    }

    @Test("Command-press inside a block takes out only that cell")
    func commandPressInsideBlockRemovesCell() {
        let block = range(cell(0, 0), cell(2, 2))

        let (selection, _) = GridSelectionReducer.press(block, at: cell(1, 1), modifiers: .command, in: grid)

        #expect(selection.uniqueCellCount == 8)
        #expect(!selection.contains(cell(1, 1)))
        #expect(selection.contains(cell(0, 0)))
        #expect(selection.contains(cell(2, 2)))
    }

    @Test("A Command-drag appends a rectangle and keeps the earlier selection")
    func commandDragAppendsRectangle() {
        let (_, drag) = GridSelectionReducer.press(single(0, 0), at: cell(2, 2), modifiers: .command, in: grid)

        let dragged = GridSelectionReducer.drag(drag, to: cell(3, 4), in: grid)

        #expect(dragged.rectangles == [GridRect(cell: cell(0, 0)), GridRect(rows: 2...3, columns: 2...4)])
        #expect(dragged.activeCell == cell(3, 4))
        #expect(dragged.anchor == cell(2, 2))
    }

    @Test("A Command-drag back onto its origin is the press's toggle again")
    func commandDragBackToOriginToggles() {
        let (pressed, drag) = GridSelectionReducer.press(single(1, 1), at: cell(1, 1), modifiers: .command, in: grid)
        #expect(pressed == .empty)

        let away = GridSelectionReducer.drag(drag, to: cell(2, 2), in: grid)
        #expect(away.contains(cell(1, 1)))
        #expect(away.contains(cell(2, 2)))

        #expect(GridSelectionReducer.drag(drag, to: cell(1, 1), in: grid) == .empty)
    }

    @Test("A Command-press or Command-drag in the body keeps a picked column")
    func commandGesturesKeepPickedColumn() {
        let picked = GridSelection.column(2, totalRows: 10)

        let (pressed, drag) = GridSelectionReducer.press(picked, at: cell(5, 4), modifiers: .command, in: grid)
        let dragged = GridSelectionReducer.drag(drag, to: cell(6, 5), in: grid)

        #expect(pressed.columns == IndexSet(integer: 2))
        #expect(dragged.columns == IndexSet(integer: 2))
        #expect(dragged.contains(cell(9, 2)))
    }

    @Test("Only a header click marks a column, not a drag that spans every row")
    func onlyHeaderMarksColumns() {
        let (_, drag) = GridSelectionReducer.press(.empty, at: cell(0, 2), modifiers: [], in: grid)

        let dragged = GridSelectionReducer.drag(drag, to: cell(9, 2), in: grid)

        #expect(dragged.columns.isEmpty)
    }

    @Test("Shift and Command together press like a plain click")
    func shiftCommandPressIsPlain() {
        let (selection, drag) = GridSelectionReducer.press(single(1, 1), at: cell(3, 3), modifiers: [.shift, .command], in: grid)

        #expect(selection == cursorAt(3, 3))
        #expect(drag.mode == .replace)
    }

    @Test("A press past the edges lands on the nearest cell")
    func pressClampsToGrid() {
        let (selection, _) = GridSelectionReducer.press(.empty, at: cell(20, -3), modifiers: [], in: grid)

        #expect(selection == cursorAt(9, 0))
    }

    @Test("A press on a grid with no rows selects nothing")
    func pressOnEmptyGrid() {
        let empty = GridSelectionContext(rowCount: 0, columnCount: 6)

        let (selection, drag) = GridSelectionReducer.press(single(1, 1), at: cell(0, 0), modifiers: [], in: empty)

        #expect(selection == .empty)
        #expect(GridSelectionReducer.drag(drag, to: cell(1, 1), in: empty) == .empty)
    }

    // MARK: - Row header

    @Test("A row header press selects the whole row and starts a rows drag")
    func rowHeaderSelectsRow() {
        let (selection, drag) = GridSelectionReducer.rowHeaderPress(.empty, row: 4, modifiers: [], in: grid)

        #expect(selection.rectangles == [wholeRows(4...4)])
        #expect(selection.activeCell == cell(4, 0))
        #expect(selection.anchor == cell(4, 0))
        #expect(drag == GridSelectionDrag(origin: cell(4, 0), base: .empty, mode: .rows))
    }

    @Test("A row header press keeps the column the cursor was on")
    func rowHeaderKeepsActiveColumn() {
        let (selection, _) = GridSelectionReducer.rowHeaderPress(single(2, 3), row: 6, modifiers: [], in: grid)

        #expect(selection.rectangles == [wholeRows(6...6)])
        #expect(selection.activeCell == cell(6, 3))
    }

    @Test("Shift on a row header extends whole rows from the anchor")
    func rowHeaderShiftExtends() {
        let (start, _) = GridSelectionReducer.rowHeaderPress(.empty, row: 2, modifiers: [], in: grid)

        let (selection, drag) = GridSelectionReducer.rowHeaderPress(start, row: 5, modifiers: .shift, in: grid)

        #expect(selection.rectangles == [wholeRows(2...5)])
        #expect(selection.anchor == cell(2, 0))
        #expect(selection.activeCell == cell(5, 0))
        #expect(drag.origin == cell(2, 0))
    }

    @Test("Command on a row header adds a row, and again takes it back")
    func rowHeaderCommandToggles() {
        let (start, _) = GridSelectionReducer.rowHeaderPress(.empty, row: 2, modifiers: [], in: grid)

        let (added, _) = GridSelectionReducer.rowHeaderPress(start, row: 5, modifiers: .command, in: grid)
        #expect(added.rectangles == [wholeRows(2...2), wholeRows(5...5)])
        #expect(added.activeCell == cell(5, 0))

        let (removed, _) = GridSelectionReducer.rowHeaderPress(added, row: 5, modifiers: .command, in: grid)
        #expect(removed.rectangles == [wholeRows(2...2)])
        #expect(removed.activeCell == cell(2, 0))
    }

    @Test("Command on a row inside a run of rows splits the run")
    func rowHeaderCommandSplitsRun() {
        let run = GridSelection(rectangles: [wholeRows(2...6)], activeCell: cell(2, 0), anchor: cell(2, 0))

        let (selection, _) = GridSelectionReducer.rowHeaderPress(run, row: 4, modifiers: .command, in: grid)

        #expect(selection.rectangles == [wholeRows(2...3), wholeRows(5...6)])
        #expect(selection.activeCell == cell(2, 0))
    }

    @Test("A rows drag extends whole rows from the pressed row in either direction")
    func rowsDragExtends() {
        let (_, drag) = GridSelectionReducer.rowHeaderPress(.empty, row: 3, modifiers: [], in: grid)

        let down = GridSelectionReducer.drag(drag, to: cell(7, 2), in: grid)
        #expect(down.rectangles == [wholeRows(3...7)])
        #expect(down.activeCell == cell(7, 0))
        #expect(down.anchor == cell(3, 0))

        let up = GridSelectionReducer.drag(drag, to: cell(1, 5), in: grid)
        #expect(up.rectangles == [wholeRows(1...3)])
        #expect(up.activeCell == cell(1, 0))
    }

    @Test("A Command rows drag adds to what was selected")
    func commandRowsDragAdds() {
        let (start, _) = GridSelectionReducer.rowHeaderPress(.empty, row: 0, modifiers: [], in: grid)
        let (_, drag) = GridSelectionReducer.rowHeaderPress(start, row: 4, modifiers: .command, in: grid)

        let dragged = GridSelectionReducer.drag(drag, to: cell(6, 0), in: grid)

        #expect(dragged.rectangles == [wholeRows(0...0), wholeRows(4...6)])
    }

    @Test("A row number press that may lift rows picks a clicked row, so it copies as a row")
    func rowNumberDragPressPicksAClickedRow() {
        let picked = GridSelectionReducer.rowNumberDragPress(cursorAt(2, 3), row: 2, keepsPickedRows: true, in: grid)

        #expect(picked.picksRows)
        #expect(picked.rectangles == [wholeRows(2...2)])
        #expect(picked.activeCell == cell(2, 3))
    }

    @Test("A row number press inside picked rows keeps them all for the drag")
    func rowNumberDragPressKeepsPickedRows() {
        let (start, _) = GridSelectionReducer.rowHeaderPress(.empty, row: 1, modifiers: [], in: grid)
        let (rows, _) = GridSelectionReducer.rowHeaderPress(start, row: 3, modifiers: .shift, in: grid)

        #expect(GridSelectionReducer.rowNumberDragPress(rows, row: 2, keepsPickedRows: true, in: grid) == rows)
    }

    @Test("Where a drag reorders one row, a row number press picks the pressed row alone")
    func rowNumberDragPressForReorderPicksThePressedRow() {
        let (start, _) = GridSelectionReducer.rowHeaderPress(.empty, row: 1, modifiers: [], in: grid)
        let (rows, _) = GridSelectionReducer.rowHeaderPress(start, row: 3, modifiers: .shift, in: grid)

        let pressed = GridSelectionReducer.rowNumberDragPress(rows, row: 3, keepsPickedRows: false, in: grid)

        #expect(pressed.picksRows)
        #expect(pressed.rectangles == [wholeRows(3...3)])
        #expect(pressed.affectedRows == IndexSet(integer: 3))
    }

    // MARK: - Column header

    @Test("Command on a header picks the whole column and marks it")
    func headerPicksColumn() {
        let selection = GridSelectionReducer.columnHeaderCommandClick(.empty, column: 2, modifiers: .command, in: grid)

        #expect(selection.rectangles == [GridRect(rows: 0...9, columns: 2...2)])
        #expect(selection.columns == IndexSet(integer: 2))
        #expect(selection.activeCell == cell(0, 2))
    }

    @Test("Command on a picked header gives the column back")
    func headerTogglesColumn() {
        let picked = GridSelectionReducer.columnHeaderCommandClick(.empty, column: 2, modifiers: .command, in: grid)

        #expect(GridSelectionReducer.columnHeaderCommandClick(picked, column: 2, modifiers: .command, in: grid) == .empty)
    }

    @Test("Command on a header keeps the rest of the selection, and giving it back leaves the rest")
    func headerKeepsOtherCells() {
        let picked = GridSelectionReducer.columnHeaderCommandClick(single(3, 0), column: 4, modifiers: .command, in: grid)
        #expect(picked.contains(cell(3, 0)))
        #expect(picked.columns == IndexSet(integer: 4))

        let released = GridSelectionReducer.columnHeaderCommandClick(picked, column: 4, modifiers: .command, in: grid)
        #expect(released.rectangles == [GridRect(cell: cell(3, 0))])
        #expect(released.columns.isEmpty)
        #expect(released.activeCell == cell(3, 0))
    }

    @Test("Picking a header again never stacks a duplicate rectangle")
    func headerNeverDuplicates() {
        var selection = GridSelection.empty
        for column in [2, 3, 2, 2] {
            selection = GridSelectionReducer.columnHeaderCommandClick(selection, column: column, modifiers: .command, in: grid)
        }

        #expect(selection.rectangles.count == 2)
        #expect(selection.columns == IndexSet([2, 3]))
    }

    @Test("Shift-Command on a header picks every column from the anchor's to this one")
    func headerShiftPicksRun() {
        let first = GridSelectionReducer.columnHeaderCommandClick(.empty, column: 1, modifiers: .command, in: grid)

        let run = GridSelectionReducer.columnHeaderCommandClick(first, column: 3, modifiers: [.command, .shift], in: grid)

        #expect(run.columns == IndexSet(integersIn: 1...3))
        #expect(run.rectangles.count == 3)
        #expect(run.activeCell == cell(0, 3))
        #expect(run.anchor == cell(0, 1))

        let released = GridSelectionReducer.columnHeaderCommandClick(run, column: 2, modifiers: .command, in: grid)
        #expect(released.columns == IndexSet([1, 3]))
        #expect(!released.contains(cell(5, 2)))
    }

    @Test("Command on a header after a click adds the column to the cursor's cell, not to the clicked row")
    func headerAfterClickKeepsOnlyTheCursorCell() {
        let picked = GridSelectionReducer.columnHeaderCommandClick(cursorAt(2, 1), column: 4, modifiers: .command, in: grid)

        #expect(picked.rectangles == [GridRect(cell: cell(2, 1)), GridRect(rows: 0...9, columns: 4...4)])
        #expect(picked.columns == IndexSet(integer: 4))
        #expect(picked.mode == .cells)
        #expect(!picked.contains(cell(2, 5)))

        let run = GridSelectionReducer.columnHeaderCommandClick(cursorAt(2, 1), column: 3, modifiers: [.command, .shift], in: grid)
        #expect(run.columns == IndexSet(integersIn: 1...3))
        #expect(!run.contains(cell(2, 5)))
    }

    @Test("Command on a header after picked rows picks the column alone")
    func headerAfterRowPickPicksOnlyTheColumn() {
        let (rows, _) = GridSelectionReducer.rowHeaderPress(.empty, row: 3, modifiers: [], in: grid)

        let picked = GridSelectionReducer.columnHeaderCommandClick(rows, column: 4, modifiers: .command, in: grid)

        #expect(picked.rectangles == [GridRect(rows: 0...9, columns: 4...4)])
        #expect(picked.columns == IndexSet(integer: 4))
    }

    @Test("A header outside the grid leaves the selection alone")
    func headerOutsideGrid() {
        #expect(GridSelectionReducer.columnHeaderCommandClick(single(1, 1), column: 9, modifiers: .command, in: grid) == single(1, 1))
    }

    // MARK: - Arrows

    @Test("An arrow moves the cursor and collapses a range onto the cursor's row")
    func arrowMovesAndCollapses() {
        let block = range(cell(1, 1), cell(3, 3))

        #expect(GridSelectionReducer.move(block, .right, extending: false, toEdge: false, in: grid) == cursorAt(3, 4))
        #expect(GridSelectionReducer.move(single(4, 2), .up, extending: false, toEdge: false, in: grid) == cursorAt(3, 2))
        #expect(GridSelectionReducer.move(single(4, 2), .down, extending: false, toEdge: false, in: grid) == cursorAt(5, 2))
        #expect(GridSelectionReducer.move(single(4, 2), .left, extending: false, toEdge: false, in: grid) == cursorAt(4, 1))
    }

    @Test("An arrow at an edge stays put and never wraps")
    func arrowStopsAtEdges() {
        #expect(GridSelectionReducer.move(single(0, 0), .up, extending: false, toEdge: false, in: grid) == cursorAt(0, 0))
        #expect(GridSelectionReducer.move(single(0, 0), .left, extending: false, toEdge: false, in: grid) == cursorAt(0, 0))
        #expect(GridSelectionReducer.move(single(9, 5), .down, extending: false, toEdge: false, in: grid) == cursorAt(9, 5))
        #expect(GridSelectionReducer.move(single(9, 5), .right, extending: false, toEdge: false, in: grid) == cursorAt(9, 5))
    }

    @Test("Command-arrow jumps to the grid edge")
    func arrowToEdge() {
        let start = single(4, 2)

        #expect(GridSelectionReducer.move(start, .down, extending: false, toEdge: true, in: grid) == cursorAt(9, 2))
        #expect(GridSelectionReducer.move(start, .up, extending: false, toEdge: true, in: grid) == cursorAt(0, 2))
        #expect(GridSelectionReducer.move(start, .left, extending: false, toEdge: true, in: grid) == cursorAt(4, 0))
        #expect(GridSelectionReducer.move(start, .right, extending: false, toEdge: true, in: grid) == cursorAt(4, 5))
    }

    @Test("Shift-arrow grows the rectangle from the anchor and moves the active cell")
    func shiftArrowGrows() {
        let down = GridSelectionReducer.move(single(2, 2), .down, extending: true, toEdge: false, in: grid)
        #expect(down == range(cell(2, 2), cell(3, 2)))

        let right = GridSelectionReducer.move(down, .right, extending: true, toEdge: false, in: grid)
        #expect(right == range(cell(2, 2), cell(3, 3)))
    }

    @Test("Shift-arrow back the other way shrinks with the anchor fixed")
    func shiftArrowShrinks() {
        var selection = single(2, 2)
        for direction in [GridMoveDirection.down, .down, .up] {
            selection = GridSelectionReducer.move(selection, direction, extending: true, toEdge: false, in: grid)
        }

        #expect(selection == range(cell(2, 2), cell(3, 2)))
    }

    @Test("Shift-Command-arrow extends to the grid edge")
    func shiftArrowToEdge() {
        let selection = GridSelectionReducer.move(single(4, 2), .right, extending: true, toEdge: true, in: grid)

        #expect(selection == range(cell(4, 2), cell(4, 5)))
    }

    @Test("Shift-arrow after a row header press starts a range at the cursor")
    func shiftArrowAfterRowHeader() {
        let (rows, _) = GridSelectionReducer.rowHeaderPress(.empty, row: 6, modifiers: [], in: grid)

        let selection = GridSelectionReducer.move(rows, .down, extending: true, toEdge: false, in: grid)

        #expect(selection.rectangles == [GridRect(rows: 6...7, columns: 0...0)])
    }

    @Test("An arrow with nothing selected lands on the first row")
    func arrowFromNothing() {
        #expect(GridSelectionReducer.move(.empty, .down, extending: false, toEdge: false, in: grid) == cursorAt(0, 0))
        #expect(GridSelectionReducer.move(.empty, .right, extending: true, toEdge: false, in: grid) == cursorAt(0, 0))
    }

    @Test("An arrow on a grid with no columns selects nothing")
    func arrowOnEmptyGrid() {
        let empty = GridSelectionContext(rowCount: 4, columnCount: 0)

        #expect(GridSelectionReducer.move(single(1, 1), .down, extending: false, toEdge: false, in: empty) == .empty)
    }

    @Test("Command-Left and Command-Right reach the first and last column")
    func moveToColumnEdge() {
        #expect(GridSelectionReducer.moveToColumnEdge(single(3, 3), last: true, extending: false, in: grid) == cursorAt(3, 5))
        #expect(GridSelectionReducer.moveToColumnEdge(single(3, 3), last: false, extending: false, in: grid) == cursorAt(3, 0))
        #expect(GridSelectionReducer.moveToColumnEdge(single(3, 3), last: true, extending: true, in: grid) == range(cell(3, 3), cell(3, 5)))
    }

    @Test("Left and Right over a clicked row move the cursor and keep the row")
    func arrowAcrossClickedRowKeepsRow() {
        let moved = GridSelectionReducer.move(cursorAt(4, 2), .right, extending: false, toEdge: false, in: grid)

        #expect(moved.rectangles == [wholeRows(4...4)])
        #expect(moved.activeCell == cell(4, 3))
        #expect(!moved.picksRows)
    }

    @Test("A Command-press after a click adds the clicked cell to the cursor's cell")
    func commandPressAfterClickAddsCell() {
        let (selection, _) = GridSelectionReducer.press(cursorAt(2, 1), at: cell(5, 3), modifiers: .command, in: grid)

        #expect(selection.rectangles == [GridRect(cell: cell(2, 1)), GridRect(cell: cell(5, 3))])
        #expect(selection.activeCell == cell(5, 3))
    }

    @Test("Row picks stay picks through a native row move")
    func nativeMoveKeepsRowPick() {
        let (picked, _) = GridSelectionReducer.rowHeaderPress(.empty, row: 2, modifiers: [], in: grid)
        #expect(picked.picksRows)

        let moved = GridSelectionReducer.rowsSelectedNatively(IndexSet(integer: 3), previous: picked, in: grid)

        #expect(moved.picksRows)
        #expect(!GridSelectionReducer.rowsSelectedNatively(IndexSet(integer: 3), previous: cursorAt(2, 1), in: grid).picksRows)
    }

    // MARK: - Tab

    @Test("Tab moves right and wraps to the next row's first cell")
    func tabMovesAndWraps() {
        #expect(GridSelectionReducer.tab(single(2, 1), forward: true, in: grid) == cursorAt(2, 2))
        #expect(GridSelectionReducer.tab(single(2, 5), forward: true, in: grid) == cursorAt(3, 0))
    }

    @Test("Shift-Tab moves left and wraps to the previous row's last cell")
    func backtabMovesAndWraps() {
        #expect(GridSelectionReducer.tab(single(2, 3), forward: false, in: grid) == cursorAt(2, 2))
        #expect(GridSelectionReducer.tab(single(2, 0), forward: false, in: grid) == cursorAt(1, 5))
    }

    @Test("Tab stops at the last cell and Shift-Tab at the first")
    func tabStopsAtEnds() {
        #expect(GridSelectionReducer.tab(single(9, 5), forward: true, in: grid) == cursorAt(9, 5))
        #expect(GridSelectionReducer.tab(single(0, 0), forward: false, in: grid) == cursorAt(0, 0))
    }

    @Test("Tab collapses a range onto the next cell")
    func tabCollapsesRange() {
        #expect(GridSelectionReducer.tab(range(cell(1, 1), cell(3, 3)), forward: true, in: grid) == cursorAt(3, 4))
    }

    @Test("Tab with nothing selected leaves the selection empty")
    func tabWithNothingSelected() {
        #expect(GridSelectionReducer.tab(.empty, forward: true, in: grid) == .empty)
    }

    // MARK: - Whole grid and rows

    @Test("Select All picks every row, marks no column and leaves no cursor")
    func selectAllCoversGrid() {
        let selection = GridSelectionReducer.selectAll(single(4, 3), in: grid)

        #expect(selection.rectangles == [GridRect(rows: 0...9, columns: 0...5)])
        #expect(selection.columns.isEmpty)
        #expect(selection.picksRows)
        #expect(selection.activeCell == nil)
        #expect(GridSelectionReducer.selectAll(.empty, in: grid).activeCell == nil)
        #expect(GridSelectionReducer.selectAll(.empty, in: GridSelectionContext(rowCount: 0, columnCount: 3)) == .empty)
    }

    @Test("Shift-Space widens to every touched row, one rectangle per run")
    func widenToRowsMergesRuns() {
        let scattered = GridSelection(
            rectangles: [
                GridRect(rows: 1...2, columns: 1...1),
                GridRect(rows: 2...3, columns: 4...4),
                GridRect(rows: 6...6, columns: 0...0)
            ],
            activeCell: cell(2, 4),
            anchor: cell(2, 4)
        )

        let widened = GridSelectionReducer.widenToRows(scattered, in: grid)

        #expect(widened.rectangles == [wholeRows(1...3), wholeRows(6...6)])
        #expect(widened.activeCell == cell(2, 4))
    }

    @Test("Shift-Space over Select All stays one rectangle")
    func widenSelectAllStaysOneRectangle() {
        let all = GridSelectionReducer.selectAll(single(0, 0), in: grid)

        #expect(GridSelectionReducer.widenToRows(all, in: grid).rectangles.count == 1)
        #expect(GridSelectionReducer.widenToRows(.empty, in: grid) == .empty)
    }

    // MARK: - Escape

    @Test("Escape drops a range back to the cursor's row")
    func cancelKeepsActiveCell() {
        #expect(GridSelectionReducer.cancel(range(cell(1, 1), cell(3, 3)), in: grid) == cursorAt(3, 3))
        #expect(GridSelectionReducer.cancel(range(cell(0, 0), cell(2, 2)), in: grid) == cursorAt(2, 2))
        #expect(GridSelectionReducer.cancel(single(4, 4), in: grid) == cursorAt(4, 4))
    }

    @Test("Escape on the cursor's row clears the selection")
    func cancelSingleCellClears() {
        #expect(GridSelectionReducer.cancel(cursorAt(4, 4), in: grid) == .empty)
        #expect(GridSelectionReducer.cancel(.empty, in: grid) == .empty)
    }

    @Test("Escape on whole rows clears the selection")
    func cancelWholeRowsClears() {
        let (rows, _) = GridSelectionReducer.rowHeaderPress(.empty, row: 3, modifiers: .shift, in: grid)
        let (run, _) = GridSelectionReducer.rowHeaderPress(rows, row: 6, modifiers: .shift, in: grid)

        #expect(GridSelectionReducer.cancel(run, in: grid) == .empty)
        #expect(GridSelectionReducer.cancel(GridSelectionReducer.selectAll(single(1, 1), in: grid), in: grid) == .empty)
    }

    @Test("Escape on a picked column keeps the cursor")
    func cancelPickedColumnKeepsCursor() {
        let picked = GridSelectionReducer.columnHeaderCommandClick(.empty, column: 2, modifiers: .command, in: grid)

        #expect(GridSelectionReducer.cancel(picked, in: grid) == cursorAt(0, 2))
    }

    // MARK: - Native row selection

    @Test("Down from a cell selects the next row and keeps the column")
    func nativeRowMoveKeepsColumn() {
        let selection = GridSelectionReducer.rowsSelectedNatively(IndexSet(integer: 3), previous: single(2, 3), in: grid)

        #expect(selection.rectangles == [wholeRows(3...3)])
        #expect(selection.activeCell == cell(3, 3))
        #expect(selection.anchor == cell(3, 3))
    }

    @Test("Rows extended natively move the cursor to the new row and keep the anchor")
    func nativeRowExtendKeepsAnchor() {
        let previous = GridSelection(rectangles: [wholeRows(3...3)], activeCell: cell(3, 3), anchor: cell(3, 3))

        let selection = GridSelectionReducer.rowsSelectedNatively(IndexSet(integersIn: 3...4), previous: previous, in: grid)

        #expect(selection.rectangles == [wholeRows(3...4)])
        #expect(selection.activeCell == cell(4, 3))
        #expect(selection.anchor == cell(3, 3))
    }

    @Test("Rows shrunk natively put the cursor on the end that lost a row")
    func nativeRowShrinkMovesCursor() {
        let previous = GridSelection(rectangles: [wholeRows(2...4)], activeCell: cell(2, 1), anchor: cell(4, 1))

        let selection = GridSelectionReducer.rowsSelectedNatively(IndexSet(integersIn: 3...4), previous: previous, in: grid)

        #expect(selection.activeCell == cell(3, 1))
        #expect(selection.anchor == cell(4, 1))
    }

    @Test("Scattered native rows become one rectangle per run, and rows past the end drop")
    func nativeRowsByRun() {
        let selection = GridSelectionReducer.rowsSelectedNatively(IndexSet([1, 2, 5, 8, 9, 12]), previous: .empty, in: grid)

        #expect(selection.rectangles == [wholeRows(1...2), wholeRows(5...5), wholeRows(8...9)])
        #expect(selection.activeCell == cell(9, 0))
    }

    @Test("No native rows is no selection")
    func nativeNoRows() {
        #expect(GridSelectionReducer.rowsSelectedNatively(IndexSet(), previous: single(1, 1), in: grid) == .empty)
    }
}

struct GridSelectionDragIndexTests {
    private func column(hit: Int, x: CGFloat) -> Int? {
        GridSelectionReducer.dragIndex(hit: hit, coordinate: x, first: 1, last: 4, lastMaxEdge: 500)
    }

    @Test("A drag past the trailing edge holds the last column, past the leading edge the first")
    func outsideHitsHoldTheNearEnd() {
        #expect(column(hit: -1, x: 5_000) == 4)
        #expect(column(hit: -1, x: -30) == 1)
    }

    @Test("A hit inside the run is clamped into the presented range")
    func hitInsideRunIsClamped() {
        #expect(column(hit: 3, x: 200) == 3)
        #expect(column(hit: 0, x: 10) == 1)
        #expect(column(hit: 9, x: 480) == 4)
    }

    @Test("A drag below the last row holds the last row, above the first the first")
    func rowsOutsideHoldTheNearEnd() {
        #expect(GridSelectionReducer.dragIndex(hit: -1, coordinate: 99_999, first: 0, last: 39, lastMaxEdge: 880) == 39)
        #expect(GridSelectionReducer.dragIndex(hit: -1, coordinate: -30, first: 0, last: 39, lastMaxEdge: 880) == 0)
        #expect(GridSelectionReducer.dragIndex(hit: 99, coordinate: 400, first: 0, last: 39, lastMaxEdge: 880) == 39)
    }

    @Test("Nothing to land on resolves nothing")
    func emptyRunResolvesNothing() {
        #expect(GridSelectionReducer.dragIndex(hit: -1, coordinate: 100, first: -1, last: -1, lastMaxEdge: 0) == nil)
        #expect(GridSelectionReducer.dragIndex(hit: -1, coordinate: 10, first: 0, last: -1, lastMaxEdge: 0) == nil)
    }
}
