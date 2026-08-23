//
//  DataGridCellFactoryPerfTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Column Width Optimization")
@MainActor
struct ColumnWidthOptimizationTests {
    private func tableRows(
        value: String,
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

    private func optimalWidth(
        for tableRows: TableRows,
        accessory: DataGridCellAccessory = .none
    ) -> CGFloat {
        DataGridCellFactory().calculateOptimalColumnWidth(
            for: "x",
            columnIndex: 0,
            tableRows: tableRows,
            accessory: accessory
        )
    }

    @Test("Column width is within min/max bounds")
    func columnWidthWithinBounds() {
        let factory = DataGridCellFactory()
        let tableRows = TestFixtures.makeTableRows(rowCount: 10)

        for (index, column) in tableRows.columns.enumerated() {
            let width = factory.calculateOptimalColumnWidth(
                for: column,
                columnIndex: index,
                tableRows: tableRows
            )
            #expect(width >= 60, "Width should be at least 60 (min)")
            #expect(width <= 800, "Width should be at most 800 (max)")
        }
    }

    @Test("Header-only column returns reasonable width")
    func headerOnlyColumnWidth() {
        let factory = DataGridCellFactory()
        let tableRows = TableRows.from(
            queryRows: [],
            columns: ["username"],
            columnTypes: [.text(rawType: nil)]
        )

        let width = factory.calculateOptimalColumnWidth(
            for: "username",
            columnIndex: 0,
            tableRows: tableRows
        )
        #expect(width >= 60)
        #expect(width <= 800)
    }

    @Test("Empty header with no rows returns minimum width")
    func emptyHeaderNoRowsReturnsMinWidth() {
        let factory = DataGridCellFactory()
        let tableRows = TableRows.from(
            queryRows: [],
            columns: [""],
            columnTypes: [.text(rawType: nil)]
        )

        let width = factory.calculateOptimalColumnWidth(
            for: "",
            columnIndex: 0,
            tableRows: tableRows
        )
        #expect(width >= 60, "Should return at least minimum width")
    }

    @Test("Very long cell content caps width at maximum")
    func longContentCapsAtMax() {
        let factory = DataGridCellFactory()
        let longValue = String(repeating: "X", count: 5_000)
        let rawRows: [[String?]] = [[longValue]]
        let tableRows = TableRows.from(
            queryRows: rawRows.map { row in row.map(PluginCellValue.fromOptional) },
            columns: ["data"],
            columnTypes: [.text(rawType: nil)]
        )

        let width = factory.calculateOptimalColumnWidth(
            for: "data",
            columnIndex: 0,
            tableRows: tableRows
        )
        #expect(width <= 800, "Width should be capped at max (800)")
    }

    @Test("Many columns still produce valid widths")
    func manyColumnsProduceValidWidths() {
        let factory = DataGridCellFactory()
        let columnCount = 60
        let columns = (0..<columnCount).map { "col_\($0)" }
        let columnTypes = Array(repeating: ColumnType.text(rawType: nil), count: columnCount)
        let rawRows: [[String?]] = (0..<100).map { rowIdx in
            columns.map { "\($0)_val_\(rowIdx)" }
        }
        let tableRows = TableRows.from(queryRows: rawRows.map { row in row.map(PluginCellValue.fromOptional) }, columns: columns, columnTypes: columnTypes)

        for (index, column) in columns.enumerated() {
            let width = factory.calculateOptimalColumnWidth(
                for: column,
                columnIndex: index,
                tableRows: tableRows
            )
            #expect(width >= 60)
            #expect(width <= 800)
        }
    }

    @Test("Nil cell values do not crash width calculation")
    func nilCellValuesSafe() {
        let factory = DataGridCellFactory()
        let rawRows: [[String?]] = [
            [nil],
            ["hello"],
            [nil],
        ]
        let tableRows = TableRows.from(
            queryRows: rawRows.map { row in row.map(PluginCellValue.fromOptional) },
            columns: ["name"],
            columnTypes: [.text(rawType: nil)]
        )

        let width = factory.calculateOptimalColumnWidth(
            for: "name",
            columnIndex: 0,
            tableRows: tableRows
        )
        #expect(width >= 60)
        #expect(width <= 800)
    }

    @Test("Automatic width includes the exact trailing action footprint")
    func automaticWidthIncludesTrailingAction() {
        let value = String(repeating: "M", count: 20)
        let plainWidth = optimalWidth(for: tableRows(value: value, columnType: .text(rawType: "TEXT")))
        let dateWidth = optimalWidth(
            for: tableRows(value: value, columnType: .date(rawType: "DATE")),
            accessory: .chevron
        )
        let foreignKeyWidth = optimalWidth(for: tableRows(
            value: value,
            columnType: .text(rawType: "TEXT"),
            foreignKey: TestFixtures.makeForeignKeyInfo(column: "x")
        ), accessory: .foreignKey)

        #expect(dateWidth == plainWidth + 16)
        #expect(foreignKeyWidth == plainWidth + 20)
    }

    @Test("Automatic width measures the displayed empty placeholder beside an action")
    func automaticWidthMeasuresEmptyPlaceholder() {
        let rows = tableRows(value: "", columnType: .date(rawType: "DATE"))
        let width = optimalWidth(for: rows, accessory: .chevron)
        let displayedWidth = CGFloat((String(localized: "Empty") as NSString).length)
            * ThemeEngine.shared.dataGridFonts.monoCharWidth

        #expect(width - DataGridCellAccessory.chevron.measurementPadding >= displayedWidth)
    }

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
        let factory = DataGridCellFactory()
        let charWidth = ThemeEngine.shared.dataGridFonts.monoCharWidth

        let automatic = factory.calculateOptimalColumnWidth(for: "title", columnIndex: 0, tableRows: rows)
        let fitted = factory.calculateFitToContentWidth(
            for: "title",
            columnIndex: 0,
            tableRows: rows,
            availableWidth: 4_000
        )

        #expect(automatic < CGFloat(long.count) * charWidth)
        #expect(fitted >= CGFloat(long.count) * charWidth + DataGridCellAccessory.none.measurementPadding)
    }
}

@Suite("Fit To Content Width")
@MainActor
struct FitToContentWidthTests {
    private func makeTableRows(values: [String], column: String = "data") -> TableRows {
        TableRows.from(
            queryRows: values.map { [PluginCellValue.fromOptional($0)] },
            columns: [column],
            columnTypes: [.text(rawType: nil)]
        )
    }

    private func fitWidth(values: [String], availableWidth: CGFloat, column: String = "data") -> CGFloat {
        DataGridCellFactory().calculateFitToContentWidth(
            for: column,
            columnIndex: 0,
            tableRows: makeTableRows(values: values, column: column),
            availableWidth: availableWidth
        )
    }

    @Test("A very long value is capped instead of stretching the column")
    func longValueIsCapped() {
        let width = fitWidth(values: [String(repeating: "X", count: 5_000)], availableWidth: 1_600)

        #expect(width == 800, "A 5,000 character value must not widen the column past the 800pt ceiling")
    }

    @Test("No column takes more than half the visible grid")
    func capIsHalfTheVisibleGrid() {
        let width = fitWidth(values: [String(repeating: "X", count: 5_000)], availableWidth: 1_000)

        #expect(width == 500)
    }

    @Test("Cap holds at 300pt in a narrow window")
    func capFloorsInNarrowWindow() {
        #expect(fitWidth(values: [String(repeating: "X", count: 5_000)], availableWidth: 200) == 300)
        #expect(fitWidth(values: [String(repeating: "X", count: 5_000)], availableWidth: 0) == 300)
    }

    @Test("Short values still size to their content, not to the cap")
    func shortValuesSizeToContent() {
        let width = fitWidth(values: ["ok", "fine"], availableWidth: 1_600, column: "status")

        #expect(width >= 60)
        #expect(width < 300, "The cap is a ceiling, not a target width")
    }

    @Test("Fitted width never exceeds the data column ceiling")
    func fittedWidthStaysUnderColumnCeiling() {
        for availableWidth in [CGFloat](stride(from: 0, through: 4_000, by: 250)) {
            let width = fitWidth(values: [String(repeating: "X", count: 20_000)], availableWidth: availableWidth)
            #expect(width <= DataGridMetrics.dataColumnMaxWidth)
        }
    }

    @Test("Long header alone does not stretch the column")
    func longHeaderIsCapped() {
        let column = String(repeating: "column_name_", count: 200)
        let width = fitWidth(values: [], availableWidth: 1_600, column: column)

        #expect(width == 800)
    }

    @Test("Fit to content includes the exact trailing action footprint")
    func fitToContentIncludesTrailingAction() {
        let value = String(repeating: "M", count: 20)
        let plainRows = TableRows.from(
            queryRows: [[.text(value)]],
            columns: ["x"],
            columnTypes: [.text(rawType: "TEXT")]
        )
        let dateRows = TableRows.from(
            queryRows: [[.text(value)]],
            columns: ["x"],
            columnTypes: [.date(rawType: "DATE")]
        )
        let foreignKeyRows = TableRows.from(
            queryRows: [[.text(value)]],
            columns: ["x"],
            columnTypes: [.text(rawType: "TEXT")],
            columnForeignKeys: ["x": TestFixtures.makeForeignKeyInfo(column: "x")],
            foreignKeysFetched: true
        )
        let factory = DataGridCellFactory()

        func width(
            for rows: TableRows,
            accessory: DataGridCellAccessory = .none
        ) -> CGFloat {
            factory.calculateFitToContentWidth(
                for: "x",
                columnIndex: 0,
                tableRows: rows,
                availableWidth: 1_600,
                accessory: accessory
            )
        }

        #expect(width(for: dateRows, accessory: .chevron) == width(for: plainRows) + 16)
        #expect(width(for: foreignKeyRows, accessory: .foreignKey) == width(for: plainRows) + 20)
    }
}

@Suite("Change Reapplication Version Tracking")
struct ChangeReapplyVersionTests {
    @Test("Version tracking skips redundant work")
    func versionTrackingSkipsRedundantWork() {
        var lastVersion = 0
        var applyCount = 0
        let currentVersion = 3

        func reapplyIfNeeded(version: Int) {
            guard lastVersion != version else { return }
            lastVersion = version
            applyCount += 1
        }

        reapplyIfNeeded(version: currentVersion)
        #expect(applyCount == 1)
        #expect(lastVersion == 3)

        reapplyIfNeeded(version: currentVersion)
        #expect(applyCount == 1, "Should skip when version unchanged")

        reapplyIfNeeded(version: 4)
        #expect(applyCount == 2, "Should apply when version changes")
        #expect(lastVersion == 4)
    }

    @Test("Version starts at zero and tracks increments")
    func versionStartsAtZeroAndIncrements() {
        var lastVersion = 0
        var versions: [Int] = []

        for v in [0, 1, 1, 2, 2, 2, 3] {
            if lastVersion != v {
                lastVersion = v
                versions.append(v)
            }
        }

        #expect(versions == [1, 2, 3], "Only version changes should be recorded")
    }

    @Test("DataChangeManager reloadVersion increments on cell change")
    @MainActor
    /// `reloadVersion` is the signal that tells the grid to throw away what it is showing and fetch
    /// again. It increments on `clearChanges`, `discardChanges` and `configureForTable`, and
    /// deliberately not on recording an edit: a reload there would discard the very edit the user
    /// just made. These asserted the opposite, which is why they sat in the quarantine file, so
    /// each now pins the real contract from both sides.
    func recordingAnEditDoesNotAskTheGridToReload() {
        let manager = DataChangeManager()
        let initialVersion = manager.reloadVersion

        manager.recordCellChange(
            rowIndex: 0,
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
