//
//  Delta.swift
//  TablePro
//

import Foundation

enum Delta: Equatable {
    case cellChanged(row: Int, column: Int)
    case cellsChanged(Set<CellPosition>)
    case rowsInserted(IndexSet)
    case rowsRemoved(IndexSet)
    case columnsReplaced
    case fullReplace

    static let none = Delta.cellsChanged([])

    var changesRowSet: Bool {
        switch self {
        case .rowsInserted(let indices), .rowsRemoved(let indices):
            return !indices.isEmpty
        case .fullReplace:
            return true
        case .cellChanged, .cellsChanged, .columnsReplaced:
            return false
        }
    }
}
