//
//  DataGridColumnWidthCalculatorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct DataGridColumnWidthCalculatorTests {
    private func calculator(for rows: TableRows, revealsInvisibleCharacters: Bool = false) -> DataGridColumnWidthCalculator {
        DataGridColumnWidthCalculator(
            rows: rows,
            databaseType: nil,
            nullDisplayString: AppSettingsManager.shared.dataGrid.nullDisplay,
            revealsInvisibleCharacters: revealsInvisibleCharacters,
            fonts: ThemeEngine.shared.dataGridFonts
        )
    }

    private func input(
        _ name: String,
        dataIndex: Int = 0,
        in rows: TableRows,
        accessory: DataGridCellAccessory = .none
    ) -> DataGridColumnWidthCalculator.Input {
        DataGridColumnWidthCalculator.Input(
            column: DataGridColumn(
                id: DataGridColumnID(name: name, occurrence: 0),
                dataIndex: dataIndex,
                type: dataIndex < rows.columnTypes.count ? rows.columnTypes[dataIndex] : nil,
                comment: nil
            ),
            accessory: accessory,
            displayFormat: nil
        )
    }

    private func singleValueRows(
        _ value: String,
        columnType: ColumnType,
        foreignKey: ForeignKeyInfo? = nil
    ) -> TableRows {
        TableRows.from(
            queryRows: [[.text(value)]],
            columns: ["x"],
            columnTypes: [columnType],
            columnForeignKeys: foreignKey.map { ["x": $0] } ?? [:],
            foreignKeysFetched: foreignKey != nil
        )
    }

    private func automaticWidth(of rows: TableRows, column: String = "x", accessory: DataGridCellAccessory = .none) -> CGFloat {
        calculator(for: rows).automaticWidth(input(column, in: rows, accessory: accessory))
    }

    private func fittedWidth(
        of rows: TableRows,
        column: String = "data",
        availableWidth: CGFloat,
        accessory: DataGridCellAccessory = .none
    ) -> CGFloat {
        calculator(for: rows).fittedWidth(input(column, in: rows, accessory: accessory), availableWidth: availableWidth)
    }

    private func textRows(_ values: [String?], column: String = "data") -> TableRows {
        TableRows.from(
            queryRows: values.map { [PluginCellValue.fromOptional($0)] },
            columns: [column],
            columnTypes: [.text(rawType: nil)]
        )
    }

    // MARK: - Automatic width

    @Test("An automatic width stays within its bounds")
    func automaticWidthWithinBounds() {
        let rows = TestFixtures.makeTableRows(rowCount: 10)

        for (index, column) in rows.columns.enumerated() {
            let width = calculator(for: rows).automaticWidth(input(column, dataIndex: index, in: rows))
            #expect(width >= 60)
            #expect(width <= 800)
        }
    }

    @Test("A header-only column gets a reasonable width")
    func headerOnlyColumnWidth() {
        let width = automaticWidth(of: textRows([], column: "username"), column: "username")

        #expect(width >= 60)
        #expect(width <= 800)
    }

    @Test("An empty header with no rows gets the minimum width")
    func emptyHeaderNoRowsReturnsMinWidth() {
        #expect(automaticWidth(of: textRows([], column: ""), column: "") >= 60)
    }

    @Test("Very long cell content caps the width at the maximum")
    func longContentCapsAtMax() {
        let rows = textRows([String(repeating: "X", count: 5_000)])

        #expect(automaticWidth(of: rows, column: "data") <= 800)
    }

    @Test("Many columns still produce valid widths")
    func manyColumnsProduceValidWidths() {
        let columnCount = 60
        let columns = (0..<columnCount).map { "col_\($0)" }
        let values: [[PluginCellValue]] = (0..<100).map { row in
            columns.map { PluginCellValue.text("\($0)_val_\(row)") }
        }
        let rows = TableRows.from(
            queryRows: values,
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: columnCount)
        )

        for (index, column) in columns.enumerated() {
            let width = calculator(for: rows).automaticWidth(input(column, dataIndex: index, in: rows))
            #expect(width >= 60)
            #expect(width <= 800)
        }
    }

    @Test("NULL values do not break the width calculation")
    func nullValuesAreSafe() {
        let width = automaticWidth(of: textRows([nil, "hello", nil], column: "name"), column: "name")

        #expect(width >= 60)
        #expect(width <= 800)
    }

    @Test("An automatic width includes the exact trailing accessory footprint")
    func automaticWidthIncludesTrailingAccessory() {
        let value = String(repeating: "M", count: 20)
        let plain = automaticWidth(of: singleValueRows(value, columnType: .text(rawType: "TEXT")))
        let date = automaticWidth(of: singleValueRows(value, columnType: .date(rawType: "DATE")), accessory: .chevron)
        let foreignKey = automaticWidth(
            of: singleValueRows(
                value,
                columnType: .text(rawType: "TEXT"),
                foreignKey: TestFixtures.makeForeignKeyInfo(column: "x")
            ),
            accessory: .foreignKey
        )

        #expect(date == plain + 16)
        #expect(foreignKey == plain + 20)
    }

    @Test("An automatic width measures the displayed empty placeholder beside an accessory")
    func automaticWidthMeasuresEmptyPlaceholder() {
        let width = automaticWidth(of: singleValueRows("", columnType: .date(rawType: "DATE")), accessory: .chevron)
        let displayedWidth = CGFloat((String(localized: "Empty") as NSString).length)
            * ThemeEngine.shared.dataGridFonts.monoCharWidth

        #expect(width - DataGridCellAccessory.chevron.measurementPadding >= displayedWidth)
    }

    @Test("An explicit fit measures a value the automatic sample steps over")
    func explicitFitMeasuresValueTheSampleSkips() {
        let short = String(repeating: "M", count: 10)
        let long = String(repeating: "M", count: 60)
        var values = Array(repeating: short, count: 1_000)
        values[5] = long
        let rows = TableRows.from(
            queryRows: values.map { [PluginCellValue.text($0)] },
            columns: ["title"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let charWidth = ThemeEngine.shared.dataGridFonts.monoCharWidth

        let automatic = automaticWidth(of: rows, column: "title")
        let fitted = fittedWidth(of: rows, column: "title", availableWidth: 4_000)

        #expect(automatic < CGFloat(long.count) * charWidth)
        #expect(fitted >= CGFloat(long.count) * charWidth + DataGridCellAccessory.none.measurementPadding)
    }

    // MARK: - Column presentation

    @Test("An enum column reserves its dropdown before the allowed values arrive")
    func enumColumnReservesDropdownBeforeValuesArrive() {
        let presentation = DataGridColumnPresentation.resolve(
            columnType: .enumType(rawType: "ENUM", values: nil),
            isForeignKey: false,
            isDropdown: false,
            isTypePicker: false,
            isEnumOrSet: false,
            isEditable: true
        )

        #expect(presentation.kind == .dropdown)
        #expect(presentation.accessory == .chevron)
    }

    @Test("A SET column reserves its dropdown before the allowed values arrive")
    func setColumnReservesDropdownBeforeValuesArrive() {
        let presentation = DataGridColumnPresentation.resolve(
            columnType: .set(rawType: "SET", values: nil),
            isForeignKey: false,
            isDropdown: false,
            isTypePicker: false,
            isEnumOrSet: false,
            isEditable: true
        )

        #expect(presentation.kind == .dropdown)
        #expect(presentation.accessory == .chevron)
    }

    @Test("A read-only enum column reserves nothing")
    func readOnlyEnumColumnReservesNothing() {
        let presentation = DataGridColumnPresentation.resolve(
            columnType: .enumType(rawType: "ENUM", values: nil),
            isForeignKey: false,
            isDropdown: false,
            isTypePicker: false,
            isEnumOrSet: false,
            isEditable: false
        )

        #expect(presentation.accessory == .none)
    }

    @Test("A checkbox column draws a checkbox whatever its type")
    func checkboxColumnIsACheckbox() {
        let presentation = DataGridColumnPresentation.resolve(
            columnType: .boolean(rawType: "BOOL"),
            isForeignKey: true,
            isDropdown: false,
            isTypePicker: false,
            isEnumOrSet: false,
            isEditable: true,
            isCheckbox: true
        )

        #expect(presentation.kind == .checkbox)
        #expect(presentation.accessory == .none)
    }

    // MARK: - Fit to content

    @Test("A very long value is capped instead of stretching the column")
    func longValueIsCapped() {
        let width = fittedWidth(of: textRows([String(repeating: "X", count: 5_000)]), availableWidth: 1_600)

        #expect(width == 800)
    }

    @Test("No column takes more than half the visible grid")
    func capIsHalfTheVisibleGrid() {
        let width = fittedWidth(of: textRows([String(repeating: "X", count: 5_000)]), availableWidth: 1_000)

        #expect(width == 500)
    }

    @Test("The cap holds at 300 pt in a narrow window")
    func capFloorsInNarrowWindow() {
        let rows = textRows([String(repeating: "X", count: 5_000)])

        #expect(fittedWidth(of: rows, availableWidth: 200) == 300)
        #expect(fittedWidth(of: rows, availableWidth: 0) == 300)
    }

    @Test("Short values still size to their content, not to the cap")
    func shortValuesSizeToContent() {
        let width = fittedWidth(of: textRows(["ok", "fine"], column: "status"), column: "status", availableWidth: 1_600)

        #expect(width >= 60)
        #expect(width < 300)
    }

    @Test("A fitted width never exceeds the data column ceiling")
    func fittedWidthStaysUnderColumnCeiling() {
        let rows = textRows([String(repeating: "X", count: 20_000)])
        for availableWidth in [CGFloat](stride(from: 0, through: 4_000, by: 250)) {
            #expect(fittedWidth(of: rows, availableWidth: availableWidth) <= DataGridMetrics.dataColumnMaxWidth)
        }
    }

    @Test("A long header alone does not stretch the column")
    func longHeaderIsCapped() {
        let column = String(repeating: "column_name_", count: 200)

        #expect(fittedWidth(of: textRows([], column: column), column: column, availableWidth: 1_600) == 800)
    }

    @Test("Fit to content includes the exact trailing accessory footprint")
    func fitToContentIncludesTrailingAccessory() {
        let value = String(repeating: "M", count: 20)
        let plain = singleValueRows(value, columnType: .text(rawType: "TEXT"))
        let date = singleValueRows(value, columnType: .date(rawType: "DATE"))
        let foreignKey = singleValueRows(
            value,
            columnType: .text(rawType: "TEXT"),
            foreignKey: TestFixtures.makeForeignKeyInfo(column: "x")
        )

        let plainWidth = fittedWidth(of: plain, column: "x", availableWidth: 1_600)
        #expect(fittedWidth(of: date, column: "x", availableWidth: 1_600, accessory: .chevron) == plainWidth + 16)
        #expect(fittedWidth(of: foreignKey, column: "x", availableWidth: 1_600, accessory: .foreignKey) == plainWidth + 20)
    }

    @Test("Fitting every column shares one budget, so a wide result is still measured whole")
    func fittingManyColumnsStillReadsTheLongValue() {
        let short = String(repeating: "M", count: 10)
        let long = String(repeating: "M", count: 60)
        var values = Array(repeating: short, count: 1_000)
        values[5] = long
        let rows = TableRows.from(
            queryRows: values.map { [PluginCellValue.text($0)] },
            columns: ["title"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let charWidth = ThemeEngine.shared.dataGridFonts.monoCharWidth

        let fitted = calculator(for: rows).fittedWidth(
            input("title", in: rows),
            availableWidth: 4_000,
            fittedColumnCount: 100
        )

        #expect(fitted >= CGFloat(long.count) * charWidth)
    }

    // MARK: - Change tracking

    // A reload would discard the very edit the user just made.
    @Test("Recording an edit does not ask the grid to reload, discarding does")
    func recordingAnEditDoesNotAskTheGridToReload() {
        let manager = DataChangeManager()
        let initialVersion = manager.reloadVersion

        manager.recordCellChange(
            rowID: .existing(0),
            columnIndex: 0,
            columnName: "name",
            oldValue: "old",
            newValue: "new"
        )

        #expect(manager.reloadVersion == initialVersion)

        manager.discardChanges()

        #expect(manager.reloadVersion == initialVersion + 1)
    }
}
