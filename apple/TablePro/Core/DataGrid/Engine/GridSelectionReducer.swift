import Foundation

struct GridSelectionContext: Equatable {
    let rowCount: Int
    let columnCount: Int

    var isEmpty: Bool { rowCount <= 0 || columnCount <= 0 }

    fileprivate var allRows: ClosedRange<Int> { 0...max(rowCount - 1, 0) }
    fileprivate var allColumns: ClosedRange<Int> { 0...max(columnCount - 1, 0) }

    fileprivate func clamp(_ cell: GridCoord) -> GridCoord {
        GridCoord(
            row: min(max(cell.row, 0), max(rowCount - 1, 0)),
            displayColumn: min(max(cell.displayColumn, 0), max(columnCount - 1, 0))
        )
    }

    fileprivate func fit(_ selection: GridSelection) -> GridSelection {
        selection.clamped(rowLimit: rowCount, columnLimit: columnCount)
    }
}

enum GridMoveDirection: Equatable {
    case up
    case down
    case left
    case right
}

struct GridPointerModifiers: OptionSet {
    let rawValue: Int

    static let shift = GridPointerModifiers(rawValue: 1 << 0)
    static let command = GridPointerModifiers(rawValue: 1 << 1)
}

struct GridSelectionDrag: Equatable {
    enum Mode: Equatable {
        case replace
        case additive
        case rows
    }

    let origin: GridCoord
    let base: GridSelection
    let mode: Mode
}

enum GridSelectionReducer {
    static func single(_ cell: GridCoord) -> GridSelection {
        GridSelection(rectangles: [GridRect(cell: cell)], activeCell: cell, anchor: cell)
    }

    // A cell click selects its row natively and puts the cursor on the cell; a range forms only by drag or Shift.
    static func cursor(_ cell: GridCoord, in c: GridSelectionContext) -> GridSelection {
        guard !c.isEmpty else { return .empty }
        let target = c.clamp(cell)
        return GridSelection(
            rectangles: [GridRect(rows: target.row...target.row, columns: c.allColumns)],
            activeCell: target,
            anchor: target,
            mode: .cursor
        )
    }

    // MARK: - Pointer

    static func press(
        _ s: GridSelection,
        at cell: GridCoord,
        modifiers: GridPointerModifiers,
        in c: GridSelectionContext
    ) -> (GridSelection, GridSelectionDrag) {
        guard !c.isEmpty else {
            return (.empty, GridSelectionDrag(origin: cell, base: .empty, mode: .replace))
        }
        let target = c.clamp(cell)
        let current = c.fit(s)
        switch Gesture(modifiers) {
        case .toggle:
            let base = cellBase(of: current, in: c)
            let drag = GridSelectionDrag(origin: target, base: base, mode: .additive)
            return (c.fit(toggling(target, in: base)), drag)
        case .extend:
            let anchor = current.anchor ?? current.activeCell ?? target
            let drag = GridSelectionDrag(origin: anchor, base: .empty, mode: .replace)
            guard anchor != target else { return (cursor(target, in: c), drag) }
            return (c.fit(range(from: anchor, to: target)), drag)
        case .replace:
            return (cursor(target, in: c), GridSelectionDrag(origin: target, base: .empty, mode: .replace))
        }
    }

    // A drag back onto its origin gives the press's own result, so a Command-press that never moves stays a toggle.
    static func drag(_ d: GridSelectionDrag, to cell: GridCoord, in c: GridSelectionContext) -> GridSelection {
        guard !c.isEmpty else { return .empty }
        let target = c.clamp(cell)
        let origin = c.clamp(d.origin)
        let base = c.fit(d.base)
        switch d.mode {
        case .replace:
            guard target != origin else { return cursor(origin, in: c) }
            return c.fit(range(from: origin, to: target))
        case .additive:
            guard target != origin else { return c.fit(toggling(origin, in: base)) }
            return c.fit(GridSelection(
                rectangles: base.rectangles + [GridRect.between(origin, target)],
                activeCell: target,
                anchor: origin,
                columns: base.columns
            ))
        case .rows:
            guard target.row != origin.row else {
                return picking(c.fit(togglingRow(origin.row, in: base, activeColumn: origin.displayColumn, c)))
            }
            return picking(c.fit(addingRows(
                min(origin.row, target.row)...max(origin.row, target.row),
                to: base,
                active: GridCoord(row: target.row, displayColumn: origin.displayColumn),
                anchor: origin,
                c
            )))
        }
    }

    static func rowHeaderPress(
        _ s: GridSelection,
        row: Int,
        modifiers: GridPointerModifiers,
        in c: GridSelectionContext
    ) -> (GridSelection, GridSelectionDrag) {
        guard !c.isEmpty else {
            return (.empty, GridSelectionDrag(origin: GridCoord(row: row, displayColumn: 0), base: .empty, mode: .rows))
        }
        let current = c.fit(s)
        let column = activeColumn(of: current, in: c)
        let target = c.clamp(GridCoord(row: row, displayColumn: column))
        switch Gesture(modifiers) {
        case .toggle:
            let drag = GridSelectionDrag(origin: target, base: current, mode: .rows)
            return (picking(c.fit(togglingRow(target.row, in: current, activeColumn: column, c))), drag)
        case .extend:
            let anchor = GridCoord(row: current.anchor?.row ?? current.activeCell?.row ?? target.row, displayColumn: column)
            let drag = GridSelectionDrag(origin: anchor, base: .empty, mode: .rows)
            let rows = min(anchor.row, target.row)...max(anchor.row, target.row)
            return (picking(c.fit(addingRows(rows, to: .empty, active: target, anchor: anchor, c))), drag)
        case .replace:
            let drag = GridSelectionDrag(origin: target, base: .empty, mode: .rows)
            return (picking(c.fit(addingRows(target.row...target.row, to: .empty, active: target, anchor: target, c))), drag)
        }
    }

    // A plain row number press AppKit tracks for a drag. A reorder moves one row, so there the pressed row is picked alone.
    static func rowNumberDragPress(
        _ s: GridSelection,
        row: Int,
        keepsPickedRows: Bool,
        in c: GridSelectionContext
    ) -> GridSelection {
        let current = c.fit(s)
        if keepsPickedRows, current.picksRows, current.affectedRows.contains(row) {
            return current
        }
        return rowHeaderPress(current, row: row, modifiers: [], in: c).0
    }

    static func columnHeaderCommandClick(
        _ s: GridSelection,
        column: Int,
        modifiers: GridPointerModifiers,
        in c: GridSelectionContext
    ) -> GridSelection {
        let current = c.fit(s)
        guard !c.isEmpty, column >= 0, column < c.columnCount else { return current }
        let base = cellBase(of: current, in: c)
        if modifiers.contains(.shift),
           let from = base.anchor?.displayColumn ?? base.activeCell?.displayColumn,
           from != column {
            return c.fit(addingColumns(from: from, to: column, in: base, c))
        }
        if base.columns.contains(column) {
            return c.fit(removingColumn(column, from: base, c))
        }
        let addition = GridSelection.column(column, totalRows: c.rowCount)
        return c.fit(base.isEmpty ? addition : base.union(addition))
    }

    // MARK: - Keyboard

    static func move(
        _ s: GridSelection,
        _ direction: GridMoveDirection,
        extending: Bool,
        toEdge: Bool,
        in c: GridSelectionContext
    ) -> GridSelection {
        guard !c.isEmpty else { return .empty }
        let current = c.fit(s)
        guard let active = cursor(of: current, in: c) else {
            return cursor(GridCoord(row: 0, displayColumn: 0), in: c)
        }
        let next = step(from: active, direction, toEdge: toEdge, in: c)
        guard extending else {
            // Left and Right over picked rows move the cursor and keep the rows, as the cursor did before.
            if current.isRows, next.row == active.row, current.affectedRows.contains(next.row) {
                return GridSelection(rectangles: current.rectangles, activeCell: next, anchor: next, mode: .cursor)
            }
            return cursor(next, in: c)
        }
        let anchor = current.anchor ?? active
        guard anchor != next else { return cursor(next, in: c) }
        return c.fit(range(from: anchor, to: next))
    }

    static func moveToColumnEdge(
        _ s: GridSelection,
        last: Bool,
        extending: Bool,
        in c: GridSelectionContext
    ) -> GridSelection {
        move(s, last ? .right : .left, extending: extending, toEdge: true, in: c)
    }

    // With no cell to start from the selection comes back unchanged, which tells the view to leave the grid.
    static func tab(_ s: GridSelection, forward: Bool, in c: GridSelectionContext) -> GridSelection {
        guard !c.isEmpty else { return .empty }
        let current = c.fit(s)
        guard let active = cursor(of: current, in: c) else { return current }
        let next: GridCoord
        if forward {
            if active.displayColumn + 1 < c.columnCount {
                next = GridCoord(row: active.row, displayColumn: active.displayColumn + 1)
            } else if active.row + 1 < c.rowCount {
                next = GridCoord(row: active.row + 1, displayColumn: 0)
            } else {
                next = active
            }
        } else {
            if active.displayColumn > 0 {
                next = GridCoord(row: active.row, displayColumn: active.displayColumn - 1)
            } else if active.row > 0 {
                next = GridCoord(row: active.row - 1, displayColumn: c.columnCount - 1)
            } else {
                next = active
            }
        }
        return cursor(next, in: c)
    }

    // Select All picks every row and leaves no cursor, as NSTableView's own selectAll does.
    static func selectAll(_ s: GridSelection, in c: GridSelectionContext) -> GridSelection {
        guard !c.isEmpty else { return .empty }
        return GridSelection(
            rectangles: [GridRect(rows: c.allRows, columns: c.allColumns)],
            activeCell: nil,
            anchor: nil,
            mode: .rows
        )
    }

    static func widenToRows(_ s: GridSelection, in c: GridSelectionContext) -> GridSelection {
        guard !c.isEmpty else { return .empty }
        let current = c.fit(s)
        let rows = current.affectedRows
        guard let firstRow = rows.first else { return current }
        let cursorCell = cursor(of: current, in: c) ?? GridCoord(row: firstRow, displayColumn: 0)
        let active = rows.contains(cursorCell.row)
            ? cursorCell
            : GridCoord(row: firstRow, displayColumn: cursorCell.displayColumn)
        let anchor = current.anchor.flatMap { rows.contains($0.row) ? $0 : nil } ?? active
        return picking(c.fit(GridSelection(rectangles: rowRectangles(rows, c), activeCell: active, anchor: anchor)))
    }

    // Without a context, whole rows are guessed from the shape: every rectangle spans column 0 to one shared last column.
    // Escape drops a cell range back to its cursor's row, then the rows to nothing.
    static func cancel(_ s: GridSelection, in c: GridSelectionContext) -> GridSelection {
        guard !s.isEmpty, !s.isRows else { return .empty }
        guard let active = s.activeCell ?? s.anchor ?? s.rectangles.first.map(topLeft) else { return .empty }
        return cursor(active, in: c)
    }

    static func rowsSelectedNatively(
        _ rows: IndexSet,
        previous: GridSelection,
        in c: GridSelectionContext
    ) -> GridSelection {
        guard !c.isEmpty else { return .empty }
        let valid = rows.filteredIndexSet { $0 >= 0 && $0 < c.rowCount }
        guard let firstRow = valid.first, let lastRow = valid.last else { return .empty }
        let column = activeColumn(of: previous, in: c)
        let previousRows = previous.affectedRows
        let row: Int
        if let added = valid.subtracting(previousRows).last {
            row = added
        } else if let lost = previousRows.subtracting(valid).last {
            row = lost > lastRow ? lastRow : firstRow
        } else if let kept = previous.activeCell?.row, valid.contains(kept) {
            row = kept
        } else {
            row = firstRow
        }
        let active = GridCoord(row: row, displayColumn: column)
        let anchor = previous.anchor.flatMap { valid.contains($0.row) ? GridCoord(row: $0.row, displayColumn: column) : nil }
        return GridSelection(
            rectangles: rowRectangles(valid, c),
            activeCell: previous.activeCell == nil && previous.picksRows ? nil : active,
            anchor: anchor ?? active,
            mode: previous.picksRows ? .rows : .cursor
        )
    }

    // NSTableView answers -1 for a point past either end, so the point decides which end.
    static func dragIndex(hit: Int, coordinate: CGFloat, first: Int, last: Int, lastMaxEdge: CGFloat) -> Int? {
        guard first >= 0, last >= first else { return nil }
        guard hit < 0 else { return min(max(hit, first), last) }
        return coordinate >= lastMaxEdge ? last : first
    }
}

// MARK: - Helpers

private enum Gesture {
    case replace
    case extend
    case toggle

    init(_ modifiers: GridPointerModifiers) {
        switch (modifiers.contains(.shift), modifiers.contains(.command)) {
        case (false, true): self = .toggle
        case (true, false): self = .extend
        default: self = .replace
        }
    }
}

private extension GridSelectionReducer {
    static func picking(_ s: GridSelection) -> GridSelection {
        var picked = s
        picked.mode = s.isEmpty ? .cells : .rows
        return picked
    }

    // A Command-click on a cell or a header adds to the cells already chosen; a clicked row lends only its cursor cell.
    static func cellBase(of s: GridSelection, in c: GridSelectionContext) -> GridSelection {
        switch s.mode {
        case .cells:
            return s
        case .cursor:
            return s.activeCell.map(single) ?? .empty
        case .rows:
            return .empty
        }
    }

    static func range(from anchor: GridCoord, to active: GridCoord) -> GridSelection {
        GridSelection(rectangles: [GridRect.between(anchor, active)], activeCell: active, anchor: anchor)
    }

    static func topLeft(_ rect: GridRect) -> GridCoord {
        GridCoord(row: rect.rows.lowerBound, displayColumn: rect.columns.lowerBound)
    }

    static func cursor(of s: GridSelection, in c: GridSelectionContext) -> GridCoord? {
        guard let cell = s.activeCell ?? s.anchor ?? s.rectangles.first.map(topLeft) else { return nil }
        return c.clamp(cell)
    }

    static func activeColumn(of s: GridSelection, in c: GridSelectionContext) -> Int {
        let column = s.activeCell?.displayColumn ?? s.anchor?.displayColumn ?? 0
        return min(max(column, 0), max(c.columnCount - 1, 0))
    }

    static func step(
        from cell: GridCoord,
        _ direction: GridMoveDirection,
        toEdge: Bool,
        in c: GridSelectionContext
    ) -> GridCoord {
        switch direction {
        case .up:
            return GridCoord(row: toEdge ? 0 : max(0, cell.row - 1), displayColumn: cell.displayColumn)
        case .down:
            return GridCoord(row: toEdge ? c.rowCount - 1 : min(c.rowCount - 1, cell.row + 1), displayColumn: cell.displayColumn)
        case .left:
            return GridCoord(row: cell.row, displayColumn: toEdge ? 0 : max(0, cell.displayColumn - 1))
        case .right:
            return GridCoord(
                row: cell.row,
                displayColumn: toEdge ? c.columnCount - 1 : min(c.columnCount - 1, cell.displayColumn + 1)
            )
        }
    }

    static func toggling(_ cell: GridCoord, in base: GridSelection) -> GridSelection {
        if base.contains(cell) {
            return base.removing(cell: cell)
        }
        return GridSelection(
            rectangles: base.rectangles + [GridRect(cell: cell)],
            activeCell: cell,
            anchor: cell,
            columns: base.columns
        )
    }

    static func rowRectangles(_ rows: IndexSet, _ c: GridSelectionContext) -> [GridRect] {
        rows.rangeView.map { GridRect(rows: $0.lowerBound...($0.upperBound - 1), columns: c.allColumns) }
    }

    static func addingRows(
        _ rows: ClosedRange<Int>,
        to base: GridSelection,
        active: GridCoord,
        anchor: GridCoord,
        _ c: GridSelectionContext
    ) -> GridSelection {
        GridSelection(
            rectangles: base.rectangles + [GridRect(rows: rows, columns: c.allColumns)],
            activeCell: active,
            anchor: anchor,
            columns: base.columns
        )
    }

    static func togglingRow(_ row: Int, in base: GridSelection, activeColumn: Int, _ c: GridSelectionContext) -> GridSelection {
        let cell = GridCoord(row: row, displayColumn: activeColumn)
        guard base.columns(in: row).contains(integersIn: 0..<c.columnCount) else {
            return addingRows(row...row, to: base, active: cell, anchor: cell, c)
        }
        var kept: [GridRect] = []
        for rect in base.rectangles {
            guard rect.rows.contains(row) else {
                kept.append(rect)
                continue
            }
            if rect.rows.lowerBound < row {
                kept.append(GridRect(rows: rect.rows.lowerBound...(row - 1), columns: rect.columns))
            }
            if row < rect.rows.upperBound {
                kept.append(GridRect(rows: (row + 1)...rect.rows.upperBound, columns: rect.columns))
            }
        }
        guard let last = kept.last else { return .empty }
        func inside(_ coord: GridCoord?) -> GridCoord? {
            guard let coord, kept.contains(where: { $0.contains(coord) }) else { return nil }
            return coord
        }
        let active = inside(base.activeCell) ?? topLeft(last)
        // A picked column lost a row, so it no longer spans the grid.
        return GridSelection(rectangles: kept, activeCell: active, anchor: inside(base.anchor) ?? active)
    }

    static func addingColumns(from: Int, to column: Int, in base: GridSelection, _ c: GridSelectionContext) -> GridSelection {
        let span = min(from, column)...max(from, column)
        let added = span.filter { !base.columns.contains($0) }
        return GridSelection(
            rectangles: base.rectangles + added.map { GridRect(rows: c.allRows, columns: $0...$0) },
            activeCell: GridCoord(row: 0, displayColumn: column),
            anchor: GridCoord(row: 0, displayColumn: from),
            columns: base.columns.union(IndexSet(integersIn: span))
        )
    }

    static func removingColumn(_ column: Int, from base: GridSelection, _ c: GridSelectionContext) -> GridSelection {
        let dropped = GridRect(rows: c.allRows, columns: column...column)
        let kept = base.rectangles.filter { $0 != dropped }
        guard let last = kept.last else { return .empty }
        var markers = base.columns
        markers.remove(column)
        let active = topLeft(last)
        return GridSelection(rectangles: kept, activeCell: active, anchor: active, columns: markers)
    }
}
