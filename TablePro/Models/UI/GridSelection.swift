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
    /// swept block's own outline, and armed the CSV inspector's Delete Column on every column of
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
        return GridSelection(
            rectangles: fitted,
            activeCell: fit(activeCell),
            anchor: fit(anchor),
            columns: columns.filteredIndexSet { $0 >= 0 && $0 < columnLimit }
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
