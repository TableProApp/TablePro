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
        hasOverlay: Bool = false
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
            palette: palette,
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
}
