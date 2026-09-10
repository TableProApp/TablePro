import Foundation

/// A rectangle of cells. Its column axis is display positions, so a sweep names the block the user
/// actually crossed; see `GridCoord` and `DataGridView+ColumnDisplayOrder`.
struct GridRect: Hashable {
    var rows: ClosedRange<Int>
    var columns: ClosedRange<Int>

    init(rows: ClosedRange<Int>, columns: ClosedRange<Int>) {
        self.rows = rows
        self.columns = columns
    }

    init(cell: GridCoord) {
        self.rows = cell.row...cell.row
        self.columns = cell.displayColumn...cell.displayColumn
    }

    static func between(_ a: GridCoord, _ b: GridCoord) -> GridRect {
        GridRect(
            rows: min(a.row, b.row)...max(a.row, b.row),
            columns: min(a.displayColumn, b.displayColumn)...max(a.displayColumn, b.displayColumn)
        )
    }

    func contains(_ coord: GridCoord) -> Bool {
        rows.contains(coord.row) && columns.contains(coord.displayColumn)
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
