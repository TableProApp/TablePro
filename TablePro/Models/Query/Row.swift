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

    subscript(column: Int) -> PluginCellValue {
        get { column >= 0 && column < values.count ? values[column] : .null }
        set {
            guard column >= 0, column < values.count else { return }
            values[column] = newValue
        }
    }
}
