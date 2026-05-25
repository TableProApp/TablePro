//
//  DataGridCellKind.swift
//  TablePro
//

import Foundation

enum DataGridCellKind: Equatable {
    case text
    case foreignKey
    case dropdown
    case boolean
    case json
    case blob
    case date

    var showsChevron: Bool {
        switch self {
        case .dropdown, .boolean, .json, .blob, .date:
            return true
        case .text, .foreignKey:
            return false
        }
    }
}
