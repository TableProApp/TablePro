import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private final class PasteMockClipboard: ClipboardProvider {
    var textToRead: String?
    var gridRowsToRead: GridRowsClipboardPayload?

    func readText() -> String? { textToRead }
    func readGridRows() -> GridRowsClipboardPayload? { gridRowsToRead }
    func writeText(_ text: String) {}
    func writeCsv(_ csv: String) {}
    func writeRows(tsv: String, html: String?, gridRows: GridRowsClipboardPayload) {}
    var hasText: Bool { textToRead != nil }
    var hasGridRows: Bool { gridRowsToRead != nil }
}

@MainActor
@Suite("RowOperationsManager Paste")
struct RowOperationsManagerPasteTests {
    private static let columns = ["id", "name", "email"]

    private func makeManager() -> RowOperationsManager {
        let changeManager = DataChangeManager()
        changeManager.configureForTable(
            tableName: "users",
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            databaseType: .mysql
        )
        return RowOperationsManager(changeManager: changeManager)
    }

    private func emptyRows() -> TableRows {
        let types: [ColumnType] = Array(repeating: .text(rawType: nil), count: Self.columns.count)
        return TableRows.from(queryRows: [], columns: Self.columns, columnTypes: types)
    }

    private func pasteRows(_ clipboard: PasteMockClipboard, manager: RowOperationsManager) -> [[PluginCellValue]] {
        var rows = emptyRows()
        let result = manager.pasteRowsFromClipboard(
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            tableRows: &rows,
            clipboard: clipboard
        )
        return result.pastedRows.map { $0.values }
    }

    private func pasteValues(_ clipboard: PasteMockClipboard, manager: RowOperationsManager) -> [PluginCellValue] {
        pasteRows(clipboard, manager: manager).first ?? []
    }

    @Test("Structured grid rows preserve comma-containing values")
    func structuredPreservesCommas() {
        let clipboard = PasteMockClipboard()
        clipboard.gridRowsToRead = GridRowsClipboardPayload(
            columns: Self.columns,
            rows: [[.text("7"), .text("Smith, John"), .text("a@test.com")]]
        )

        let values = pasteValues(clipboard, manager: makeManager())

        #expect(values.count == 3)
        #expect(values[0] == .text("__DEFAULT__"))
        #expect(values[1] == .text("Smith, John"))
        #expect(values[2] == .text("a@test.com"))
    }

    @Test("Structured grid rows distinguish a real NULL from the literal string NULL")
    func structuredDistinguishesNull() {
        let clipboard = PasteMockClipboard()
        clipboard.gridRowsToRead = GridRowsClipboardPayload(
            columns: Self.columns,
            rows: [[.text("7"), .text("NULL"), .null]]
        )

        let values = pasteValues(clipboard, manager: makeManager())

        #expect(values[1] == .text("NULL"))
        #expect(values[2] == .null)
    }

    @Test("Structured payload wins over plain text when both are present")
    func structuredPreferredOverText() {
        let clipboard = PasteMockClipboard()
        clipboard.gridRowsToRead = GridRowsClipboardPayload(
            columns: Self.columns,
            rows: [[.text("7"), .text("structured"), .text("x@test.com")]]
        )
        clipboard.textToRead = "7\twrong\twrong@test.com"

        let values = pasteValues(clipboard, manager: makeManager())

        #expect(values[1] == .text("structured"))
    }

    @Test("Structured grid rows map source columns to destination by name when reordered")
    func structuredMapsByColumnName() {
        let clipboard = PasteMockClipboard()
        clipboard.gridRowsToRead = GridRowsClipboardPayload(
            columns: ["email", "id", "name"],
            rows: [[.text("e@x.com"), .text("9"), .text("Jo")]]
        )

        let values = pasteValues(clipboard, manager: makeManager())

        #expect(values[0] == .text("__DEFAULT__"))
        #expect(values[1] == .text("Jo"))
        #expect(values[2] == .text("e@x.com"))
    }

    @Test("Destination columns absent from the source fill with NULL (e.g. a hidden column copy)")
    func structuredFillsMissingColumnsWithNull() {
        let clipboard = PasteMockClipboard()
        clipboard.gridRowsToRead = GridRowsClipboardPayload(
            columns: ["name", "email"],
            rows: [[.text("Jo"), .text("e@x.com")]]
        )

        let values = pasteValues(clipboard, manager: makeManager())

        #expect(values.count == 3)
        #expect(values[0] == .text("__DEFAULT__"))
        #expect(values[1] == .text("Jo"))
        #expect(values[2] == .text("e@x.com"))
    }

    @Test("Unrelated source columns fall back to positional mapping")
    func structuredFallsBackToPositional() {
        let clipboard = PasteMockClipboard()
        clipboard.gridRowsToRead = GridRowsClipboardPayload(
            columns: ["a", "b", "c"],
            rows: [[.text("1"), .text("2"), .text("3")]]
        )

        let values = pasteValues(clipboard, manager: makeManager())

        #expect(values[0] == .text("__DEFAULT__"))
        #expect(values[1] == .text("2"))
        #expect(values[2] == .text("3"))
    }

    @Test("Structured payload pastes multiple rows")
    func structuredPastesMultipleRows() {
        let clipboard = PasteMockClipboard()
        clipboard.gridRowsToRead = GridRowsClipboardPayload(
            columns: Self.columns,
            rows: [
                [.text("1"), .text("Alice"), .text("a@test.com")],
                [.text("2"), .text("Bob"), .null],
            ]
        )

        let rows = pasteRows(clipboard, manager: makeManager())

        #expect(rows.count == 2)
        #expect(rows[0] == [.text("__DEFAULT__"), .text("Alice"), .text("a@test.com")])
        #expect(rows[1] == [.text("__DEFAULT__"), .text("Bob"), .null])
    }

    @Test("Plain-text TSV with commas inside a value parses as TSV, not CSV")
    func textTSVWithCommasParsesAsTSV() {
        let clipboard = PasteMockClipboard()
        clipboard.textToRead = "7\tMozilla/5.0 (KHTML, like Gecko) Safari\ta@test.com"

        let values = pasteValues(clipboard, manager: makeManager())

        #expect(values.count == 3)
        #expect(values[0] == .text("__DEFAULT__"))
        #expect(values[1] == .text("Mozilla/5.0 (KHTML, like Gecko) Safari"))
        #expect(values[2] == .text("a@test.com"))
    }

    @Test("detectParser picks TSV when a tab is present even alongside commas")
    func detectParserTabWins() {
        #expect(RowOperationsManager.detectParser(for: "a\tb,c") is TSVRowParser)
        #expect(RowOperationsManager.detectParser(for: "a,b\tc") is TSVRowParser)
    }

    @Test("detectParser picks CSV only when commas appear without tabs")
    func detectParserCsvWhenNoTabs() {
        #expect(RowOperationsManager.detectParser(for: "a,b,c") is CSVRowParser)
    }

    @Test("detectParser defaults to TSV for single-column text")
    func detectParserDefaultsToTSV() {
        #expect(RowOperationsManager.detectParser(for: "single") is TSVRowParser)
    }
}
