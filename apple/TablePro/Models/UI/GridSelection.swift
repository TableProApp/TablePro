import Foundation

struct GridSelection: Equatable {
    var rectangles: [GridRect]
    var activeCell: GridCoord?
    var anchor: GridCoord?
    // Recorded, not read from shape: a full-height rectangle is also Select All, Shift+Space or a drag on a short page.
    var columns: IndexSet = []
    // Geometry can't tell the pick: an all-columns range on a narrow grid is still cells, and a click's pick is one cell.
    enum Mode: Equatable {
        case cells
        // A cell click: its row is selected and the cursor sits on the cell.
        case cursor
        // Row numbers, Select All, Shift+Space.
        case rows
    }

    var mode: Mode = .cells

    var picksRows: Bool { mode == .rows }
    var isRows: Bool { mode != .cells }

    static let empty = GridSelection(rectangles: [], activeCell: nil, anchor: nil)

    var isEmpty: Bool { rectangles.isEmpty }

    func contains(_ coord: GridCoord) -> Bool {
        rectangles.contains { $0.contains(coord) }
    }

    func contains(row: Int, displayColumn: Int) -> Bool {
        contains(GridCoord(row: row, displayColumn: displayColumn))
    }

    var affectedRows: IndexSet {
        var set = IndexSet()
        for rect in rectangles {
            set.insert(integersIn: rect.rows.lowerBound...rect.rows.upperBound)
        }
        return set
    }

    // Display positions: convert with TableViewCoordinator.dataColumnIndices(in:) before indexing anything holding values.
    var affectedColumns: IndexSet {
        var set = IndexSet()
        for rect in rectangles {
            set.insert(integersIn: rect.columns.lowerBound...rect.columns.upperBound)
        }
        return set
    }

    var boundingRectangle: GridRect? {
        guard let first = rectangles.first else { return nil }
        var minRow = first.rows.lowerBound
        var maxRow = first.rows.upperBound
        var minColumn = first.columns.lowerBound
        var maxColumn = first.columns.upperBound
        for rect in rectangles.dropFirst() {
            minRow = min(minRow, rect.rows.lowerBound)
            maxRow = max(maxRow, rect.rows.upperBound)
            minColumn = min(minColumn, rect.columns.lowerBound)
            maxColumn = max(maxColumn, rect.columns.upperBound)
        }
        return GridRect(rows: minRow...maxRow, columns: minColumn...maxColumn)
    }

    func columns(in row: Int) -> IndexSet {
        var set = IndexSet()
        for rect in rectangles where rect.rows.contains(row) {
            set.insert(integersIn: rect.columns.lowerBound...rect.columns.upperBound)
        }
        return set
    }

    // NSTableView.selectRowIndexes selects nothing if any index is out of range (measured), and a restored result can shrink.
    func clamped(rowLimit: Int, columnLimit: Int) -> GridSelection {
        let fitted = rectangles.compactMap { $0.clamped(rowLimit: rowLimit, columnLimit: columnLimit) }
        guard !fitted.isEmpty else { return .empty }
        func fit(_ coord: GridCoord?) -> GridCoord? {
            guard let coord,
                  coord.row >= 0, coord.row < rowLimit,
                  coord.displayColumn >= 0, coord.displayColumn < columnLimit else { return nil }
            return coord
        }
        // A marker survives only while its block still covers the column: a grown result left a stale marker short of the end.
        let stillWholeColumns = columns.filteredIndexSet { position in
            guard position >= 0, position < columnLimit else { return false }
            return fitted.contains { rect in
                rect.columns.contains(position) && rect.rows.lowerBound <= 0 && rect.rows.upperBound >= rowLimit - 1
            }
        }
        return GridSelection(
            rectangles: fitted,
            activeCell: fit(activeCell),
            anchor: fit(anchor),
            columns: stillWholeColumns,
            mode: mode
        )
    }

    func union(_ other: GridSelection) -> GridSelection {
        GridSelection(
            rectangles: rectangles + other.rectangles,
            activeCell: other.activeCell ?? activeCell,
            anchor: other.anchor ?? anchor,
            columns: columns.union(other.columns),
            mode: mode == other.mode ? mode : .cells
        )
    }

    static func single(_ rect: GridRect, anchor: GridCoord, active: GridCoord) -> GridSelection {
        GridSelection(rectangles: [rect], activeCell: active, anchor: anchor)
    }

    // Carries the position, so the heading knows it was chosen rather than merely covered.
    static func column(_ displayColumn: Int, totalRows: Int) -> GridSelection {
        let anchor = GridCoord(row: 0, displayColumn: displayColumn)
        return GridSelection(
            rectangles: [GridRect(rows: 0...(totalRows - 1), columns: displayColumn...displayColumn)],
            activeCell: anchor,
            anchor: anchor,
            columns: IndexSet(integer: displayColumn)
        )
    }
}

internal extension GridSelection {
    // Rectangles overlap, so areas can't be summed; walked by row band, so a whole-column pick costs one band.
    var uniqueCellCount: Int {
        if rectangles.count == 1, let only = rectangles.first {
            return only.rows.count * only.columns.count
        }
        var total = 0
        forEachRowBand { band, covered in
            total += band.count * covered.count
        }
        return total
    }

    var hasMultipleCells: Bool {
        guard let first = rectangles.first else { return false }
        if rectangles.contains(where: { $0.rows.count > 1 || $0.columns.count > 1 }) {
            return true
        }
        return rectangles.contains { $0 != first }
    }

    func removing(cell: GridCoord) -> GridSelection {
        guard contains(cell) else { return self }
        var remaining: [GridRect] = []
        for rect in rectangles {
            if rect.contains(cell) {
                remaining.append(contentsOf: rect.pieces(around: cell))
            } else {
                remaining.append(rect)
            }
        }
        var markers = columns
        markers.remove(cell.displayColumn)
        return rebuilt(rectangles: remaining, markers: markers, active: activeCell, origin: anchor)
    }
}

private extension GridSelection {
    // Rectangle row bounds are breakpoints, so one column union serves every row of a band.
    func forEachRowBand(_ body: (Range<Int>, IndexSet) -> Void) {
        var breakpoints = rectangles.flatMap { [$0.rows.lowerBound, $0.rows.upperBound + 1] }
        breakpoints.sort()
        var pending = ArraySlice(rectangles.sorted { $0.rows.lowerBound < $1.rows.lowerBound })
        var active: [GridRect] = []
        for (start, end) in zip(breakpoints, breakpoints.dropFirst()) where start < end {
            while let next = pending.first, next.rows.lowerBound <= start {
                active.append(next)
                pending.removeFirst()
            }
            active.removeAll { $0.rows.upperBound < start }
            guard !active.isEmpty else { continue }
            var covered = IndexSet()
            for rect in active {
                covered.insert(integersIn: rect.columns.lowerBound...rect.columns.upperBound)
            }
            body(start..<end, covered)
        }
    }

    // A cursor outside the selection would draw on an unselected cell, so it moves to the last rectangle (as Cmd+click does).
    func rebuilt(rectangles kept: [GridRect], markers: IndexSet, active: GridCoord?, origin: GridCoord?) -> GridSelection {
        guard let last = kept.last else { return .empty }
        func inside(_ coord: GridCoord?) -> GridCoord? {
            guard let coord, kept.contains(where: { $0.contains(coord) }) else { return nil }
            return coord
        }
        let fallback = GridCoord(row: last.rows.lowerBound, displayColumn: last.columns.lowerBound)
        let newActive: GridCoord? = activeCell == nil ? nil : inside(active) ?? fallback
        let newAnchor: GridCoord? = anchor == nil ? nil : inside(origin) ?? newActive ?? fallback
        return GridSelection(rectangles: kept, activeCell: newActive, anchor: newAnchor, columns: markers)
    }
}

private extension GridRect {
    func pieces(around cell: GridCoord) -> [GridRect] {
        var pieces: [GridRect] = []
        if rows.lowerBound < cell.row {
            pieces.append(GridRect(rows: rows.lowerBound...(cell.row - 1), columns: columns))
        }
        if cell.row < rows.upperBound {
            pieces.append(GridRect(rows: (cell.row + 1)...rows.upperBound, columns: columns))
        }
        if columns.lowerBound < cell.displayColumn {
            pieces.append(GridRect(rows: cell.row...cell.row, columns: columns.lowerBound...(cell.displayColumn - 1)))
        }
        if cell.displayColumn < columns.upperBound {
            pieces.append(GridRect(rows: cell.row...cell.row, columns: (cell.displayColumn + 1)...columns.upperBound))
        }
        return pieces
    }
}
