//
//  DataGridCellPalette.swift
//  TablePro
//

import AppKit
import TableProTheme

@MainActor
struct DataGridCellPalette: Equatable {
    let regularFont: NSFont
    let italicFont: NSFont
    let mediumFont: NSFont
    let rowNumberFont: NSFont
    let text: NSColor
    let placeholderText: NSColor
    let booleanTrueText: NSColor
    let booleanFalseText: NSColor
    let rowNumberText: NSColor
    let deletedRowText: NSColor
    let modifiedColumnTint: NSColor
    let findMatchTint: NSColor
    let findMatchText: NSColor
    let selectionText: NSColor
    let focusBorder: NSColor

    init(
        regularFont: NSFont,
        italicFont: NSFont,
        mediumFont: NSFont,
        rowNumberFont: NSFont = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
        text: NSColor,
        placeholderText: NSColor,
        booleanTrueText: NSColor,
        booleanFalseText: NSColor,
        rowNumberText: NSColor,
        deletedRowText: NSColor,
        modifiedColumnTint: NSColor,
        findMatchTint: NSColor,
        findMatchText: NSColor = DataGridCellPalette.findMatchTextColor,
        selectionText: NSColor,
        focusBorder: NSColor
    ) {
        self.regularFont = regularFont
        self.italicFont = italicFont
        self.mediumFont = mediumFont
        self.rowNumberFont = rowNumberFont
        self.text = text
        self.placeholderText = placeholderText
        self.booleanTrueText = booleanTrueText
        self.booleanFalseText = booleanFalseText
        self.rowNumberText = rowNumberText
        self.deletedRowText = deletedRowText
        self.modifiedColumnTint = modifiedColumnTint
        self.findMatchTint = findMatchTint
        self.findMatchText = findMatchText
        self.selectionText = selectionText
        self.focusBorder = focusBorder
    }

    // NSTextFinder draws its find indicator as a light bubble in every appearance, so the text on it is light-appearance text.
    static let findMatchTextColor: NSColor = {
        var color = NSColor.textColor
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            color = NSColor(cgColor: NSColor.textColor.cgColor) ?? .textColor
        }
        return color
    }()

    func rowNumberColor(for visualState: RowVisualState, onEmphasizedSelection: Bool) -> NSColor {
        if onEmphasizedSelection { return selectionText }
        return visualState.isDeleted ? deletedRowText : rowNumberText
    }
}

extension ThemeScope {
    // The row-state tints are dynamic providers that cost four times a catalog color per fill, so they resolve once here.
    func dataGridCellPalette(
        in appearance: NSAppearance,
        fonts: DataGridFontCache = ThemeEngine.shared.dataGridFonts
    ) -> DataGridCellPalette {
        let resolved = resolved
        return DataGridCellPalette(
            regularFont: fonts.regular,
            italicFont: fonts.italic,
            mediumFont: fonts.medium,
            rowNumberFont: fonts.rowNumber,
            text: resolved[.gridText],
            placeholderText: resolved[.gridNullValue],
            booleanTrueText: resolved[.gridBoolTrue],
            booleanFalseText: resolved[.gridBoolFalse],
            rowNumberText: resolved[.gridRowNumber],
            deletedRowText: Self.resolvedTint(.gridDeletedText, of: resolved, in: appearance),
            modifiedColumnTint: Self.resolvedTint(.gridModified, of: resolved, in: appearance),
            findMatchTint: .findHighlightColor,
            selectionText: resolved[.gridSelectionText],
            focusBorder: resolved[.gridFocusBorder]
        )
    }

    private static func resolvedTint(_ slot: ThemeSlot, of resolved: ResolvedTheme, in appearance: NSAppearance) -> NSColor {
        guard !resolved.isOverridden(slot) else { return resolved[slot] }
        return NSColor(cgColor: resolved.cgColor(slot, in: appearance)) ?? resolved[slot]
    }
}
