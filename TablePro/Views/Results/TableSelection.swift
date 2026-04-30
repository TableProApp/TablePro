import Foundation

struct TableSelection: Equatable {
    var focusedRow: Int = -1
    var focusedColumn: Int = -1

    var hasFocus: Bool { focusedRow >= 0 && focusedColumn >= 0 }

    static let empty = TableSelection()

    mutating func clearFocus() {
        focusedRow = -1
        focusedColumn = -1
    }

    mutating func setFocus(row: Int, column: Int) {
        focusedRow = row
        focusedColumn = column
    }

    func reloadIndexes(from previous: TableSelection) -> (rows: IndexSet, columns: IndexSet)? {
        guard previous.focusedRow != focusedRow || previous.focusedColumn != focusedColumn else {
            return nil
        }

        var rows = IndexSet()
        var columns = IndexSet()

        if previous.focusedRow >= 0 { rows.insert(previous.focusedRow) }
        if previous.focusedColumn >= 0 { columns.insert(previous.focusedColumn) }
        if focusedRow >= 0 { rows.insert(focusedRow) }
        if focusedColumn >= 0 { columns.insert(focusedColumn) }

        guard !rows.isEmpty, !columns.isEmpty else { return nil }
        return (rows, columns)
    }
}
