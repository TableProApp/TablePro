import Foundation

struct TableSelection: Equatable {
    var focusedRow: Int = -1
    var focusedColumn: Int = -1
    var cellSelection: CellSelection = .none

    func reloadIndexes(from previous: TableSelection) -> (rows: IndexSet, columns: IndexSet)? {
        let focusChanged = previous.focusedRow != focusedRow || previous.focusedColumn != focusedColumn
        let cellSelectionChanged = previous.cellSelection != cellSelection

        guard focusChanged || cellSelectionChanged else { return nil }

        var rows = IndexSet()
        var columns = IndexSet()

        if previous.focusedRow >= 0 { rows.insert(previous.focusedRow) }
        if previous.focusedColumn >= 0 { columns.insert(previous.focusedColumn) }
        if focusedRow >= 0 { rows.insert(focusedRow) }
        if focusedColumn >= 0 { columns.insert(focusedColumn) }

        if cellSelectionChanged {
            rows.formUnion(previous.cellSelection.affectedRows)
            rows.formUnion(cellSelection.affectedRows)
            columns.formUnion(previous.cellSelection.affectedColumns)
            columns.formUnion(cellSelection.affectedColumns)
        }

        guard !rows.isEmpty, !columns.isEmpty else { return nil }
        return (rows, columns)
    }
}
