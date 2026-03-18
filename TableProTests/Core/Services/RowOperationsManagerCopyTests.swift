//
//  RowOperationsManagerCopyTests.swift
//  TableProTests
//
//  Regression tests for RowOperationsManager copy optimization (P2-6).
//  Validates TSV formatting, NULL handling, and large-row correctness.
//

import Foundation
@testable import TablePro
import Testing

private final class MockClipboardProvider: ClipboardProvider {
    var lastWrittenText: String?
    var textToRead: String?

    func readText() -> String? { textToRead }

    func writeText(_ text: String) {
        lastWrittenText = text
    }

    var hasText: Bool { textToRead != nil }
}

@MainActor
@Suite("RowOperationsManager Copy")
struct RowOperationsManagerCopyTests {
    // MARK: - Helpers

    private func makeManager() -> (RowOperationsManager, DataChangeManager) {
        let changeManager = DataChangeManager()
        changeManager.configureForTable(
            tableName: "users",
            columns: ["id", "name", "email"],
            primaryKeyColumn: "id",
            databaseType: .mysql
        )
        let manager = RowOperationsManager(changeManager: changeManager)
        return (manager, changeManager)
    }

    private func copyAndCapture(
        manager: RowOperationsManager,
        indices: Set<Int>,
        rows: [QueryResultRow],
        columns: [String] = [],
        includeHeaders: Bool = false
    ) -> String? {
        let clipboard = MockClipboardProvider()
        ClipboardService.shared = clipboard
        manager.copySelectedRowsToClipboard(
            selectedIndices: indices,
            resultRows: rows,
            columns: columns,
            includeHeaders: includeHeaders
        )
        return clipboard.lastWrittenText
    }

    // MARK: - Single Row TSV

    @Test("Single row copy produces tab-separated values")
    func singleRowTSV() {
        let (manager, _) = makeManager()
        let rows = [QueryResultRow(id: 0, values: ["1", "Alice", "alice@test.com"])]

        let result = copyAndCapture(manager: manager, indices: [0], rows: rows)

        #expect(result == "1\tAlice\talice@test.com")
    }

    // MARK: - Multiple Rows

    @Test("Multiple rows separated by newlines in TSV format")
    func multipleRowsTSV() {
        let (manager, _) = makeManager()
        let rows = [
            QueryResultRow(id: 0, values: ["1", "Alice", "a@test.com"]),
            QueryResultRow(id: 1, values: ["2", "Bob", "b@test.com"]),
        ]

        let result = copyAndCapture(manager: manager, indices: [0, 1], rows: rows)

        #expect(result == "1\tAlice\ta@test.com\n2\tBob\tb@test.com")
    }

    // MARK: - NULL Handling

    @Test("NULL values rendered as literal NULL string")
    func nullValuesRenderedAsNullString() {
        let (manager, _) = makeManager()
        let rows = [QueryResultRow(id: 0, values: [nil, "Alice", nil])]

        let result = copyAndCapture(manager: manager, indices: [0], rows: rows)

        #expect(result == "NULL\tAlice\tNULL")
    }

    @Test("Mixed NULL and non-NULL values in same row")
    func mixedNullAndNonNull() {
        let (manager, _) = makeManager()
        let rows = [
            QueryResultRow(id: 0, values: ["1", nil, "a@test.com"]),
            QueryResultRow(id: 1, values: [nil, "Bob", nil]),
        ]

        let result = copyAndCapture(manager: manager, indices: [0, 1], rows: rows)

        let lines = result?.components(separatedBy: "\n")
        #expect(lines?.count == 2)
        #expect(lines?[0] == "1\tNULL\ta@test.com")
        #expect(lines?[1] == "NULL\tBob\tNULL")
    }

    // MARK: - Empty Selection

    @Test("Empty selection produces no clipboard write")
    func emptySelectionNoWrite() {
        let (manager, _) = makeManager()
        let rows = TestFixtures.makeQueryResultRows(count: 3)
        let clipboard = MockClipboardProvider()
        ClipboardService.shared = clipboard

        manager.copySelectedRowsToClipboard(
            selectedIndices: [],
            resultRows: rows
        )

        #expect(clipboard.lastWrittenText == nil)
    }

    // MARK: - Large Row Count

    @Test("Large row count produces correct first and last rows")
    func largeRowCount() {
        let (manager, _) = makeManager()
        let count = 1_000
        let rows = (0..<count).map { i in
            QueryResultRow(id: i, values: ["\(i)", "name_\(i)", "email_\(i)"])
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

    // MARK: - Row Ordering

    @Test("Copied rows are in sorted index order regardless of selection order")
    func rowsInSortedOrder() {
        let (manager, _) = makeManager()
        let rows = [
            QueryResultRow(id: 0, values: ["A"]),
            QueryResultRow(id: 1, values: ["B"]),
            QueryResultRow(id: 2, values: ["C"]),
        ]

        let result = copyAndCapture(manager: manager, indices: [2, 0], rows: rows)

        #expect(result == "A\nC")
    }

    // MARK: - Include Headers

    @Test("Copy with headers prepends column names as first TSV line")
    func copyWithHeaders() {
        let (manager, _) = makeManager()
        let rows = [QueryResultRow(id: 0, values: ["1", "Alice", "a@test.com"])]

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

    // MARK: - Out-of-Bounds Index

    @Test("Out-of-bounds indices are skipped gracefully")
    func outOfBoundsIndicesSkipped() {
        let (manager, _) = makeManager()
        let rows = [QueryResultRow(id: 0, values: ["1", "Alice"])]

        let result = copyAndCapture(manager: manager, indices: [0, 5, 10], rows: rows)

        #expect(result == "1\tAlice")
    }

    // MARK: - All NULL Row

    @Test("Row with all NULL values produces tab-separated NULL strings")
    func allNullRow() {
        let (manager, _) = makeManager()
        let rows = [QueryResultRow(id: 0, values: [nil, nil, nil])]

        let result = copyAndCapture(manager: manager, indices: [0], rows: rows)

        #expect(result == "NULL\tNULL\tNULL")
    }
}
