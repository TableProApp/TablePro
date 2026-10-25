//
//  ResultComparisonGridModelTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct ResultComparisonGridModelTests {
    private static func side(_ columns: [String], _ rows: [[String]]) -> ResultComparisonSide {
        ResultComparisonSide(
            title: "Result",
            detail: "Query",
            columns: columns,
            rows: ContiguousArray(rows.enumerated().map { index, values in
                Row(id: .existing(index), values: ContiguousArray(values.map(PluginCellValue.text)))
            })
        )
    }

    private static let left = side(["id", "name"], [["1", "a"], ["2", "x"], ["4", "d"]])
    private static let right = side(["name", "id"], [["a", "1"], ["b", "2"], ["c", "3"]])
    private static let pairing = ResultColumnPairing(left: left.columns, right: right.columns)

    private static func comparison() throws -> ResultComparison {
        try ResultComparisonEngine.compare(left: left, right: right, pairing: pairing, keyPairs: [0])
    }

    @Test("A changed row draws both lines, every other row one")
    func linesPerKind() throws {
        let lines = ResultComparisonGridModel.lines(for: try Self.comparison().entries)

        #expect(lines.map(\.entry.kind) == [.same, .changed, .changed, .onlyLeft, .onlyRight])
        #expect(lines.map(\.isLeft) == [true, true, false, true, false])
    }

    @Test("Only left reads as new, only right as removed, and a changed value is marked on both lines")
    func marks() throws {
        let lines = ResultComparisonGridModel.lines(for: try Self.comparison().entries)
        let states = lines.map(ResultComparisonGridModel.visualState(for:))
        let nameColumn = 1 + ResultComparisonGridModel.leadingColumnCount

        #expect(states[0] == RowVisualState(isDeleted: false, isInserted: false, modifiedColumns: [], vocabulary: .resultComparison))
        #expect(states[1].modifiedColumns == [nameColumn])
        #expect(states[2].struckColumns == [nameColumn])
        #expect(states[3].isInserted)
        #expect(states[4].isDeleted)
        #expect(states.allSatisfy { $0.vocabulary == .resultComparison })
    }

    @Test("Each line shows its own side's values under the left result's column order")
    func valuesFollowTheLine() throws {
        let lines = ResultComparisonGridModel.lines(for: try Self.comparison().entries)
        let rows = ResultComparisonGridModel.tableRows(for: lines, left: Self.left, right: Self.right, pairing: Self.pairing)

        #expect(rows.columns == ["Status", "Side", "id", "name"])
        #expect(Array(rows.rows[1].values) == [.text("Changed"), .text("Left"), .text("2"), .text("x")])
        #expect(Array(rows.rows[2].values) == [.text("Changed"), .text("Right"), .text("2"), .text("b")])
        #expect(Array(rows.rows[4].values) == [.text("Only Right"), .text("Right"), .text("3"), .text("c")])
    }

    @Test("A field one document lacks stays absent on its line")
    func absentFieldsSurvive() {
        var lacking = Self.right.rows
        lacking[1].absentColumns = [0]
        let right = ResultComparisonSide(title: "Result", detail: "Query", columns: Self.right.columns, rows: lacking)
        let lines = [ResultComparisonGridLine(entry: ResultComparisonEntry(kind: .onlyRight, leftRow: nil, rightRow: 1), isLeft: false)]

        let rows = ResultComparisonGridModel.tableRows(for: lines, left: Self.left, right: right, pairing: Self.pairing)

        #expect(rows.rows[0].absentColumns == [1 + ResultComparisonGridModel.leadingColumnCount])
    }

    @Test("A DATE beside a TIMESTAMP draws as text, so the right line keeps its time")
    func mixedTemporalTypesDrawAsText() {
        let date = ColumnType.date(rawType: "DATE")
        let timestamp = ColumnType.timestamp(rawType: "TIMESTAMP")

        #expect(CompareRowGridModel.displayType(source: date, target: timestamp) == .text(rawType: nil))
        #expect(CompareRowGridModel.displayType(source: timestamp, target: .timestamp(rawType: "timestamp(6)")) == timestamp)
        #expect(CompareRowGridModel.displayType(source: nil, target: date) == date)
    }

    @Test("The row menu offers Copy as and a column header offers Display As")
    func offersCopyAsAndDisplayAs() throws {
        let comparison = try Self.comparison()
        let grid = ResultComparisonGridModel()
        grid.ensureLoaded(
            key: ResultComparisonGridModel.LoadKey(comparisonId: comparison.id, filter: .all),
            comparison: comparison, left: Self.left, right: Self.right, pairing: Self.pairing
        )
        let controller = DataGridViewController(model: grid.model)
        let name = try #require(grid.model.columns.columns.first { $0.name == "name" })

        let rowMenu = controller.rowMenu(forRow: 0, displayColumn: 3, in: .main)
        let headerMenu = controller.headerMenu(for: name)

        #expect(rowMenu?.items.contains { $0.title == String(localized: "Copy as") } == true)
        #expect(headerMenu?.items.contains { $0.title == String(localized: "Display As") } == true)
    }

    @Test("VoiceOver names the side rather than the sync direction")
    func accessibilityWords() {
        let onlyLeft = RowVisualState(isDeleted: false, isInserted: true, modifiedColumns: [], vocabulary: .resultComparison)
        let rightLine = RowVisualState(
            isDeleted: false, isInserted: false, modifiedColumns: [], struckColumns: [2], vocabulary: .resultComparison
        )

        #expect(DataGridCellTextMark.accessibilityDescription(state: onlyLeft, columnIndex: 2) == "only in the left result")
        #expect(DataGridCellTextMark.accessibilityDescription(state: rightLine, columnIndex: 2) == "right value, differs")
    }
}
