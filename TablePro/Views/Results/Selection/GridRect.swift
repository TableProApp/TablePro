import Foundation

struct GridRect: Hashable {
    var rows: ClosedRange<Int>
    var columns: ClosedRange<Int>

    init(rows: ClosedRange<Int>, columns: ClosedRange<Int>) {
        self.rows = rows
        self.columns = columns
    }

    init(cell: GridCoord) {
        self.rows = cell.row...cell.row
        self.columns = cell.column...cell.column
    }

    static func between(_ a: GridCoord, _ b: GridCoord) -> GridRect {
        GridRect(
            rows: min(a.row, b.row)...max(a.row, b.row),
            columns: min(a.column, b.column)...max(a.column, b.column)
        )
    }

    func contains(_ coord: GridCoord) -> Bool {
        rows.contains(coord.row) && columns.contains(coord.column)
    }

    func clamped(rowLimit: Int, columnLimit: Int) -> GridRect? {
        guard rowLimit > 0, columnLimit > 0 else { return nil }
        let rLow = max(0, rows.lowerBound)
        let rHigh = min(rowLimit - 1, rows.upperBound)
        let cLow = max(0, columns.lowerBound)
        let cHigh = min(columnLimit - 1, columns.upperBound)
        guard rLow <= rHigh, cLow <= cHigh else { return nil }
        return GridRect(rows: rLow...rHigh, columns: cLow...cHigh)
    }
}
