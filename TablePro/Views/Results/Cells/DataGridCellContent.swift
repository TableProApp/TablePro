//
//  DataGridCellContent.swift
//  TablePro
//

import Foundation

enum DataGridCellPlaceholder: Equatable {
    case null
    case empty
    case defaultMarker
}

struct DataGridCellContent {
    let displayText: String
    let rawValue: String?
    let placeholder: DataGridCellPlaceholder?
    let accessibilityLabel: String
}

struct DataGridCellState {
    let visualState: RowVisualState
    let isFocused: Bool
    let isEditable: Bool
    let isLargeDataset: Bool
    let row: Int
    let columnIndex: Int
}
