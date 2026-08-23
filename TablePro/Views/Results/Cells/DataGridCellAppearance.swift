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
    /// Painted behind the text, for a find match or a modified value.
    let backgroundTint: NSColor?
    let accessory: DataGridCellAccessory
    /// Which symbol the accessory draws, resolved here because it follows the row's state rather
    /// than anything the renderer can see.
    let accessoryRole: DataGridCellAccessoryGlyph.Role?
    /// The cell cursor on a selected row, which the selection fill would swallow a focus ring behind.
    let drawsFocusBorder: Bool
    /// The cell cursor on an unselected row.
    let drawsFocusRing: Bool

    static func resolve(
        kind: DataGridCellKind,
        content: DataGridCellContent,
        state: DataGridCellState,
        palette: DataGridCellPalette,
        nullDisplayString: String,
        onEmphasizedSelection: Bool,
        hasOverlay: Bool
    ) -> DataGridCellAppearance {
        let deletedTextColor = state.visualState.isDeleted ? palette.deletedRowText : nil
        let font: NSFont
        let baseColor: NSColor

        switch content.placeholder {
        case .none:
            font = palette.regularFont
            baseColor = deletedTextColor ?? .labelColor
        case .null, .empty:
            font = palette.italicFont
            baseColor = deletedTextColor ?? .secondaryLabelColor
        case .defaultMarker:
            font = palette.mediumFont
            baseColor = deletedTextColor ?? .systemBlue
        }

        let findTint: NSColor? = state.isCurrentFindMatch ? palette.findMatchTint : nil
        let modifiedTint: NSColor?
        if state.visualState.isDeleted || state.visualState.isInserted {
            modifiedTint = nil
        } else if state.visualState.isModified(columnIndex: state.columnIndex) {
            modifiedTint = palette.modifiedColumnTint
        } else {
            modifiedTint = nil
        }

        // A find match keeps its own highlight whatever else is true, and the text turns black
        // against it. Otherwise a selected row's text takes the selection's own colour, and the
        // modified tint stands down so the selection fill is not painted over.
        let backgroundTint: NSColor?
        let textColor: NSColor
        if let findTint {
            backgroundTint = findTint
            textColor = .black
        } else if onEmphasizedSelection {
            backgroundTint = nil
            textColor = .alternateSelectedControlTextColor
        } else {
            backgroundTint = modifiedTint
            textColor = baseColor
        }

        let accessory = DataGridCellAccessory.visible(
            for: kind,
            isEditable: state.isEditable,
            rawValue: content.rawValue
        )
        let isCursorVisible = state.isFocused && !hasOverlay
        return DataGridCellAppearance(
            text: DataGridCellContent.resolvedDisplayText(
                content.displayText,
                placeholder: content.placeholder,
                isLargeDataset: state.isLargeDataset,
                nullDisplayString: nullDisplayString
            ),
            font: font,
            textColor: textColor,
            backgroundTint: backgroundTint,
            accessory: accessory,
            accessoryRole: DataGridCellAccessoryGlyph.Role(
                accessory: accessory,
                isEmphasized: onEmphasizedSelection,
                isDisabled: state.visualState.isDeleted
            ),
            drawsFocusBorder: isCursorVisible && onEmphasizedSelection,
            drawsFocusRing: isCursorVisible && !onEmphasizedSelection
        )
    }
}
