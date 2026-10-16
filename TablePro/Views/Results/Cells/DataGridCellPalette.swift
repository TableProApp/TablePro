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
    let focusRing: NSColor

    init(
        regularFont: NSFont,
        italicFont: NSFont,
        mediumFont: NSFont,
        text: NSColor,
        placeholderText: NSColor,
        booleanTrueText: NSColor,
        booleanFalseText: NSColor,
        rowNumberText: NSColor,
        deletedRowText: NSColor,
        modifiedColumnTint: NSColor,
        findMatchTint: NSColor,
        findMatchText: NSColor = DataGridCellPalette.findMatchTextColor,
        selectionText: NSColor = .alternateSelectedControlTextColor,
        focusRing: NSColor = .keyboardFocusIndicatorColor
    ) {
        self.regularFont = regularFont
        self.italicFont = italicFont
        self.mediumFont = mediumFont
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
        self.focusRing = focusRing
    }

    static let placeholder = DataGridCellPalette(
        regularFont: .systemFont(ofSize: NSFont.systemFontSize),
        italicFont: .systemFont(ofSize: NSFont.systemFontSize),
        mediumFont: .systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
        text: .labelColor,
        placeholderText: .secondaryLabelColor,
        booleanTrueText: .labelColor,
        booleanFalseText: .labelColor,
        rowNumberText: .secondaryLabelColor,
        deletedRowText: .secondaryLabelColor,
        modifiedColumnTint: .systemYellow,
        findMatchTint: .findHighlightColor
    )

    /// `NSTextFinder` draws its find indicator as a light bubble in every appearance, so the text on
    /// `findHighlightColor` is the light appearance's text color.
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
    /// The row-state tints are dynamic providers, which cost four times a catalog color on every
    /// fill and `CTLineDraw`, so they are resolved here once in the appearance the grid draws in.
    /// The catalog colors stay dynamic and resolve at draw time. Fonts are the user's typography,
    /// not the theme's, so every scope draws in the engine's.
    func dataGridCellPalette(
        in appearance: NSAppearance,
        fonts: DataGridFontCache = ThemeEngine.shared.dataGridFonts
    ) -> DataGridCellPalette {
        let resolved = resolved
        return DataGridCellPalette(
            regularFont: fonts.regular,
            italicFont: fonts.italic,
            mediumFont: fonts.medium,
            text: resolved[.gridText],
            placeholderText: resolved[.gridNullValue],
            booleanTrueText: resolved[.gridBoolTrue],
            booleanFalseText: resolved[.gridBoolFalse],
            rowNumberText: resolved[.gridRowNumber],
            deletedRowText: Self.resolvedTint(.gridDeletedText, of: resolved, in: appearance),
            modifiedColumnTint: Self.resolvedTint(.gridModified, of: resolved, in: appearance),
            findMatchTint: .findHighlightColor,
            selectionText: resolved[.gridSelectionText],
            focusRing: resolved[.gridFocusBorder]
        )
    }

    private static func resolvedTint(_ slot: ThemeSlot, of resolved: ResolvedTheme, in appearance: NSAppearance) -> NSColor {
        guard !resolved.isOverridden(slot) else { return resolved[slot] }
        return NSColor(cgColor: resolved.cgColor(slot, in: appearance)) ?? resolved[slot]
    }
}
