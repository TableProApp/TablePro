import Foundation
import TableProPluginKit
@testable import TablePro
import Testing

private final class MockClipboardProvider: ClipboardProvider {
    var lastWrittenText: String?
    var textToRead: String?
    var lastWasGridRows = false

    func readText() -> String? { textToRead }

    func writeText(_ text: String) {
        lastWrittenText = text
        lastWasGridRows = false
    }

    func writeRows(tsv: String, html: String?) {
        lastWrittenText = tsv
        lastWasGridRows = true
    }

    var hasText: Bool { textToRead != nil }
    var hasGridRows: Bool { lastWasGridRows }
}

@MainActor
@Suite("RowOperationsManager Copy")
struct RowOperationsManagerCopyTests {
    private static let defaultColumns = ["id", "name", "email"]

    private func makeManager() -> (RowOperationsManager, DataChangeManager) {
        let changeManager = DataChangeManager()
        changeManager.configureForTable(
            tableName: "users",
            columns: Self.defaultColumns,
            primaryKeyColumns: ["id"],
            databaseType: .mysql
        )
        let manager = RowOperationsManager(changeManager: changeManager)
        return (manager, changeManager)
    }

    private func makeTableRows(rows: [[String?]], columns: [String]? = nil) -> TableRows {
        let cols = columns ?? Self.defaultColumns
        let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: cols.count)
        return TableRows.from(queryRows: rows.map { row in row.map(PluginCellValue.fromOptional) }, columns: cols, columnTypes: columnTypes)
    }

    private func copyAndCapture(
        manager: RowOperationsManager,
        indices: Set<Int>,
        rows: [[String?]],
        columns: [String]? = nil,
        includeHeaders: Bool = false
    ) -> String? {
        let clipboard = MockClipboardProvider()
        ClipboardService.shared = clipboard
        let tableRows = makeTableRows(rows: rows, columns: columns ?? Self.defaultColumns)
        manager.copySelectedRowsToClipboard(
            selectedIndices: indices,
            tableRows: tableRows,
            includeHeaders: includeHeaders
        )
        return clipboard.lastWrittenText
    }

    @Test("Single row copy produces tab-separated values")
    func singleRowTSV() {
        let (manager, _) = makeManager()
        let rows: [[String?]] = [["1", "Alice", "alice@test.com"]]

        let result = copyAndCapture(manager: manager, indices: [0], rows: rows)

        #expect(result == "1\tAlice\talice@test.com")
    }

    @Test("Multiple rows separated by newlines in TSV format")
    func multipleRowsTSV() {
        let (manager, _) = makeManager()
        let rows: [[String?]] = [
            ["1", "Alice", "a@test.com"],
            ["2", "Bob", "b@test.com"],
        ]

        let result = copyAndCapture(manager: manager, indices: [0, 1], rows: rows)

        #expect(result == "1\tAlice\ta@test.com\n2\tBob\tb@test.com")
    }

    @Test("NULL values rendered as literal NULL string")
    func nullValuesRenderedAsNullString() {
        let (manager, _) = makeManager()
        let rows: [[String?]] = [[nil, "Alice", nil]]

        let result = copyAndCapture(manager: manager, indices: [0], rows: rows)

        #expect(result == "NULL\tAlice\tNULL")
    }

    @Test("Mixed NULL and non-NULL values in same row")
    func mixedNullAndNonNull() {
        let (manager, _) = makeManager()
        let rows: [[String?]] = [
            ["1", nil, "a@test.com"],
            [nil, "Bob", nil],
        ]

        let result = copyAndCapture(manager: manager, indices: [0, 1], rows: rows)

        let lines = result?.components(separatedBy: "\n")
        #expect(lines?.count == 2)
        #expect(lines?[0] == "1\tNULL\ta@test.com")
        #expect(lines?[1] == "NULL\tBob\tNULL")
    }

    @Test("Empty selection produces no clipboard write")
    func emptySelectionNoWrite() {
        let (manager, _) = makeManager()
        let rows = TestFixtures.makeRows(count: 3)
        let clipboard = MockClipboardProvider()
        ClipboardService.shared = clipboard
        let tableRows = makeTableRows(rows: rows)

        manager.copySelectedRowsToClipboard(
            selectedIndices: [],
            tableRows: tableRows
        )

        #expect(clipboard.lastWrittenText == nil)
    }

    @Test("Large row count produces correct first and last rows")
    func largeRowCount() {
        let (manager, _) = makeManager()
        let count = 1_000
        let rows: [[String?]] = (0..<count).map { i in
            ["\(i)", "name_\(i)", "email_\(i)"]
        }

        let result = copyAndCapture(
            manager: manager,
            indices: Set(0..<count),
            rows: rows
        )

        let lines = result?.components(separatedBy: "\n") ?? []
        #expect(lines.count == count)
        #expect(lines.first == "0\tname_0\temail_0")
        #expect(lines.last == "\(count - 1)\tname_\(count - 1)\temail_\(count - 1)")
    }

    @Test("Copied rows are in sorted index order regardless of selection order")
    func rowsInSortedOrder() {
        let (manager, _) = makeManager()
        let rows: [[String?]] = [
            ["A"],
            ["B"],
            ["C"],
        ]

        let result = copyAndCapture(manager: manager, indices: [2, 0], rows: rows, columns: ["letter"])

        #expect(result == "A\nC")
    }

    @Test("Copy with headers prepends column names as first TSV line")
    func copyWithHeaders() {
        let (manager, _) = makeManager()
        let rows: [[String?]] = [["1", "Alice", "a@test.com"]]

        let result = copyAndCapture(
            manager: manager,
            indices: [0],
            rows: rows,
            columns: ["id", "name", "email"],
            includeHeaders: true
        )

        let lines = result?.components(separatedBy: "\n") ?? []
        #expect(lines.count == 2)
        #expect(lines[0] == "id\tname\temail")
        #expect(lines[1] == "1\tAlice\ta@test.com")
    }

    @Test("Out-of-bounds indices are skipped gracefully")
    func outOfBoundsIndicesSkipped() {
        let (manager, _) = makeManager()
        let rows: [[String?]] = [["1", "Alice"]]

        let result = copyAndCapture(manager: manager, indices: [0, 5, 10], rows: rows, columns: ["id", "name"])

        #expect(result == "1\tAlice")
    }

    @Test("Row with all NULL values produces tab-separated NULL strings")
    func allNullRow() {
        let (manager, _) = makeManager()
        let rows: [[String?]] = [[nil, nil, nil]]

        let result = copyAndCapture(manager: manager, indices: [0], rows: rows)

        #expect(result == "NULL\tNULL\tNULL")
    }
}
