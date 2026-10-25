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
    // The row has no field for the column, which a document store tells apart from NULL.
    case absent
    case unloaded(byteCount: Int)
}

struct DataGridCellContent {
    let displayText: String
    let rawValue: String?
    let placeholder: DataGridCellPlaceholder?

    static func placeholder(
        for rawValue: PluginCellValue,
        isAbsent: Bool = false,
        unloadedByteCount: Int? = nil
    ) -> DataGridCellPlaceholder? {
        if let unloadedByteCount { return .unloaded(byteCount: unloadedByteCount) }
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
        nullDisplayString: String
    ) -> String {
        switch placeholder {
        case .none:
            return displayText
        case .null:
            return nullDisplayString
        case .empty:
            return String(localized: "Empty")
        case .defaultMarker:
            return String(localized: "DEFAULT")
        case .absent:
            return absentFieldText
        case .unloaded(let byteCount):
            return unloadedText(byteCount: byteCount)
        }
    }

    static var absentFieldText: String {
        String(localized: "No Field")
    }

    static func unloadedText(byteCount: Int) -> String {
        UnloadedValueText.size(byteCount: byteCount)
    }

    static func unloadedSpokenText(byteCount: Int) -> String {
        UnloadedValueText.notLoaded(byteCount: byteCount)
    }
}

struct DataGridCellState {
    let visualState: RowVisualState
    let isEditable: Bool
    let isCurrentFindMatch: Bool
    let row: Int
    let columnIndex: Int

    init(
        visualState: RowVisualState,
        isEditable: Bool,
        isCurrentFindMatch: Bool = false,
        row: Int,
        columnIndex: Int
    ) {
        self.visualState = visualState
        self.isEditable = isEditable
        self.isCurrentFindMatch = isCurrentFindMatch
        self.row = row
        self.columnIndex = columnIndex
    }
}
