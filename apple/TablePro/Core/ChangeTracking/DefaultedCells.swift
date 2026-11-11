//
//  DefaultedCells.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// The cells a pending insert or edit set to the column's default, by row and data index. Only those rows can hold one.
enum DefaultedCells {
    static func marked(
        in rows: TableRows,
        rowIDs: Set<RowID>,
        expressionColumns: (RowID) -> Set<Int>
    ) -> [RowID: Set<Int>] {
        var cells: [RowID: Set<Int>] = [:]
        for rowID in rowIDs {
            guard let row = rows.row(withID: rowID) else { continue }
            let defaulted = expressionColumns(rowID).filter {
                row.values.indices.contains($0) && row.values[$0].isColumnDefault(isExpression: true)
            }
            if !defaulted.isEmpty { cells[rowID] = defaulted }
        }
        return cells
    }
}

extension ChangeManaging {
    func defaultedCells(in rows: TableRows) -> [RowID: Set<Int>] {
        DefaultedCells.marked(in: rows, rowIDs: insertedRowIDs.union(modifiedCells.keys)) { expressionColumns(forRow: $0) }
    }
}

extension AnyChangeManager {
    func defaultedCells(in rows: TableRows) -> [RowID: Set<Int>] {
        DefaultedCells.marked(in: rows, rowIDs: insertedRowIDs.union(modifiedCells.keys)) { expressionColumns(forRow: $0) }
    }
}
