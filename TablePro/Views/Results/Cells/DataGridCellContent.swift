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
    /// The row has no field for the column, which a document store tells apart from NULL.
    case absent
}

struct DataGridCellContent {
    let displayText: String
    let rawValue: String?
    let placeholder: DataGridCellPlaceholder?

    static func placeholder(for rawValue: PluginCellValue, isAbsent: Bool = false) -> DataGridCellPlaceholder? {
        guard !isAbsent else { return .absent }
        switch rawValue {
        case .null:
            return .null
        case .text(let value):
            if value == PluginCellValue.defaultMarkerText { return .defaultMarker }
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
        case .absent:
            return isLargeDataset ? "" : absentFieldText
        }
    }

    static var absentFieldText: String {
        String(localized: "No Field")
    }
}

struct DataGridCellState {
    let visualState: RowVisualState
    let isFocused: Bool
    let isEditable: Bool
    let isLargeDataset: Bool
    let isCurrentFindMatch: Bool
    let row: Int
    let columnIndex: Int

    init(
        visualState: RowVisualState,
        isFocused: Bool,
        isEditable: Bool,
        isLargeDataset: Bool,
        isCurrentFindMatch: Bool = false,
        row: Int,
        columnIndex: Int
    ) {
        self.visualState = visualState
        self.isFocused = isFocused
        self.isEditable = isEditable
        self.isLargeDataset = isLargeDataset
        self.isCurrentFindMatch = isCurrentFindMatch
        self.row = row
        self.columnIndex = columnIndex
    }
}
