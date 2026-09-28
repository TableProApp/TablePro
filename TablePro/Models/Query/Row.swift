//
//  Row.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum RowID: Hashable, Sendable {
    case existing(Int)
    case inserted(UUID)

    var isInserted: Bool {
        if case .inserted = self { return true }
        return false
    }
}

struct Row: Equatable, Sendable {
    var id: RowID
    var values: ContiguousArray<PluginCellValue>
    /// The columns this row has no field for, which only an engine that tells a missing field from
    /// NULL reports. Their values read `.null`.
    var absentColumns: Set<Int> = []

    func isAbsent(_ column: Int) -> Bool {
        absentColumns.contains(column)
    }

    subscript(column: Int) -> PluginCellValue {
        get { column >= 0 && column < values.count ? values[column] : .null }
        set {
            guard column >= 0, column < values.count else { return }
            values[column] = newValue
        }
    }
}
