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
    let deletedRowText: NSColor
    let modifiedColumnTint: NSColor

    static let placeholder = DataGridCellPalette(
        regularFont: .systemFont(ofSize: NSFont.systemFontSize),
        italicFont: .systemFont(ofSize: NSFont.systemFontSize),
        mediumFont: .systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
        deletedRowText: .secondaryLabelColor,
        modifiedColumnTint: .systemYellow
    )
}

extension ThemeEngine {
    var dataGridCellPalette: DataGridCellPalette {
        DataGridCellPalette(
            regularFont: dataGridFonts.regular,
            italicFont: dataGridFonts.italic,
            mediumFont: dataGridFonts.medium,
            deletedRowText: colors.dataGrid.deletedText,
            modifiedColumnTint: colors.dataGrid.modified
        )
    }
}
