//
//  DataGridCellAppearance.swift
//  TablePro
//

import AppKit

// Every decision about one cell's look, kept apart from drawing so it is testable without a view.
@MainActor
struct DataGridCellAppearance: Equatable {
    let text: String
    let font: NSFont
    let textColor: NSColor
    let backgroundTint: NSColor?
    let textMark: DataGridCellTextMark?
    let accessory: DataGridCellAccessory
    let accessoryRole: DataGridCellAccessoryGlyph.Role?
    let accessoryColor: NSColor?
    let checkboxMark: DataGridCheckboxMark?
    let specialCharacterColor: NSColor?

    static func resolve(
        kind: DataGridCellKind,
        content: DataGridCellContent,
        state: DataGridCellState,
        palette: DataGridCellPalette,
        nullDisplayString: String,
        onEmphasizedSelection: Bool,
        checkboxMark: DataGridCheckboxMark? = nil,
        textTone: NSColor? = nil,
        revealsInvisibleCharacters: Bool = false
    ) -> DataGridCellAppearance {
        let deletedTextColor = state.visualState.isDeleted ? palette.deletedRowText : nil
        let font: NSFont
        let baseColor: NSColor

        switch content.placeholder {
        // A pending SQL expression is a value the server fills in on save, as a pending DEFAULT is, and shows its SQL.
        case .none where state.visualState.isExpression(columnIndex: state.columnIndex), .defaultMarker:
            font = palette.mediumFont
            baseColor = deletedTextColor ?? .systemBlue
        case .none:
            font = palette.regularFont
            baseColor = deletedTextColor ?? textTone ?? valueTextColor(kind: kind, rawValue: content.rawValue, palette: palette)
        case .null, .empty, .absent, .unloaded:
            font = palette.italicFont
            baseColor = deletedTextColor ?? palette.placeholderText
        }

        let findTint: NSColor? = state.isCurrentFindMatch ? palette.findMatchTint : nil
        let stateTint: NSColor?
        if state.visualState.isDeleted || state.visualState.isInserted {
            stateTint = nil
        } else if state.visualState.isModified(columnIndex: state.columnIndex)
            || state.visualState.isStruck(columnIndex: state.columnIndex) {
            stateTint = palette.modifiedColumnTint
        } else {
            stateTint = state.visualState.cellHighlightColor(forColumn: state.columnIndex)?.washColor
        }

        // The modified or highlight tint stands down on an emphasized selection; a find match keeps its highlight.
        let backgroundTint: NSColor?
        let textColor: NSColor
        if let findTint {
            backgroundTint = findTint
            textColor = palette.findMatchText
        } else if onEmphasizedSelection {
            backgroundTint = nil
            textColor = palette.selectionText
        } else {
            backgroundTint = stateTint
            textColor = baseColor
        }

        let accessory = DataGridCellAccessory.visible(for: kind, isEditable: state.isEditable, rawValue: content.rawValue)
        // The editor's orange, except over a fill of the cell's own, where it takes the text's color.
        let specialCharacterColor: NSColor? = revealsInvisibleCharacters && content.placeholder == nil && kind != .checkbox
            ? (findTint != nil || onEmphasizedSelection ? textColor : .systemOrange)
            : nil
        let accessoryRole = DataGridCellAccessoryGlyph.Role(
            accessory: accessory,
            isEmphasized: onEmphasizedSelection,
            isDisabled: state.visualState.isDeleted
        )
        return DataGridCellAppearance(
            text: kind == .checkbox ? "" : DataGridCellContent.resolvedDisplayText(
                content.displayText,
                placeholder: content.placeholder,
                nullDisplayString: nullDisplayString
            ),
            font: font,
            textColor: textColor,
            backgroundTint: backgroundTint,
            textMark: DataGridCellTextMark.resolve(state: state.visualState, columnIndex: state.columnIndex),
            accessory: accessory,
            accessoryRole: accessoryRole,
            accessoryColor: accessoryRole?.color(selectionText: palette.selectionText),
            checkboxMark: kind == .checkbox ? checkboxMark : nil,
            specialCharacterColor: specialCharacterColor
        )
    }

    private static func valueTextColor(
        kind: DataGridCellKind,
        rawValue: String?,
        palette: DataGridCellPalette
    ) -> NSColor {
        guard kind == .boolean, let rawValue, let isTrue = StoredBoolean.value(of: rawValue) else {
            return palette.text
        }
        return isTrue ? palette.booleanTrueText : palette.booleanFalseText
    }
}
