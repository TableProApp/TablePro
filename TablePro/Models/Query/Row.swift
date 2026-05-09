//
//  Row.swift
//  TablePro
//

import Foundation

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
    var values: ContiguousArray<String?>

    subscript(column: Int) -> String? {
        get { column >= 0 && column < values.count ? values[column] : nil }
        set {
            guard column >= 0, column < values.count else { return }
            values[column] = newValue
        }
    }
}
