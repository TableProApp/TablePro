//
//  DataGridCellAppearance.swift
//  TablePro
//

import AppKit

/// What one data cell looks like, resolved from its content and state.
///
/// Separated from the drawing so the decisions are testable without a view and without a graphics
/// context: which font a NULL takes, when a modified cell keeps its tint, what colour text turns on
/// a selected row. The renderer that consumes this makes no decisions of its own.
@MainActor
struct DataGridCellAppearance: Equatable {
    let text: String
    let font: NSFont
    let textColor: NSColor
    /// Painted behind the text, for a find match, a modified value or a highlight rule.
    let backgroundTint: NSColor?
    /// The line a pending change draws through or under the text. Unlike the tint, it survives a
    /// selection, which is what makes it the cue rather than a decoration on one.
    let textMark: DataGridCellTextMark?
    let accessory: DataGridCellAccessory
    /// Which symbol the accessory draws, resolved here because it follows the row's state rather
    /// than anything the renderer can see.
    let accessoryRole: DataGridCellAccessoryGlyph.Role?
    let accessoryColor: NSColor?
    /// The cell cursor on a selected row, which the selection fill would swallow a focus ring behind.
    let drawsFocusBorder: Bool
    /// The cell cursor on an unselected row.
    let drawsFocusRing: Bool
    let focusColor: NSColor
    let checkboxMark: DataGridCheckboxMark?
    /// Nil leaves invisible characters unmarked.
    let specialCharacterColor: NSColor?

    static func resolve(
        kind: DataGridCellKind,
        content: DataGridCellContent,
        state: DataGridCellState,
        palette: DataGridCellPalette,
        nullDisplayString: String,
        onEmphasizedSelection: Bool,
        hasOverlay: Bool,
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
        let highlightColor = state.visualState.cellHighlightColor(forColumn: state.columnIndex)
        let stateTint: NSColor?
        if state.visualState.isDeleted || state.visualState.isInserted {
            stateTint = nil
        } else if state.visualState.isModified(columnIndex: state.columnIndex)
            || state.visualState.isStruck(columnIndex: state.columnIndex) {
            stateTint = palette.modifiedColumnTint
        } else {
            stateTint = highlightColor?.washColor
        }

        // The modified or highlight tint stands down on a selected row so the selection fill is
        // not painted over; a find match keeps its own highlight whatever else is true.
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

        let accessory = DataGridCellAccessory.visible(
            for: kind,
            isEditable: state.isEditable,
            rawValue: content.rawValue
        )
        let isCursorVisible = state.isFocused && !hasOverlay
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
                isLargeDataset: state.isLargeDataset,
                nullDisplayString: nullDisplayString
            ),
            font: font,
            textColor: textColor,
            backgroundTint: backgroundTint,
            textMark: DataGridCellTextMark.resolve(state: state.visualState, columnIndex: state.columnIndex),
            accessory: accessory,
            accessoryRole: accessoryRole,
            accessoryColor: accessoryRole?.color(selectionText: palette.selectionText),
            drawsFocusBorder: isCursorVisible && onEmphasizedSelection,
            drawsFocusRing: isCursorVisible && !onEmphasizedSelection,
            focusColor: onEmphasizedSelection ? palette.selectionText : palette.focusRing,
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
