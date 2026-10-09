//
//  SelectionSummaryCalculatorTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProNumberFormatting
import TableProPluginKit
import Testing

struct SelectionSummaryCalculatorTests {
    private static func tableRows(_ values: [[PluginCellValue]], types: [ColumnType]) -> TableRows {
        TableRows.from(queryRows: values, columns: types.indices.map { "c\($0)" }, columnTypes: types)
    }

    private static func selection(_ rects: [GridRect], columns: IndexSet = []) -> GridSelection {
        GridSelection(rectangles: rects, activeCell: nil, anchor: nil, columns: columns)
    }

    private static func input(
        _ tableRows: TableRows,
        selecting rects: [GridRect],
        displayIDs: [RowID]? = nil,
        dataColumns: [Int]? = nil,
        policy: SelectionSummaryColumnPolicy? = nil,
        deleted: Set<RowID> = [],
        inserted: Set<RowID> = [],
        modified: [RowID: Set<Int>] = [:]
    ) -> SelectionSummaryInput {
        SelectionSummaryInput(
            selection: selection(rects),
            tableRows: tableRows,
            displayIDs: displayIDs,
            dataColumnsByDisplayPosition: dataColumns ?? Array(tableRows.columns.indices),
            policy: policy ?? .derived(
                columnTypes: tableRows.columnTypes,
                displayFormats: [],
                columnCount: tableRows.columns.count
            ),
            deletedRowIDs: deleted,
            insertedRowIDs: inserted,
            modifiedCells: modified
        )
    }

    private static func summarize(_ input: SelectionSummaryInput) async throws -> SelectionSummary {
        try await SelectionSummaryCalculator().summarize(input)
    }

    private static let integer = ColumnType.integer(rawType: "INT")
    private static let untyped = ColumnType.text(rawType: nil)

    @Test("cells under three overlapping rectangles are counted once")
    func overlappingRectanglesCountOnce() async throws {
        let rows = (0..<4).map { row in (0..<3).map { PluginCellValue.text("\(row * 10 + $0)") } }
        let table = Self.tableRows(rows, types: Array(repeating: Self.integer, count: 3))
        let rects = [
            GridRect(rows: 0...2, columns: 0...1),
            GridRect(rows: 1...3, columns: 1...2),
            GridRect(rows: 2...2, columns: 0...2),
            GridRect(rows: 0...2, columns: 0...1)
        ]

        let summary = try await Self.summarize(Self.input(table, selecting: rects))

        #expect(summary.valueCount == 10)
        #expect(summary.numbers?.count == 10)
        #expect(summary.numbers?.sum.decimal == 160)
    }

    @Test("display positions resolve through the column map, so a hidden column is never read")
    func hiddenAndReorderedColumnsResolveThroughTheMap() async throws {
        let table = Self.tableRows(
            [[.text("1"), .text("100"), .text("10")], [.text("2"), .text("200"), .text("20")]],
            types: Array(repeating: Self.integer, count: 3)
        )

        let first = try await Self.summarize(
            Self.input(table, selecting: [GridRect(rows: 0...1, columns: 0...0)], dataColumns: [2, 0])
        )
        let both = try await Self.summarize(
            Self.input(table, selecting: [GridRect(rows: 0...1, columns: 0...1)], dataColumns: [2, 0])
        )

        #expect(first.numbers?.sum.decimal == 30)
        #expect(both.numbers?.sum.decimal == 33)
        #expect(both.valueCount == 4)
    }

    @Test("display rows resolve through the value filter's order and stop at its end")
    func valueFilterOrderResolvesRows() async throws {
        let table = Self.tableRows([[.text("1")], [.text("2")], [.text("3")], [.text("4")]], types: [Self.integer])

        let summary = try await Self.summarize(
            Self.input(table, selecting: [GridRect(rows: 0...3, columns: 0...0)], displayIDs: [.existing(3), .existing(1)])
        )

        #expect(summary.valueCount == 2)
        #expect(summary.numbers?.sum.decimal == 6)
    }

    @Test("a row staged for deletion is neither a value nor empty")
    func deletedRowsAreLeftOut() async throws {
        let table = Self.tableRows([[.text("1")], [.text("2")], [.null]], types: [Self.integer])

        let summary = try await Self.summarize(
            Self.input(table, selecting: [GridRect(rows: 0...2, columns: 0...0)], deleted: [.existing(1), .existing(2)])
        )

        #expect(summary.valueCount == 1)
        #expect(summary.emptyCount == 0)
        #expect(summary.numbers?.sum.decimal == 1)
    }

    @Test("NULL is empty, empty text is a value, and the default marker is empty only where an edit put it")
    func emptyCellRules() async throws {
        let insertedID = RowID.inserted(UUID())
        var table = Self.tableRows(
            [
                [.null, .text("")],
                [.text(PluginCellValue.defaultMarkerText), .text(PluginCellValue.defaultMarkerText)],
                [.text("7"), .text(PluginCellValue.defaultMarkerText)]
            ],
            types: [Self.integer, Self.untyped]
        )
        table.appendInsertedRow(id: insertedID, values: [.text(PluginCellValue.defaultMarkerText), .text("5")])

        let summary = try await Self.summarize(
            Self.input(
                table,
                selecting: [GridRect(rows: 0...3, columns: 0...1)],
                inserted: [insertedID],
                modified: [.existing(2): [1]]
            )
        )

        #expect(summary.emptyCount == 3)
        #expect(summary.valueCount == 5)
        #expect(summary.notANumberCount == 1)
        #expect(summary.numbers?.count == 2)
        #expect(summary.numbers?.sum.decimal == 12)
    }

    @Test("empty text is empty where the policy says so, as a CSV cell is")
    func emptyTextIsEmptyForDataFiles() async throws {
        let table = Self.tableRows([[.text("")], [.text("3")], [.null]], types: [Self.untyped])
        let policy = SelectionSummaryColumnPolicy(rules: [.numericIfParsable], emptyTextIsEmpty: true)

        let summary = try await Self.summarize(
            Self.input(table, selecting: [GridRect(rows: 0...2, columns: 0...0)], policy: policy)
        )

        #expect(summary.emptyCount == 2)
        #expect(summary.valueCount == 1)
        #expect(summary.numbers?.sum.decimal == 3)
    }

    @Test("NaN, Infinity and money text in a numeric column are counted as not a number")
    func nonNumbersInNumericColumn() async throws {
        let values = ["1.5", "NaN", "Infinity", "$1,234.56", "2.5"]
        let table = Self.tableRows(
            values.map { [.text($0), .text($0)] },
            types: [.decimal(rawType: "NUMERIC"), Self.untyped]
        )

        let numeric = try await Self.summarize(Self.input(table, selecting: [GridRect(rows: 0...4, columns: 0...0)]))
        let untyped = try await Self.summarize(Self.input(table, selecting: [GridRect(rows: 0...4, columns: 1...1)]))

        #expect(numeric.valueCount == 5)
        #expect(numeric.notANumberCount == 3)
        #expect(numeric.numbers?.count == 2)
        #expect(numeric.numbers?.sum.decimal == 4)
        #expect(untyped.notANumberCount == 0)
        #expect(untyped.numbers?.count == 2)
    }

    @Test("digits in a typed VARCHAR column are counted, never summed")
    func typedTextColumnIsNotSummed() async throws {
        let table = Self.tableRows([[.text("00501")], [.text("00502")]], types: [.text(rawType: "VARCHAR(10)")])

        let summary = try await Self.summarize(Self.input(table, selecting: [GridRect(rows: 0...1, columns: 0...0)]))

        #expect(summary.valueCount == 2)
        #expect(summary.numbers == nil)
        #expect(summary.notANumberCount == 0)
    }

    @Test("an untyped column is summed where its text parses as a number")
    func untypedColumnIsParsed() async throws {
        let table = Self.tableRows(
            [[.text("5"), .text("1")], [.text("7"), .text("2")], [.text("abc"), .text("x")]],
            types: [Self.untyped, .text(rawType: "")]
        )

        let summary = try await Self.summarize(Self.input(table, selecting: [GridRect(rows: 0...2, columns: 0...1)]))

        #expect(summary.valueCount == 6)
        #expect(summary.notANumberCount == 0)
        #expect(summary.numbers?.count == 4)
        #expect(summary.numbers?.sum.decimal == 15)
    }

    @Test("a number padded with a non-breaking space is summed, as Column Statistics sums it")
    func unicodePaddedNumberIsSummed() async throws {
        let table = Self.tableRows([[.text("\u{00A0}7")], [.text("1")]], types: [Self.integer])

        let summary = try await Self.summarize(Self.input(table, selecting: [GridRect(rows: 0...1, columns: 0...0)]))

        #expect(summary.notANumberCount == 0)
        #expect(summary.numbers?.sum.decimal == 8)
    }

    @Test("0.99 added a hundred times is exactly 99")
    func decimalSumIsExact() async throws {
        let table = Self.tableRows(Array(repeating: [.text("0.99")], count: 100), types: [.decimal(rawType: "REAL")])

        let summary = try await Self.summarize(Self.input(table, selecting: [GridRect(rows: 0...99, columns: 0...0)]))

        let sum = try #require(summary.numbers?.sum)
        #expect(!sum.isApproximate)
        #expect(sum.decimal == Decimal(99))
        #expect(summary.numbers?.mean.decimal == Decimal(string: "0.99"))
    }

    @Test("binary cells count as values and never as not a number")
    func bytesCountAsValues() async throws {
        let table = Self.tableRows([[.bytes(Data([0x01]))], [.text("4")]], types: [Self.integer])

        let summary = try await Self.summarize(Self.input(table, selecting: [GridRect(rows: 0...1, columns: 0...0)]))

        #expect(summary.valueCount == 2)
        #expect(summary.notANumberCount == 0)
        #expect(summary.numbers?.count == 1)
    }

    @Test("a column picked by its heading is reported as covering the whole column")
    func headingPickCoversWholeColumn() async throws {
        let table = Self.tableRows([[.text("1")], [.text("2")]], types: [Self.integer])
        let picked = SelectionSummaryInput(
            selection: .column(0, totalRows: 2),
            tableRows: table,
            dataColumnsByDisplayPosition: [0],
            policy: .derived(columnTypes: table.columnTypes, displayFormats: [], columnCount: 1)
        )

        let whole = try await Self.summarize(picked)
        let swept = try await Self.summarize(Self.input(table, selecting: [GridRect(rows: 0...1, columns: 0...0)]))

        #expect(whole.coversWholeColumn)
        #expect(!swept.coversWholeColumn)
        #expect(whole.numbers?.sum.decimal == 3)
    }

    @Test("a cancelled run throws instead of returning a partial summary")
    @MainActor
    func cancelledRunThrows() async {
        let table = Self.tableRows(Array(repeating: [.text("1")], count: 10_000), types: [Self.integer])
        let input = Self.input(table, selecting: [GridRect(rows: 0...9_999, columns: 0...0)])
        let calculator = SelectionSummaryCalculator()

        /// Main-actor bound, so it cannot start before the cancel below lands.
        let task = Task { @MainActor in
            try await calculator.summarize(input)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test("rules come from the column type, and a display format leaves a column count only")
    func derivedPolicy() {
        let policy = SelectionSummaryColumnPolicy.derived(
            columnTypes: [
                .integer(rawType: "INT"),
                .decimal(rawType: "NUMERIC"),
                .text(rawType: nil),
                .text(rawType: ""),
                .text(rawType: "VARCHAR(10)"),
                .date(rawType: "DATE"),
                .integer(rawType: "BIGINT"),
                .boolean(rawType: "BOOL")
            ],
            displayFormats: [nil, .raw, nil, nil, nil, nil, .unixTimestamp],
            columnCount: 8
        )

        #expect(policy.rules == [
            .numeric, .numeric, .numericIfParsable, .numericIfParsable, .countOnly, .countOnly, .countOnly, .countOnly
        ])
        #expect(!policy.emptyTextIsEmpty)
        #expect(policy.rule(forColumn: 99) == .countOnly)
    }
}
