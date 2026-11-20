//
//  DataGridValueEditor.swift
//  TablePro
//

import Foundation

enum DataGridChevronEditor: Equatable {
    case dropdown
    case typePicker
    case boolean
    case array
    case vector
    case set
    case enumeration
    case json
    case blob
    case datePicker
    case inlineText
}

enum DataGridValueEditor: Equatable {
    case chevron(DataGridChevronEditor)
    case mode(CellInteractionMode)
    case jsonViewer
    case unloaded(edits: Bool)

    var edits: Bool {
        switch self {
        case .chevron:
            return true
        case .jsonViewer:
            return false
        case .unloaded(let edits):
            return edits
        case .mode(let mode):
            switch mode {
            case .editInline, .editText, .editForeignKey, .editJson, .editBlob, .editSvg, .editVector:
                return true
            case .viewText, .viewJson, .viewBlob, .viewPhpSerialized, .viewBinaryValue, .viewSvg, .viewVector, .blocked:
                return false
            }
        }
    }

    // nil where a cell opens nothing beyond its inline field. `chevron` is nil on a cell the grid cannot write.
    static func resolve(
        mode: CellInteractionMode,
        chevron: DataGridChevronEditor?,
        isJsonColumn: Bool,
        isNull: Bool,
        isUnloaded: Bool,
        isWritable: Bool,
        isCheckbox: Bool
    ) -> DataGridValueEditor? {
        guard !isCheckbox, mode != .blocked else { return nil }
        if isUnloaded { return .unloaded(edits: isWritable) }
        let editor = loaded(mode: mode, chevron: chevron, isJsonColumn: isJsonColumn)
        // A NULL has nothing to view; an editor is still how a value gets into it.
        if isNull, editor?.edits == false { return nil }
        return editor
    }

    private static func loaded(
        mode: CellInteractionMode,
        chevron: DataGridChevronEditor?,
        isJsonColumn: Bool
    ) -> DataGridValueEditor? {
        switch mode {
        case .viewJson, .editJson, .viewBlob, .editBlob, .viewPhpSerialized, .viewBinaryValue,
             .viewSvg, .editSvg, .viewVector, .editVector:
            // Ahead of the chevron, which follows the column type and would drop a Display As choice.
            return .mode(mode)
        case .viewText, .editInline, .editText, .editForeignKey:
            if let chevron, chevron != .inlineText { return .chevron(chevron) }
            if isJsonColumn { return .jsonViewer }
            return longText(mode)
        case .blocked:
            return nil
        }
    }

    private static func longText(_ mode: CellInteractionMode) -> DataGridValueEditor? {
        switch mode {
        case .editText:
            return .mode(mode)
        case .viewText(let value):
            return CellInteractionResolver.editsInPopover(value) ? .mode(mode) : nil
        default:
            return nil
        }
    }
}
