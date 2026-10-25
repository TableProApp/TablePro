//
//  DataGridCellAppearanceTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

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
        isEditable: Bool = true,
        isCurrentFindMatch: Bool = false,
        columnIndex: Int = 0,
        onEmphasizedSelection: Bool = false,
        checkboxMark: DataGridCheckboxMark? = nil,
        textTone: NSColor? = nil,
        palette: DataGridCellPalette? = nil
    ) -> DataGridCellAppearance {
        DataGridCellAppearance.resolve(
            kind: kind,
            content: DataGridCellContent(displayText: text, rawValue: rawValue, placeholder: placeholder),
            state: DataGridCellState(
                visualState: visualState,
                isEditable: isEditable,
                isCurrentFindMatch: isCurrentFindMatch,
                row: 0,
                columnIndex: columnIndex
            ),
            palette: palette ?? self.palette,
            nullDisplayString: "NULL",
            onEmphasizedSelection: onEmphasizedSelection,
            checkboxMark: checkboxMark,
            textTone: textTone
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
        #expect(empty.text == String(localized: "Empty"))
    }

    @Test("A server default draws in the medium font, tinted")
    func defaultMarker() {
        let appearance = resolve(text: "", placeholder: .defaultMarker)

        #expect(appearance.font == palette.mediumFont)
        #expect(appearance.textColor == .systemBlue)
    }

    @Test("A pending SQL expression draws like a pending DEFAULT and shows its SQL")
    func expressionDrawsLikeDefault() {
        let expression = resolve(
            text: "now()",
            rawValue: "now()",
            visualState: RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [0], expressionColumns: [0])
        )
        let literal = resolve(
            text: "now()",
            rawValue: "now()",
            visualState: RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [0])
        )

        #expect(expression.text == "now()")
        #expect(expression.font == palette.mediumFont)
        #expect(expression.textColor == .systemBlue)
        #expect(literal.font == palette.regularFont)
        #expect(literal.textColor == .labelColor)
    }

    // Changed on purpose: a result past 5,000 rows used to draw its placeholders blank.
    @Test("A NULL far down a large result still shows its placeholder text")
    func largeResultShowsPlaceholders() throws {
        let rowCount = 6_000
        let nullRow = 5_500
        let rows = TableRows.from(
            queryRows: (0..<rowCount).map { index -> [PluginCellValue] in
                [.text("\(index)"), index == nullRow ? .null : .text("v")]
            },
            columns: ["id", "note"],
            columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT")]
        )
        let owner = GridTestOwner(rows)
        defer { withExtendedLifetime(owner) {} }
        let model = DataGridModel()
        model.dataSource = owner
        model.reloadRows()
        let presenter = DataGridCellPresenter(model: model)
        let aqua = try #require(NSAppearance(named: .aqua))
        let pass = try #require(presenter.makePass(in: aqua))
        let row = try #require(model.row(at: nullRow))
        let column = try #require(model.columns.column(at: 1))

        let appearance = try #require(presenter.appearance(
            of: row,
            displayRow: nullRow,
            column: column,
            visualState: .empty,
            pass: pass,
            onEmphasizedSelection: false
        ))

        #expect(appearance.text == pass.nullDisplayString)
        #expect(!appearance.text.isEmpty)
        #expect(appearance.font == pass.palette.italicFont)
    }

    @Test("A deleted row recolours its text and keeps no modified tint")
    func deletedRow() {
        let appearance = resolve(visualState: RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: []), columnIndex: 0)

        #expect(appearance.textColor == palette.deletedRowText)
        #expect(appearance.backgroundTint == nil)
    }

    @Test("The find match keeps its highlight and its text takes the find indicator's color")
    func findMatchWins() {
        let appearance = resolve(isCurrentFindMatch: true, onEmphasizedSelection: true)

        #expect(appearance.backgroundTint == palette.findMatchTint)
        #expect(appearance.textColor == palette.findMatchText)
        #expect(palette.findMatchText == DataGridCellPalette.findMatchTextColor)
    }

    // findHighlightColor is light yellow in both appearances, where the label color is white in Dark Mode.
    @Test("Find match text stays dark in both appearances")
    func findMatchTextStaysDark() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var luminance: CGFloat = 1
            appearance.performAsCurrentDrawingAppearance {
                let color = DataGridCellPalette.findMatchTextColor.usingColorSpace(.sRGB)
                luminance = color.map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 } ?? 1
            }
            #expect(luminance < 0.2, "find match text is \(luminance) in \(name.rawValue)")
        }
    }

    @Test("A selected cell drops the modified tint and takes the selection's text colour")
    func selectionSuppressesTheModifiedTint() {
        let modified = RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [0])
        let unselected = resolve(visualState: modified, columnIndex: 0)
        let selected = resolve(visualState: modified, columnIndex: 0, onEmphasizedSelection: true)

        #expect(unselected.backgroundTint == palette.modifiedColumnTint)
        #expect(selected.backgroundTint == nil)
        #expect(selected.textColor == .alternateSelectedControlTextColor)
    }

    @Test("Only the modified column carries the tint")
    func onlyTheModifiedColumnIsTinted() {
        let state = RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [2])

        #expect(resolve(visualState: state, columnIndex: 2).backgroundTint != nil)
        #expect(resolve(visualState: state, columnIndex: 3).backgroundTint == nil)
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
        #expect(
            resolve(
                kind: .date,
                visualState: RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: [])
            ).accessoryRole == .chevronDisabled
        )
    }

    @Test("A cell with no accessory resolves no symbol")
    func noAccessoryNoRole() {
        #expect(resolve().accessoryRole == nil)
    }

    @Test("A read-only cell shows no chevron, a foreign key keeps its arrow")
    func readOnlyCellsKeepOnlyTheArrow() {
        #expect(resolve(kind: .date, isEditable: false).accessory == .none)
        #expect(resolve(kind: .date, isEditable: true).accessory == .chevron)
        #expect(resolve(kind: .foreignKey, rawValue: "42", isEditable: false).accessory == .foreignKey)
    }

    // MARK: - Checkboxes and owner tone

    @Test("A checkbox cell draws its mark and no text")
    func checkboxDrawsTheMarkOnly() {
        let checked = resolve(kind: .checkbox, text: "1", rawValue: "1", checkboxMark: .checked)
        let plain = resolve(kind: .text, text: "1", rawValue: "1", checkboxMark: .checked)

        #expect(checked.text.isEmpty)
        #expect(checked.checkboxMark == .checked)
        #expect(plain.checkboxMark == nil)
        #expect(plain.text == "1")
    }

    @Test("An owner's text tone colors a value but not a placeholder or a deleted row")
    func textToneColorsValuesOnly() {
        let toned = resolve(textTone: .systemGreen)
        let null = resolve(text: "", placeholder: .null, textTone: .systemGreen)
        let deleted = resolve(
            visualState: RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: []),
            textTone: .systemGreen
        )

        #expect(toned.textColor == .systemGreen)
        #expect(null.textColor == .secondaryLabelColor)
        #expect(deleted.textColor == palette.deletedRowText)
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

    // Changed on purpose: the selected text is always the system's, so it no longer takes a theme color.
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
        #expect(found.textColor == themedPalette.findMatchText)
    }

    // MARK: - Selection

    @Test("A selected cell's text takes the system's selected text color")
    func nativeSelectionColors() {
        let selected = resolve(onEmphasizedSelection: true)
        let unselected = resolve()

        #expect(selected.textColor == .alternateSelectedControlTextColor)
        #expect(unselected.textColor == .labelColor)
    }

    // Changed on purpose: the selection text slot is gone, so a theme cannot reach a selected cell.
    @Test("A theme that overrides every slot leaves the selected text to the system")
    func themeNeverReachesSelectedText() throws {
        let aqua = try #require(NSAppearance(named: .aqua))
        let palette = try ThemeTestFixture.withEverySlotOverridden {
            ThemeScope.live.dataGridCellPalette(in: aqua)
        }
        let selected = resolve(onEmphasizedSelection: true, palette: palette)

        #expect(palette.selectionText == .alternateSelectedControlTextColor)
        #expect(selected.textColor == .alternateSelectedControlTextColor)
        #expect(resolve(palette: palette).textColor != .alternateSelectedControlTextColor)
    }
}
