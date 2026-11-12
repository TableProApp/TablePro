//
//  DataGridCellAppearanceTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import TableProTheme
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
        valueColors: DataGridValueColors(all: .labelColor),
        rowNumberText: .secondaryLabelColor,
        deletedRowText: .systemRed,
        modifiedColumnTint: .systemYellow,
        findMatchTint: .systemOrange,
        selectionText: .alternateSelectedControlTextColor,
        focusBorder: .keyboardFocusIndicatorColor
    )

    private let themedPalette = DataGridCellPalette(
        regularFont: .systemFont(ofSize: 13),
        italicFont: .systemFont(ofSize: 13),
        mediumFont: .systemFont(ofSize: 13, weight: .medium),
        text: .systemPurple,
        placeholderText: .systemBrown,
        booleanTrueText: .systemGreen,
        booleanFalseText: .systemPink,
        valueColors: DataGridValueColors(all: .systemPurple),
        rowNumberText: .systemTeal,
        deletedRowText: .systemRed,
        modifiedColumnTint: .systemYellow,
        findMatchTint: .systemOrange,
        selectionText: .systemIndigo,
        focusBorder: .systemMint
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
        valueTone: DataGridValueTone = .plain,
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
            textTone: textTone,
            valueTone: valueTone
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

        #expect(selected.textColor == .systemIndigo)
        #expect(deleted.textColor == .systemRed)
        #expect(found.textColor == themedPalette.findMatchText)
    }

    // MARK: - Value tones

    private let tonedPalette = DataGridCellPalette(
        regularFont: .systemFont(ofSize: 13),
        italicFont: .systemFont(ofSize: 13),
        mediumFont: .systemFont(ofSize: 13, weight: .medium),
        text: .systemPurple,
        placeholderText: .systemBrown,
        booleanTrueText: .systemGreen,
        booleanFalseText: .systemPink,
        valueColors: DataGridValueColors(
            string: NSColor(srgbRed: 0.80, green: 0.20, blue: 0.10, alpha: 1),
            number: NSColor(srgbRed: 0.10, green: 0.40, blue: 0.80, alpha: 1),
            dateTime: NSColor(srgbRed: 0.50, green: 0.20, blue: 0.70, alpha: 1),
            binary: NSColor(srgbRed: 0.40, green: 0.40, blue: 0.40, alpha: 1),
            json: NSColor(srgbRed: 0.10, green: 0.50, blue: 0.30, alpha: 1),
            uuid: NSColor(srgbRed: 0.60, green: 0.40, blue: 0.10, alpha: 1),
            enumeration: NSColor(srgbRed: 0.70, green: 0.10, blue: 0.40, alpha: 1)
        ),
        rowNumberText: .systemTeal,
        deletedRowText: .systemRed,
        modifiedColumnTint: .systemYellow,
        findMatchTint: .systemOrange,
        selectionText: .systemIndigo,
        focusBorder: .systemMint
    )

    @Test("Each value tone draws its theme color, a plain value the text color")
    func eachToneDrawsItsColor() {
        let colors = tonedPalette.valueColors
        let expected: [(DataGridValueTone, NSColor)] = [
            (.string, colors.string),
            (.number, colors.number),
            (.dateTime, colors.dateTime),
            (.binary, colors.binary),
            (.json, colors.json),
            (.uuid, colors.uuid),
            (.enumeration, colors.enumeration),
            (.plain, .systemPurple),
        ]
        let distinctColors = Set(expected.map { ThemeTestFixture.hex($0.1) })
        #expect(distinctColors.count == expected.count)
        for (tone, color) in expected {
            #expect(resolve(valueTone: tone, palette: tonedPalette).textColor == color, "\(tone)")
        }
    }

    @Test("A find match, an emphasized selection, a deleted row and an owner tone outrank the value color")
    func stateOutranksTheValueColor() {
        let found = resolve(isCurrentFindMatch: true, valueTone: .number, palette: tonedPalette)
        let selected = resolve(onEmphasizedSelection: true, valueTone: .number, palette: tonedPalette)
        let deleted = resolve(
            visualState: RowVisualState(isDeleted: true, isInserted: false, modifiedColumns: []),
            valueTone: .number,
            palette: tonedPalette
        )
        let toned = resolve(textTone: .systemGreen, valueTone: .number, palette: tonedPalette)
        let modified = resolve(
            visualState: RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [0]),
            valueTone: .number,
            palette: tonedPalette
        )

        #expect(found.textColor == tonedPalette.findMatchText)
        #expect(selected.textColor == .systemIndigo)
        #expect(deleted.textColor == .systemRed)
        #expect(toned.textColor == .systemGreen)
        #expect(modified.textColor == tonedPalette.valueColors.number)
        #expect(modified.backgroundTint == tonedPalette.modifiedColumnTint)
    }

    @Test("A placeholder, a pending DEFAULT and a pending expression keep their own colors over a value tone")
    func placeholdersAndPendingValuesIgnoreTheTone() {
        let null = resolve(text: "", rawValue: nil, placeholder: .null, valueTone: .number, palette: tonedPalette)
        let pendingDefault = resolve(text: "", placeholder: .defaultMarker, valueTone: .number, palette: tonedPalette)
        let expression = resolve(
            text: "now()",
            rawValue: "now()",
            visualState: RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [0], expressionColumns: [0]),
            valueTone: .dateTime,
            palette: tonedPalette
        )

        #expect(null.textColor == .systemBrown)
        #expect(pendingDefault.textColor == .systemBlue)
        #expect(expression.textColor == .systemBlue)
    }

    @Test("A boolean keeps its true and false colors whatever the tone, and an unreadable one draws plain")
    func booleanBranchComesFirst() {
        let isTrue = resolve(kind: .boolean, text: "1", rawValue: "1", valueTone: .number, palette: tonedPalette)
        let isFalse = resolve(kind: .boolean, text: "f", rawValue: "f", palette: tonedPalette)
        let unreadable = resolve(kind: .boolean, text: "maybe", rawValue: "maybe", palette: tonedPalette)

        #expect(isTrue.textColor == .systemGreen)
        #expect(isFalse.textColor == .systemPink)
        #expect(unreadable.textColor == .systemPurple)
    }

    @Test("A theme's value colors reach the grid's palette, and unset ones draw the grid text")
    func themeReachesValueColors() throws {
        let aqua = try #require(NSAppearance(named: .aqua))
        let themed = ThemeScope.fixed(try ThemeTestFixture.theme(.light, [
            .gridString: "#AA1100",
            .gridNumber: "#0044AA",
            .gridDateTime: "#7722AA",
            .gridBinary: "#555555",
            .gridJSON: "#117744",
            .gridUUID: "#996611",
            .gridEnum: "#AA1166",
        ])).dataGridCellPalette(in: aqua)
        let unset = ThemeScope.fixed(BuiltInThemes.light).dataGridCellPalette(in: aqua)

        #expect(ThemeTestFixture.hex(themed.valueColors.string) == "#AA1100")
        #expect(ThemeTestFixture.hex(themed.valueColors.number) == "#0044AA")
        #expect(ThemeTestFixture.hex(themed.valueColors.dateTime) == "#7722AA")
        #expect(ThemeTestFixture.hex(themed.valueColors.binary) == "#555555")
        #expect(ThemeTestFixture.hex(themed.valueColors.json) == "#117744")
        #expect(ThemeTestFixture.hex(themed.valueColors.uuid) == "#996611")
        #expect(ThemeTestFixture.hex(themed.valueColors.enumeration) == "#AA1166")
        #expect(unset.valueColors == DataGridValueColors(all: unset.text))
    }

    private static let typedTheme: [ThemeSlot: String] = [
        .gridText: "#111111",
        .gridString: "#AA1100",
        .gridNumber: "#0044AA",
        .gridDateTime: "#7722AA",
        .gridBinary: "#555555",
        .gridJSON: "#117744",
        .gridUUID: "#996611",
        .gridEnum: "#AA1166",
        .gridBoolTrue: "#118811",
        .gridBoolFalse: "#881111",
        .gridNullValue: "#777777",
    ]

    @MainActor
    private struct TypedGrid {
        let owner: GridTestOwner
        let model: DataGridModel
        let presenter: DataGridCellPresenter

        init(
            values: [PluginCellValue],
            type: ColumnType,
            colorsValuesByType: Bool,
            settingIsOn: Bool = true,
            overridesSetting: Bool = false,
            isForeignKey: Bool = false,
            format: ValueDisplayFormat?
        ) throws {
            owner = GridTestOwner(TableRows.from(
                queryRows: values.map { [$0] },
                columns: ["value"],
                columnTypes: [type],
                columnForeignKeys: isForeignKey
                    ? ["value": ForeignKeyInfo(name: "fk_value", column: "value", referencedTable: "targets", referencedColumn: "id")]
                    : [:]
            ))
            var configuration = DataGridConfiguration()
            configuration.colorsValuesByType = colorsValuesByType
            configuration.overridesValueColorSetting = overridesSetting
            model = DataGridModel(
                configuration: configuration,
                themeScope: .fixed(try ThemeTestFixture.theme(.light, DataGridCellAppearanceTests.typedTheme))
            )
            model.dataSource = owner
            model.reloadRows()
            if let format { model.store.displayFormats = [format] }
            presenter = DataGridCellPresenter(model: model, valueColors: ValueColorSettings(colorsValuesByType: settingIsOn))
            presenter.refreshColumnPresentations()
        }

        func colors() throws -> [String?] {
            let aqua = try #require(NSAppearance(named: .aqua))
            let pass = try #require(presenter.makePass(in: aqua))
            let column = try #require(model.columns.column(at: 0))
            return try (0..<model.rowCount).map { displayRow in
                let row = try #require(model.row(at: displayRow))
                let appearance = try #require(presenter.appearance(
                    of: row,
                    displayRow: displayRow,
                    column: column,
                    visualState: .empty,
                    pass: pass,
                    onEmphasizedSelection: false
                ))
                return ThemeTestFixture.hex(appearance.textColor)
            }
        }
    }

    private func presentedColors(
        of values: [PluginCellValue],
        type: ColumnType,
        colorsValuesByType: Bool = true,
        settingIsOn: Bool = true,
        overridesSetting: Bool = false,
        format: ValueDisplayFormat? = nil
    ) throws -> [String?] {
        let grid = try TypedGrid(
            values: values,
            type: type,
            colorsValuesByType: colorsValuesByType,
            settingIsOn: settingIsOn,
            overridesSetting: overridesSetting,
            format: format
        )
        return try withExtendedLifetime(grid.owner) { try grid.colors() }
    }

    private static let uuidBytes = Data([
        0xAF, 0x49, 0x45, 0x3B, 0x7F, 0x2F, 0xFB, 0x58,
        0xFC, 0xD3, 0x2B, 0xD3, 0x99, 0x59, 0x9F, 0xA5,
    ])

    @Test("A grid that does not opt in draws every value in the grid text")
    func gridOffDrawsPlain() throws {
        #expect(try presentedColors(of: [.text("42")], type: .integer(rawType: "INT"), colorsValuesByType: false) == ["#111111"])
        #expect(try presentedColors(of: [.text("ok")], type: .text(rawType: "VARCHAR(8)"), colorsValuesByType: false) == ["#111111"])
        #expect(try presentedColors(
            of: [.text("1700000000")],
            type: .integer(rawType: "BIGINT"),
            colorsValuesByType: false,
            format: .unixTimestamp
        ) == ["#111111"])
    }

    private static let everyTypedColumn: [(value: PluginCellValue, type: ColumnType, format: ValueDisplayFormat?, hex: String)] = [
        (.text("42"), .integer(rawType: "INT"), nil, "#0044AA"),
        (.text("ok"), .text(rawType: "VARCHAR(8)"), nil, "#AA1100"),
        (.text("2024-01-08"), .date(rawType: "DATE"), nil, "#7722AA"),
        (.bytes(Data([0x9F, 0x3A])), .blob(rawType: "BLOB"), nil, "#555555"),
        (.text(#"["ops"]"#), .json(rawType: "JSON"), nil, "#117744"),
        (.text("8f14e45f-ceea-467f-a8f5-2e1c6a3d9b07"), .text(rawType: "UUID"), nil, "#996611"),
        (.text("admin"), .enumType(rawType: "ENUM", values: ["admin", "staff"]), nil, "#AA1166"),
        (.text("1700000000"), .integer(rawType: "BIGINT"), .unixTimestamp, "#7722AA"),
    ]

    @Test("With Color values by type off, an opted-in grid draws every typed value in the grid text")
    func settingOffDrawsPlain() throws {
        for column in Self.everyTypedColumn {
            let on = try presentedColors(of: [column.value], type: column.type, format: column.format)
            let off = try presentedColors(of: [column.value], type: column.type, settingIsOn: false, format: column.format)
            #expect(on == [column.hex], "\(column.type)")
            #expect(off == ["#111111"], "\(column.type)")
        }
    }

    @Test("Booleans and NULL keep their colors whether Color values by type is on or off")
    func booleansAndNullIgnoreTheSetting() throws {
        let values: [PluginCellValue] = [.text("true"), .text("false"), .null]
        let type = ColumnType.boolean(rawType: "BOOLEAN")
        let expected: [String?] = ["#118811", "#881111", "#777777"]

        #expect(try presentedColors(of: values, type: type, settingIsOn: true) == expected)
        #expect(try presentedColors(of: values, type: type, settingIsOn: false) == expected)
        #expect(try presentedColors(of: [.null], type: .integer(rawType: "INT"), settingIsOn: false) == ["#777777"])
    }

    @Test("A grid that overrides the setting colors values by type while it is off, and only if it opted in")
    func overrideIgnoresTheSetting() throws {
        let value: [PluginCellValue] = [.text("42")]
        let type = ColumnType.integer(rawType: "INT")

        #expect(try presentedColors(of: value, type: type, settingIsOn: false, overridesSetting: true) == ["#0044AA"])
        #expect(try presentedColors(
            of: value,
            type: type,
            colorsValuesByType: false,
            settingIsOn: false,
            overridesSetting: true
        ) == ["#111111"])
    }

    @Test("A foreign key cell keeps its link and takes its type's color")
    func foreignKeyTakesItsTypeColor() throws {
        let number = try TypedGrid(
            values: [.text("7")],
            type: .integer(rawType: "INT"),
            colorsValuesByType: true,
            isForeignKey: true,
            format: nil
        )
        let string = try TypedGrid(
            values: [.text("ops")],
            type: .text(rawType: "VARCHAR(8)"),
            colorsValuesByType: true,
            isForeignKey: true,
            format: nil
        )

        #expect(number.presenter.presentation(forDataIndex: 0).kind == .foreignKey)
        #expect(try withExtendedLifetime(number.owner) { try number.colors() } == ["#0044AA"])
        #expect(string.presenter.presentation(forDataIndex: 0).kind == .foreignKey)
        #expect(try withExtendedLifetime(string.owner) { try string.colors() } == ["#AA1100"])
    }

    @Test("An opted-in grid colors a value by its column's type and by the format it is shown in")
    func gridOnColorsByTypeAndFormat() throws {
        #expect(try presentedColors(of: [.text("42")], type: .integer(rawType: "INT")) == ["#0044AA"])
        #expect(try presentedColors(of: [.text("ok")], type: .text(rawType: "VARCHAR(8)")) == ["#AA1100"])
        #expect(try presentedColors(of: [.text("10.0.0.1")], type: .text(rawType: "INET")) == ["#111111"])
        #expect(try presentedColors(of: [.text("1700000000")], type: .integer(rawType: "BIGINT"), format: .unixTimestamp) == ["#7722AA"])
        #expect(try presentedColors(of: [.text("1700000000")], type: .integer(rawType: "BIGINT"), format: .json) == ["#0044AA"])
    }

    @Test("Under a UUID format a 16-byte value takes the UUID color and an 8-byte one in the same column stays binary")
    func uuidFormatColorsOnlyTheValuesItRenders() throws {
        let colors = try presentedColors(
            of: [.bytes(Self.uuidBytes), .bytes(Self.uuidBytes.prefix(8))],
            type: .blob(rawType: "VARBINARY(16)"),
            format: .uuid
        )

        #expect(colors == ["#996611", "#555555"])
    }

    @Test("A value its decoder cannot read keeps the column's color, one it reads takes the JSON color")
    func failedDecoderKeepsTheBaseColor() throws {
        let colors = try presentedColors(
            of: [.bytes(Data([0x82, 0xA7, 0x63, 0x6F, 0x6D, 0x70])), .bytes(Data([0x81, 0xA1, 0x61, 0x01]))],
            type: .blob(rawType: "BLOB"),
            format: .messagePack
        )

        #expect(colors == ["#555555", "#117744"])
    }

    @Test("A text column under a UUID format keeps the string color for a value that is not a UUID")
    func textThatIsNotAUUIDStaysAString() throws {
        let colors = try presentedColors(
            of: [.text("not a uuid"), .text("AF49453B7F2FFB58FCD32BD399599FA5")],
            type: .text(rawType: "VARCHAR(40)"),
            format: .uuid
        )

        #expect(colors == ["#AA1100", "#996611"])
    }

    @Test("The prewarmed text carries the same color as text formatted at draw time")
    func prewarmedTextKeepsTheFormattedFlag() throws {
        let grid = try TypedGrid(
            values: [.bytes(Self.uuidBytes), .bytes(Self.uuidBytes.prefix(8))],
            type: .blob(rawType: "VARBINARY(16)"),
            colorsValuesByType: true,
            format: .uuid
        )
        for displayRow in 0..<grid.model.rowCount {
            let row = try #require(grid.model.row(at: displayRow))
            grid.presenter.cacheText(
                of: row,
                rows: grid.model.rows,
                formats: grid.model.store.displayFormats,
                databaseType: nil
            )
        }

        #expect(try withExtendedLifetime(grid.owner) { try grid.colors() } == ["#996611", "#555555"])
    }

    @Test("A display format change recolors the cached cells it reformats")
    func formatChangeRecolorsCachedCells() throws {
        let grid = try TypedGrid(
            values: [.bytes(Self.uuidBytes)],
            type: .blob(rawType: "BINARY(16)"),
            colorsValuesByType: true,
            format: nil
        )
        let column = try #require(grid.model.columns.column(at: 0))

        let asBinary = try grid.colors()
        grid.model.setDisplayFormat(.uuid, for: column)
        let asUUID = try grid.colors()
        grid.model.setDisplayFormat(.raw, for: column)
        let asBinaryAgain = try grid.colors()
        withExtendedLifetime(grid.owner) {}

        #expect(asBinary == ["#555555"])
        #expect(asUUID == ["#996611"])
        #expect(asBinaryAgain == ["#555555"])
    }

    // MARK: - Selection

    @Test("A selected cell's text takes the palette's selected text color")
    func selectionTakesThePaletteSelectedText() {
        let selected = resolve(onEmphasizedSelection: true)
        let themed = resolve(onEmphasizedSelection: true, palette: themedPalette)
        let unselected = resolve()

        #expect(selected.textColor == palette.selectionText)
        #expect(themed.textColor == .systemIndigo)
        #expect(unselected.textColor == .labelColor)
    }

    @Test("A theme's selected text and focus border reach the grid's palette")
    func themeReachesSelectedTextAndFocusBorder() throws {
        let aqua = try #require(NSAppearance(named: .aqua))
        let scope = ThemeScope.fixed(try ThemeTestFixture.theme(.light, [
            .gridSelectionText: "#00AA00",
            .gridFocusBorder: "#FF79C6",
        ]))
        let palette = scope.dataGridCellPalette(in: aqua)
        let selected = resolve(onEmphasizedSelection: true, palette: palette)

        #expect(ThemeTestFixture.hex(palette.selectionText) == "#00AA00")
        #expect(ThemeTestFixture.hex(palette.focusBorder) == "#FF79C6")
        #expect(selected.textColor === palette.selectionText)
        #expect(resolve(palette: palette).textColor !== palette.selectionText)
        #expect(palette.rowNumberColor(for: .empty, onEmphasizedSelection: true) === palette.selectionText)
        #expect(palette.rowNumberColor(for: .empty, onEmphasizedSelection: false) === palette.rowNumberText)
    }

    @Test("With the slots unset the grid's palette carries the system's selected text and focus ring colors")
    func unsetSlotsGiveTheSystemColors() throws {
        let aqua = try #require(NSAppearance(named: .aqua))
        let palette = ThemeScope.fixed(BuiltInThemes.light).dataGridCellPalette(in: aqua)

        #expect(palette.selectionText === NSColor.alternateSelectedControlTextColor)
        #expect(palette.focusBorder === NSColor.keyboardFocusIndicatorColor)
        #expect(resolve(onEmphasizedSelection: true, palette: palette).textColor === NSColor.alternateSelectedControlTextColor)
    }
}

extension GlobalStateSuites {
    @MainActor
    struct DataGridValueColorSettingTests {
        private func valueColor(in grid: HostedDataGrid) throws -> String? {
            let aqua = try #require(NSAppearance(named: .aqua))
            let presenter = grid.controller.presenter
            let pass = try #require(presenter.makePass(in: aqua))
            let row = try #require(grid.model.row(at: 0))
            let column = try #require(grid.model.columns.column(at: 0))
            let appearance = try #require(presenter.appearance(
                of: row,
                displayRow: 0,
                column: column,
                visualState: .empty,
                pass: pass,
                onEmphasizedSelection: false
            ))
            return ThemeTestFixture.hex(appearance.textColor)
        }

        @Test("Turning Color values by type on or off reaches a mounted grid's cells, with no reload of its rows")
        func settingChangeRecolorsWithoutReload() async throws {
            let settings = AppSettingsManager.shared
            let original = settings.valueColors
            defer { settings.valueColors = original }
            settings.valueColors = ValueColorSettings(colorsValuesByType: false)
            var configuration = DataGridConfiguration()
            configuration.colorsValuesByType = true
            let scope = ThemeScope.fixed(try ThemeTestFixture.theme(.light, [.gridText: "#111111", .gridNumber: "#0044AA"]))
            let grid = HostedDataGrid(
                rows: TableRows.from(queryRows: [[.text("42")]], columns: ["value"], columnTypes: [.integer(rawType: "INT")]),
                configuration: configuration,
                prepare: { _, model in model.themeScope = scope }
            )
            defer { grid.close() }
            let rowView = try #require(grid.main.rowView(atRow: 0, makeIfNecessary: true))
            let rowID = try #require(grid.model.row(at: 0)).id
            let off = try valueColor(in: grid)
            let cached = try #require(grid.model.display.cache.box(forID: rowID))

            settings.valueColors = ValueColorSettings(colorsValuesByType: true)
            try await waitUntil { grid.controller.presenter.registry.colorsValuesByType }
            let on = try valueColor(in: grid)

            settings.valueColors = ValueColorSettings(colorsValuesByType: false)
            try await waitUntil { !grid.controller.presenter.registry.colorsValuesByType }
            let offAgain = try valueColor(in: grid)

            #expect(off == "#111111")
            #expect(on == "#0044AA")
            #expect(offAgain == "#111111")
            #expect(grid.model.display.cache.box(forID: rowID) === cached)
            #expect(grid.main.rowView(atRow: 0, makeIfNecessary: false) === rowView)
        }
    }
}
