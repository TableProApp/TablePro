//
//  DataGridCellAppearanceTests.swift
//  TableProTests
//
//  The grid draws its cells rather than mounting one view per cell, so what a cell looks like is
//  decided here rather than by a view configuring itself. These are the decisions: which font a
//  placeholder takes, when a tint survives, what colour text turns on a selected row.
//

import AppKit
import Testing

@testable import TablePro

@Suite("Data grid cell appearance")
@MainActor
struct DataGridCellAppearanceTests {
    private let palette = DataGridCellPalette(
        regularFont: .systemFont(ofSize: 13),
        italicFont: .systemFont(ofSize: 13),
        mediumFont: .systemFont(ofSize: 13, weight: .medium),
        text: .labelColor,
        placeholderText: .secondaryLabelColor,
        booleanTrueText: .labelColor,
        booleanFalseText: .labelColor,
        rowNumberText: .secondaryLabelColor,
        deletedRowText: .systemRed,
        modifiedColumnTint: .systemYellow,
        findMatchTint: .systemOrange
    )

    private let themedPalette = DataGridCellPalette(
        regularFont: .systemFont(ofSize: 13),
        italicFont: .systemFont(ofSize: 13),
        mediumFont: .systemFont(ofSize: 13, weight: .medium),
        text: .systemPurple,
        placeholderText: .systemBrown,
        booleanTrueText: .systemGreen,
        booleanFalseText: .systemPink,
        rowNumberText: .systemTeal,
        deletedRowText: .systemRed,
        modifiedColumnTint: .systemYellow,
        findMatchTint: .systemOrange
    )

    private func resolve(
        kind: DataGridCellKind = .text,
        text: String = "value",
        rawValue: String? = "value",
        placeholder: DataGridCellPlaceholder? = nil,
        visualState: RowVisualState = .empty,
        isFocused: Bool = false,
        isEditable: Bool = true,
        isLargeDataset: Bool = false,
        isCurrentFindMatch: Bool = false,
        columnIndex: Int = 0,
        onEmphasizedSelection: Bool = false,
        hasOverlay: Bool = false,
        palette: DataGridCellPalette? = nil
    ) -> DataGridCellAppearance {
        DataGridCellAppearance.resolve(
            kind: kind,
            content: DataGridCellContent(displayText: text, rawValue: rawValue, placeholder: placeholder),
            state: DataGridCellState(
                visualState: visualState,
                isFocused: isFocused,
                isEditable: isEditable,
                isLargeDataset: isLargeDataset,
                isCurrentFindMatch: isCurrentFindMatch,
                row: 0,
                columnIndex: columnIndex
            ),
            palette: palette ?? self.palette,
            nullDisplayString: "NULL",
            onEmphasizedSelection: onEmphasizedSelection,
            hasOverlay: hasOverlay
        )
    }

    @Test("An ordinary value draws in the regular font at the label colour")
    func ordinaryValue() {
        let appearance = resolve()

        #expect(appearance.text == "value")
        #expect(appearance.font == palette.regularFont)
        #expect(appearance.textColor == .labelColor)
        #expect(appearance.backgroundTint == nil)
    }

    @Test("NULL and empty draw in the italic font as secondary text")
    func placeholdersAreItalic() {
        let null = resolve(text: "", placeholder: .null)
        let empty = resolve(text: "", placeholder: .empty)

        #expect(null.font == palette.italicFont)
        #expect(null.textColor == .secondaryLabelColor)
        #expect(null.text == "NULL")
        #expect(empty.font == palette.italicFont)
    }

    @Test("A server default draws in the medium font, tinted")
    func defaultMarker() {
        let appearance = resolve(text: "", placeholder: .defaultMarker)

        #expect(appearance.font == palette.mediumFont)
        #expect(appearance.textColor == .systemBlue)
    }

    /// A large result blanks its placeholders rather than formatting every one of them.
    @Test("A large result draws no placeholder text")
    func largeDatasetBlanksPlaceholders() {
        #expect(resolve(text: "", placeholder: .null, isLargeDataset: true).text.isEmpty)
        #expect(resolve(text: "", placeholder: .empty, isLargeDataset: true).text.isEmpty)
    }

    @Test("A deleted row recolours its text and keeps no modified tint")
    func deletedRow() {
        let appearance = resolve(visualState: RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: []), columnIndex: 0)

        #expect(appearance.textColor == palette.deletedRowText)
        #expect(appearance.backgroundTint == nil)
    }

    @Test("The find match keeps its highlight and turns its text black")
    func findMatchWins() {
        let appearance = resolve(isCurrentFindMatch: true, onEmphasizedSelection: true)

        #expect(appearance.backgroundTint == palette.findMatchTint)
        #expect(appearance.textColor == .black)
    }

    /// The selection paints the whole row, so a modified cell's tint would be painted over it.
    @Test("A selected row drops the modified tint and takes the selection's text colour")
    func selectionSuppressesTheModifiedTint() {
        let unselected = resolve(visualState: RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [0]), columnIndex: 0)
        let selected = resolve(visualState: RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [0]), columnIndex: 0, onEmphasizedSelection: true)

        #expect(unselected.backgroundTint == palette.modifiedColumnTint)
        #expect(selected.backgroundTint == nil)
        #expect(selected.textColor == .alternateSelectedControlTextColor)
    }

    @Test("Only the modified column carries the tint")
    func onlyTheModifiedColumnIsTinted() {
        #expect(resolve(visualState: RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [2]), columnIndex: 2).backgroundTint != nil)
        #expect(resolve(visualState: RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [2]), columnIndex: 3).backgroundTint == nil)
    }

    // MARK: - The cell cursor

    /// A mounted cell got its ring from AppKit. A drawn cell has no view to hang one on, so the
    /// appearance has to say which of the two shapes to draw.
    @Test("The cell cursor draws a ring on an unselected row and a border on a selected one")
    func cursorShape() {
        let unselected = resolve(isFocused: true)
        let selected = resolve(isFocused: true, onEmphasizedSelection: true)

        #expect(unselected.drawsFocusRing)
        #expect(!unselected.drawsFocusBorder)
        #expect(selected.drawsFocusBorder)
        #expect(!selected.drawsFocusRing)
    }

    @Test("An open editor hides the cell cursor behind it")
    func overlayHidesTheCursor() {
        let appearance = resolve(isFocused: true, hasOverlay: true)

        #expect(!appearance.drawsFocusRing)
        #expect(!appearance.drawsFocusBorder)
    }

    @Test("An unfocused cell draws no cursor")
    func unfocusedDrawsNothing() {
        let appearance = resolve()

        #expect(!appearance.drawsFocusRing)
        #expect(!appearance.drawsFocusBorder)
    }

    // MARK: - Accessories

    @Test("A foreign key with a value gets the arrow, an empty one gets nothing")
    func foreignKeyAccessory() {
        #expect(resolve(kind: .foreignKey, rawValue: "42").accessory == .foreignKey)
        #expect(resolve(kind: .foreignKey, rawValue: "").accessory == .none)
        #expect(resolve(kind: .foreignKey, rawValue: nil).accessory == .none)
    }

    @Test("The accessory symbol follows the row's state")
    func accessoryRoleFollowsState() {
        #expect(resolve(kind: .foreignKey, rawValue: "42").accessoryRole == .foreignKeyNormal)
        #expect(
            resolve(kind: .foreignKey, rawValue: "42", onEmphasizedSelection: true).accessoryRole
                == .foreignKeyEmphasized
        )
    }

    @Test("A cell with no accessory resolves no symbol")
    func noAccessoryNoRole() {
        #expect(resolve().accessoryRole == nil)
    }

    // MARK: - Highlight rules

    private func highlighted(
        column: Int,
        color: HighlightColor = .green,
        isDeleted: Bool = false,
        isInserted: Bool = false,
        modifiedColumns: Set<Int> = []
    ) -> RowVisualState {
        let rule = HighlightRule(columnName: "status", value: "paid", color: color, target: .cell)
        return RowVisualState(
            isDeleted: isDeleted,
            isInserted: isInserted,
            modifiedColumns: modifiedColumns,
            highlight: RowHighlight(rowRule: nil, cellRules: [column: rule])
        )
    }

    @Test("A cell a highlight rule matches takes the rule's wash")
    func highlightedCellTakesTheWash() {
        let appearance = resolve(visualState: highlighted(column: 1), columnIndex: 1)

        #expect(appearance.backgroundTint == HighlightColor.green.washColor)
        #expect(resolve(visualState: highlighted(column: 1), columnIndex: 2).backgroundTint == nil)
    }

    @Test("A modified cell keeps the modified tint over a highlight")
    func modifiedTintOutranksHighlight() {
        let appearance = resolve(visualState: highlighted(column: 0, modifiedColumns: [0]), columnIndex: 0)

        #expect(appearance.backgroundTint == palette.modifiedColumnTint)
    }

    @Test("A find match and a selection both outrank a highlight")
    func findAndSelectionOutrankHighlight() {
        let found = resolve(visualState: highlighted(column: 0), isCurrentFindMatch: true, columnIndex: 0)
        let selected = resolve(visualState: highlighted(column: 0), columnIndex: 0, onEmphasizedSelection: true)

        #expect(found.backgroundTint == palette.findMatchTint)
        #expect(selected.backgroundTint == nil)
    }

    @Test("A pending insert or delete shows no cell highlight, so it cannot pass for one")
    func pendingRowsShowNoCellHighlight() {
        let inserted = resolve(visualState: highlighted(column: 0, isInserted: true), columnIndex: 0)
        let deleted = resolve(visualState: highlighted(column: 0, isDeleted: true), columnIndex: 0)

        #expect(inserted.backgroundTint == nil)
        #expect(deleted.backgroundTint == nil)
    }

    @Test("Only a highlight that is drawn is named to VoiceOver")
    func drawnHighlightRule() {
        let rowRule = HighlightRule(columnName: "status", value: "paid", color: .green)
        let cellRule = HighlightRule(columnName: "total", value: "9", color: .red, target: .cell)
        let highlight = RowHighlight(rowRule: rowRule, cellRules: [1: cellRule])
        let plain = RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [], highlight: highlight)
        let modified = RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [1], highlight: highlight)
        let deleted = RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: [], highlight: highlight)

        #expect(plain.drawnHighlightRule(forColumn: 1) == cellRule)
        #expect(plain.drawnHighlightRule(forColumn: 0) == rowRule)
        #expect(modified.drawnHighlightRule(forColumn: 1) == rowRule)
        #expect(deleted.drawnHighlightRule(forColumn: 1) == nil)
    }

    // MARK: - Theme colors

    @Test("A value takes the theme's text color, a placeholder its NULL color")
    func themeTextAndPlaceholderColors() {
        let value = resolve(palette: themedPalette)
        let null = resolve(text: "", rawValue: nil, placeholder: .null, palette: themedPalette)
        let empty = resolve(text: "", rawValue: "", placeholder: .empty, palette: themedPalette)

        #expect(value.textColor == .systemPurple)
        #expect(null.textColor == .systemBrown)
        #expect(empty.textColor == .systemBrown)
    }

    @Test("A boolean cell takes the theme's true or false color", arguments: [
        ("true", NSColor.systemGreen), ("1", .systemGreen), ("t", .systemGreen),
        ("false", .systemPink), ("0", .systemPink), ("f", .systemPink),
    ])
    func booleanColors(raw: String, expected: NSColor) {
        let appearance = resolve(kind: .boolean, text: raw, rawValue: raw, palette: themedPalette)

        #expect(appearance.textColor == expected)
    }

    @Test("A boolean color stays off text columns and unreadable values")
    func booleanColorNeedsABooleanValue() {
        let textColumn = resolve(kind: .text, text: "true", rawValue: "true", palette: themedPalette)
        let unreadable = resolve(kind: .boolean, text: "maybe", rawValue: "maybe", palette: themedPalette)

        #expect(textColumn.textColor == .systemPurple)
        #expect(unreadable.textColor == .systemPurple)
    }

    @Test("A theme without boolean colors draws booleans as plain text")
    func booleanFallsBackToText() {
        let appearance = resolve(kind: .boolean, text: "true", rawValue: "true")

        #expect(appearance.textColor == .labelColor)
    }

    @Test("Selection, deletion and a find match outrank the boolean color")
    func booleanColorYieldsToState() {
        let selected = resolve(kind: .boolean, text: "1", rawValue: "1", onEmphasizedSelection: true, palette: themedPalette)
        let deleted = resolve(
            kind: .boolean,
            text: "1",
            rawValue: "1",
            visualState: RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: []),
            palette: themedPalette
        )
        let found = resolve(kind: .boolean, text: "1", rawValue: "1", isCurrentFindMatch: true, palette: themedPalette)

        #expect(selected.textColor == .alternateSelectedControlTextColor)
        #expect(deleted.textColor == .systemRed)
        #expect(found.textColor == .black)
    }
}
