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
    let booleanTrueText: NSColor?
    let booleanFalseText: NSColor?
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
        booleanTrueText: nil,
        booleanFalseText: nil,
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
            text: colors.dataGrid.text,
            placeholderText: colors.dataGrid.nullValue,
            booleanTrueText: colors.dataGrid.boolTrue,
            booleanFalseText: colors.dataGrid.boolFalse,
            rowNumberText: colors.dataGrid.rowNumber,
            deletedRowText: colors.dataGrid.deletedText,
            modifiedColumnTint: colors.dataGrid.modified,
            findMatchTint: .findHighlightColor
        )
    }
}
