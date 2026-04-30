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
}
