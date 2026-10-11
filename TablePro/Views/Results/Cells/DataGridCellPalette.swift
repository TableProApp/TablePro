//
//  DataGridCellPalette.swift
//  TablePro
//

import AppKit

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
}

extension ThemeEngine {
    var dataGridCellPalette: DataGridCellPalette {
        DataGridCellPalette(
            regularFont: dataGridFonts.regular,
            italicFont: dataGridFonts.italic,
            mediumFont: dataGridFonts.medium,
            text: resolved[.gridText],
            placeholderText: resolved[.gridNullValue],
            booleanTrueText: resolved[.gridBoolTrue],
            booleanFalseText: resolved[.gridBoolFalse],
            rowNumberText: resolved[.gridRowNumber],
            deletedRowText: resolved[.gridDeletedText],
            modifiedColumnTint: resolved[.gridModified],
            findMatchTint: .findHighlightColor
        )
    }
}
