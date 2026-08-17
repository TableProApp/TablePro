//
//  DataGridCellContent.swift
//  TablePro
//

import Foundation
import TableProPluginKit

enum DataGridCellPlaceholder: Equatable {
    case null
    case empty
    case defaultMarker
}

struct DataGridCellContent {
    let displayText: String
    let rawValue: String?
    let placeholder: DataGridCellPlaceholder?

    static func placeholder(for rawValue: PluginCellValue) -> DataGridCellPlaceholder? {
        switch rawValue {
        case .null:
            return .null
        case .text(let value):
            if value == "__DEFAULT__" { return .defaultMarker }
            return value.isEmpty ? .empty : nil
        case .bytes:
            return nil
        }
    }

    static func resolvedDisplayText(
        _ displayText: String,
        placeholder: DataGridCellPlaceholder?,
        isLargeDataset: Bool,
        nullDisplayString: String
    ) -> String {
        switch placeholder {
        case .none:
            return displayText
        case .null:
            return isLargeDataset ? "" : nullDisplayString
        case .empty:
            return isLargeDataset ? "" : String(localized: "Empty")
        case .defaultMarker:
            return isLargeDataset ? "" : String(localized: "DEFAULT")
        }
    }
}

struct DataGridCellState {
    let visualState: RowVisualState
    let isFocused: Bool
    let isEditable: Bool
    let isLargeDataset: Bool
    let row: Int
    let columnIndex: Int
}
