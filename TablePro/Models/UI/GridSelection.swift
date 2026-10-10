import Foundation

struct GridSelection: Equatable {
    var rectangles: [GridRect]
    var activeCell: GridCoord?
    var anchor: GridCoord?
    /// The display positions the user picked *as columns*, by clicking their headings.
    ///
    /// Recorded rather than re-derived, because geometry cannot tell the gestures apart. A
    /// rectangle spanning every row is what a heading click builds, and equally what Select All,
    /// Shift+Space and an ordinary cell drag build whenever the page is short enough. Reading the
    /// intent back out of the shape painted the whole heading row as selected on Cmd+A, hid a
    /// swept block's own outline, and armed the data file window's Delete Column on every column of
    /// the file.
    var columns: IndexSet = []

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

    /// The display positions the selection covers. Convert with
    /// `TableViewCoordinator.dataColumnIndices(in:)` before indexing anything that holds values.
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

    /// The display positions covered on one row.
    func columns(in row: Int) -> IndexSet {
        var set = IndexSet()
        for rect in rectangles where rect.rows.contains(row) {
            set.insert(integersIn: rect.columns.lowerBound...rect.columns.upperBound)
        }
        return set
    }

    /// The part of this selection that still fits a grid of the given size, or `.empty` when none
    /// of it does.
    ///
    /// A selection restored onto a remounted grid describes the result it was made against, and the
    /// row count can have shrunk in between. `NSTableView.selectRowIndexes` is all-or-nothing on an
    /// out-of-range member, measured, so an unclamped restore selects nothing at all rather than the
    /// rows that do still exist.
    func clamped(rowLimit: Int, columnLimit: Int) -> GridSelection {
        let fitted = rectangles.compactMap { $0.clamped(rowLimit: rowLimit, columnLimit: columnLimit) }
        guard !fitted.isEmpty else { return .empty }
        func fit(_ coord: GridCoord?) -> GridCoord? {
            guard let coord,
                  coord.row >= 0, coord.row < rowLimit,
                  coord.displayColumn >= 0, coord.displayColumn < columnLimit else { return nil }
            return coord
        }
        /// A marker only survives while its block still covers the column. The row count can have
        /// grown as well as shrunk, and a result that gained rows leaves the old block short of the
        /// end: keeping the marker then told the heading and the column commands they had a whole
        /// column while the fill, the copy and the affected rows stopped short, and
        /// `removeEntireColumn` could no longer match the stale block to take it back off.
        ///
        /// Checking the geometry here is not the inference this field replaced. It validates a
        /// recorded intent against the result now in front of it, rather than inventing one.
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
            columns: stillWholeColumns
        )
    }

    func union(_ other: GridSelection) -> GridSelection {
        GridSelection(
            rectangles: rectangles + other.rectangles,
            activeCell: other.activeCell ?? activeCell,
            anchor: other.anchor ?? anchor,
            columns: columns.union(other.columns)
        )
    }

    static func single(_ rect: GridRect, anchor: GridCoord, active: GridCoord) -> GridSelection {
        GridSelection(rectangles: [rect], activeCell: active, anchor: anchor)
    }

    /// One whole column the user picked by its heading, carrying the position as well as the block,
    /// so the heading knows it was chosen rather than merely covered.
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
    /// Rectangles overlap (a Cmd+drag over a block, a picked column under a swept one), so summing
    /// their areas counts a cell twice. Walked by row band, so a whole-column pick costs one band.
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

    /// `indices` are positions in the grown grid, as `NSTableView.insertRows(at:)` takes them.
    static func row(_ row: Int, afterInserting indices: IndexSet) -> Int {
        var row = row
        for range in indices.rangeView {
            guard range.lowerBound <= row else { break }
            row += range.count
        }
        return row
    }

    /// `indices` are positions before the removal, as `NSTableView.removeRows(at:)` takes them. Nil
    /// when the row itself was removed.
    static func row(_ row: Int, afterRemoving indices: IndexSet) -> Int? {
        guard !indices.contains(row) else { return nil }
        return row - indices.count(in: 0..<max(0, row))
    }

    func insertingRows(_ indices: IndexSet, newRowCount: Int) -> GridSelection {
        guard !isEmpty, !indices.isEmpty, newRowCount > 0 else { return self }
        let oldRowCount = newRowCount - indices.count
        func shiftedRow(_ row: Int) -> Int {
            Self.row(row, afterInserting: indices)
        }
        func shiftedCoord(_ coord: GridCoord?) -> GridCoord? {
            coord.map { GridCoord(row: shiftedRow($0.row), displayColumn: $0.displayColumn) }
        }
        let moved = rectangles.map { rect -> GridRect in
            if isPickedColumn(rect, rowCount: oldRowCount) {
                return GridRect(rows: 0...(newRowCount - 1), columns: rect.columns)
            }
            return GridRect(
                rows: shiftedRow(rect.rows.lowerBound)...shiftedRow(rect.rows.upperBound),
                columns: rect.columns
            )
        }
        return rebuilt(
            rectangles: moved,
            markers: wholeColumns(in: moved, rowCount: newRowCount),
            active: shiftedCoord(activeCell),
            origin: shiftedCoord(anchor)
        )
    }

    func removingRows(_ indices: IndexSet, newRowCount: Int) -> GridSelection {
        guard !isEmpty, !indices.isEmpty else { return self }
        guard newRowCount > 0 else { return .empty }
        func shiftedRow(_ row: Int) -> Int? {
            Self.row(row, afterRemoving: indices)
        }
        func shiftedCoord(_ coord: GridCoord?) -> GridCoord? {
            guard let coord, let row = shiftedRow(coord.row) else { return nil }
            return GridCoord(row: row, displayColumn: coord.displayColumn)
        }
        let kept = rectangles.compactMap { rect -> GridRect? in
            var survivors = IndexSet(integersIn: rect.rows.lowerBound...rect.rows.upperBound)
            survivors.subtract(indices)
            guard let first = survivors.first,
                  let last = survivors.last,
                  let lower = shiftedRow(first),
                  let upper = shiftedRow(last) else { return nil }
            return GridRect(rows: lower...upper, columns: rect.columns)
        }
        return rebuilt(
            rectangles: kept,
            markers: wholeColumns(in: kept, rowCount: newRowCount),
            active: shiftedCoord(activeCell),
            origin: shiftedCoord(anchor)
        )
    }
}

private extension GridSelection {
    /// Every rectangle's row bounds are breakpoints, so the rectangles covering a band are the same
    /// on each of its rows and one column union serves the whole band.
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

    func isPickedColumn(_ rect: GridRect, rowCount: Int) -> Bool {
        !columns.isEmpty
            && columns.contains(integersIn: rect.columns.lowerBound...rect.columns.upperBound)
            && rect.rows.lowerBound <= 0
            && rect.rows.upperBound >= rowCount - 1
    }

    func wholeColumns(in rects: [GridRect], rowCount: Int) -> IndexSet {
        columns.filteredIndexSet { position in
            rects.contains { rect in
                rect.columns.contains(position) && rect.rows.lowerBound <= 0 && rect.rows.upperBound >= rowCount - 1
            }
        }
    }

    /// A cursor left outside the selection would be drawn on a cell that is no longer selected, so
    /// it moves to the last rectangle, as the Cmd+click toggle has always done.
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
