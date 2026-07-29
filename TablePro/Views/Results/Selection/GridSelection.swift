import Foundation

struct GridSelection: Equatable {
    var rectangles: [GridRect]
    var activeCell: GridCoord?
    var anchor: GridCoord?

    static let empty = GridSelection(rectangles: [], activeCell: nil, anchor: nil)

    var isEmpty: Bool { rectangles.isEmpty }

    func contains(_ coord: GridCoord) -> Bool {
        rectangles.contains { $0.contains(coord) }
    }

    func contains(row: Int, column: Int) -> Bool {
        contains(GridCoord(row: row, column: column))
    }

    var affectedRows: IndexSet {
        var set = IndexSet()
        for rect in rectangles {
            set.insert(integersIn: rect.rows.lowerBound...rect.rows.upperBound)
        }
        return set
    }

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

    func union(_ other: GridSelection) -> GridSelection {
        GridSelection(
            rectangles: rectangles + other.rectangles,
            activeCell: other.activeCell ?? activeCell,
            anchor: other.anchor ?? anchor
        )
    }

    static func single(_ rect: GridRect, anchor: GridCoord, active: GridCoord) -> GridSelection {
        GridSelection(rectangles: [rect], activeCell: active, anchor: anchor)
    }
}
