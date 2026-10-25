import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

extension GlobalStateSuites {
    @Suite(.recordingClipboard)
    @MainActor
    struct RowOperationsManagerCopyTests {
        private static let defaultColumns = ["id", "name", "email"]

        private func makeManager() -> (RowOperationsManager, DataChangeManager) {
            let changeManager = DataChangeManager()
            changeManager.configureForTable(
                tableName: "users",
                columns: Self.defaultColumns,
                primaryKeyColumns: ["id"],
                databaseType: .mysql,
                generatedColumns: []
            )
            let manager = RowOperationsManager(changeManager: changeManager)
            return (manager, changeManager)
        }

        private func makeTableRows(rows: [[String?]], columns: [String]? = nil) -> TableRows {
            let cols = columns ?? Self.defaultColumns
            let columnTypes: [ColumnType] = Array(repeating: .text(rawType: nil), count: cols.count)
            return TableRows.from(queryRows: rows.map { row in row.map(PluginCellValue.fromOptional) }, columns: cols, columnTypes: columnTypes)
        }

        // The rows a grid selection names, in display order, which is how the grid hands them over.
        private static func rowIDs(
            _ displayRows: IndexSet,
            in tableRows: TableRows,
            displayIDs: [RowID]? = nil
        ) -> [RowID] {
            DataGridRowOrder(filteredIDs: displayIDs, revision: 0).rowIDs(atDisplayIndexes: displayRows, in: tableRows)
        }

        private func copyAndCapture(
            manager: RowOperationsManager,
            indices: IndexSet,
            rows: [[String?]],
            columns: [String]? = nil,
            includeHeaders: Bool = false,
            visibleColumnIndices: [Int]? = nil
        ) throws -> String? {
            let clipboard = try #require(RecordingClipboard.current)
            let tableRows = makeTableRows(rows: rows, columns: columns ?? Self.defaultColumns)
            manager.copyRowsToClipboard(
                Self.rowIDs(indices, in: tableRows),
                tableRows: tableRows,
                includeHeaders: includeHeaders,
                visibleColumnIndices: visibleColumnIndices
            )
            return clipboard.writes.last
        }

        @Test("Single row copy produces tab-separated values")
        func singleRowTSV() throws {
            let (manager, _) = makeManager()
            let rows: [[String?]] = [["1", "Alice", "alice@test.com"]]

            let result = try copyAndCapture(manager: manager, indices: [0], rows: rows)

            #expect(result == "1\tAlice\talice@test.com")
        }

        @Test("Multiple rows separated by newlines in TSV format")
        func multipleRowsTSV() throws {
            let (manager, _) = makeManager()
            let rows: [[String?]] = [
                ["1", "Alice", "a@test.com"],
                ["2", "Bob", "b@test.com"],
            ]

            let result = try copyAndCapture(manager: manager, indices: [0, 1], rows: rows)

            #expect(result == "1\tAlice\ta@test.com\n2\tBob\tb@test.com")
        }

        @Test("NULL values rendered as literal NULL string")
        func nullValuesRenderedAsNullString() throws {
            let (manager, _) = makeManager()
            let rows: [[String?]] = [[nil, "Alice", nil]]

            let result = try copyAndCapture(manager: manager, indices: [0], rows: rows)

            #expect(result == "NULL\tAlice\tNULL")
        }

        @Test("Mixed NULL and non-NULL values in same row")
        func mixedNullAndNonNull() throws {
            let (manager, _) = makeManager()
            let rows: [[String?]] = [
                ["1", nil, "a@test.com"],
                [nil, "Bob", nil],
            ]

            let result = try copyAndCapture(manager: manager, indices: [0, 1], rows: rows)

            let lines = result?.components(separatedBy: "\n")
            #expect(lines?.count == 2)
            #expect(lines?[0] == "1\tNULL\ta@test.com")
            #expect(lines?[1] == "NULL\tBob\tNULL")
        }

        @Test("Empty selection produces no clipboard write")
        func emptySelectionNoWrite() throws {
            let (manager, _) = makeManager()
            let rows = TestFixtures.makeRows(count: 3)
            let clipboard = try #require(RecordingClipboard.current)
            let tableRows = makeTableRows(rows: rows)

            manager.copyRowsToClipboard([], tableRows: tableRows)

            #expect(clipboard.writes.last == nil)
        }

        @Test("Large row count produces correct first and last rows")
        func largeRowCount() throws {
            let (manager, _) = makeManager()
            let count = 1_000
            let rows: [[String?]] = (0..<count).map { i in
                ["\(i)", "name_\(i)", "email_\(i)"]
            }

            let result = try copyAndCapture(
                manager: manager,
                indices: IndexSet(integersIn: 0..<count),
                rows: rows
            )

            let lines = result?.components(separatedBy: "\n") ?? []
            #expect(lines.count == count)
            #expect(lines.first == "0\tname_0\temail_0")
            #expect(lines.last == "\(count - 1)\tname_\(count - 1)\temail_\(count - 1)")
        }

        @Test("Copied rows follow display order regardless of selection order")
        func rowsInSortedOrder() throws {
            let (manager, _) = makeManager()
            let rows: [[String?]] = [
                ["A"],
                ["B"],
                ["C"],
            ]

            let result = try copyAndCapture(manager: manager, indices: [2, 0], rows: rows, columns: ["letter"])

            #expect(result == "A\nC")
        }

        @Test("Copy with headers prepends column names as first TSV line")
        func copyWithHeaders() throws {
            let (manager, _) = makeManager()
            let rows: [[String?]] = [["1", "Alice", "a@test.com"]]

            let result = try copyAndCapture(
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

        @Test("Display positions past the rows are skipped")
        func outOfBoundsIndicesSkipped() throws {
            let (manager, _) = makeManager()
            let rows: [[String?]] = [["1", "Alice"]]

            let result = try copyAndCapture(manager: manager, indices: [0, 5, 10], rows: rows, columns: ["id", "name"])

            #expect(result == "1\tAlice")
        }

        @Test("Row with all NULL values produces tab-separated NULL strings")
        func allNullRow() throws {
            let (manager, _) = makeManager()
            let rows: [[String?]] = [[nil, nil, nil]]

            let result = try copyAndCapture(manager: manager, indices: [0], rows: rows)

            #expect(result == "NULL\tNULL\tNULL")
        }

        @Test("Hidden columns are excluded from copied values")
        func hiddenColumnsExcluded() throws {
            let (manager, _) = makeManager()
            let rows: [[String?]] = [["1", "Alice", "alice@test.com"]]

            let result = try copyAndCapture(manager: manager, indices: [0], rows: rows, visibleColumnIndices: [0, 2])

            #expect(result == "1\talice@test.com")
        }

        @Test("Hidden columns are excluded from headers too")
        func hiddenColumnsExcludedFromHeaders() throws {
            let (manager, _) = makeManager()
            let rows: [[String?]] = [["1", "Alice", "alice@test.com"]]

            let result = try copyAndCapture(
                manager: manager,
                indices: [0],
                rows: rows,
                includeHeaders: true,
                visibleColumnIndices: [0, 2]
            )

            let lines = result?.components(separatedBy: "\n") ?? []
            #expect(lines.count == 2)
            #expect(lines[0] == "id\temail")
            #expect(lines[1] == "1\talice@test.com")
        }

        @Test("Copy follows visual column order")
        func copyFollowsVisualOrder() throws {
            let (manager, _) = makeManager()
            let rows: [[String?]] = [["1", "Alice", "alice@test.com"]]

            let result = try copyAndCapture(
                manager: manager,
                indices: [0],
                rows: rows,
                includeHeaders: true,
                visibleColumnIndices: [2, 0, 1]
            )

            let lines = result?.components(separatedBy: "\n") ?? []
            #expect(lines[0] == "email\tid\tname")
            #expect(lines[1] == "alice@test.com\t1\tAlice")
        }

        @Test("Nil visible indices copies every column unchanged")
        func nilIndicesCopiesAllColumns() throws {
            let (manager, _) = makeManager()
            let rows: [[String?]] = [["1", "Alice", "alice@test.com"]]

            let result = try copyAndCapture(manager: manager, indices: [0], rows: rows, visibleColumnIndices: nil)

            #expect(result == "1\tAlice\talice@test.com")
        }

        @Test("Copy writes structured grid rows with column names and raw cell values")
        func copyWritesStructuredGridRows() throws {
            let (manager, _) = makeManager()
            let rows: [[String?]] = [["1", "Smith, John", nil]]
            let clipboard = try #require(RecordingClipboard.current)
            let tableRows = makeTableRows(rows: rows)

            manager.copyRowsToClipboard([.existing(0)], tableRows: tableRows)

            #expect(clipboard.gridRows?.columns == ["id", "name", "email"])
            #expect(clipboard.gridRows?.rows == [[.text("1"), .text("Smith, John"), .null]])
        }

        @Test("Structured grid rows follow visible column projection and visual order")
        func structuredGridRowsFollowProjection() throws {
            let (manager, _) = makeManager()
            let rows: [[String?]] = [["1", "Alice", "alice@test.com"]]
            let clipboard = try #require(RecordingClipboard.current)
            let tableRows = makeTableRows(rows: rows)

            manager.copyRowsToClipboard([.existing(0)], tableRows: tableRows, visibleColumnIndices: [2, 0])

            #expect(clipboard.gridRows?.columns == ["email", "id"])
            #expect(clipboard.gridRows?.rows == [[.text("alice@test.com"), .text("1")]])
        }

        @Test("Copy under a display filter reads the underlying row, not the raw position")
        func copyResolvesDisplayIndexUnderFilter() throws {
            let (manager, _) = makeManager()
            let rows: [[String?]] = [
                ["1", "Alice", "a@test.com"],
                ["2", "Bob", "b@test.com"],
                ["3", "Carol", "c@test.com"],
                ["4", "Dave", "d@test.com"],
            ]
            let clipboard = try #require(RecordingClipboard.current)
            let tableRows = makeTableRows(rows: rows)
            let displayIDs: [RowID] = [.existing(0), .existing(2), .existing(3)]

            manager.copyRowsToClipboard(Self.rowIDs([1], in: tableRows, displayIDs: displayIDs), tableRows: tableRows)

            #expect(clipboard.writes.last == "3\tCarol\tc@test.com")
        }

        @Test("Copy under a display filter emits rows in display order")
        func copyEmitsDisplayOrderUnderFilter() throws {
            let (manager, _) = makeManager()
            let rows: [[String?]] = [
                ["1", "Alice", "a@test.com"],
                ["2", "Bob", "b@test.com"],
                ["3", "Carol", "c@test.com"],
            ]
            let clipboard = try #require(RecordingClipboard.current)
            let tableRows = makeTableRows(rows: rows)
            let displayIDs: [RowID] = [.existing(2), .existing(0)]

            manager.copyRowsToClipboard(Self.rowIDs([0, 1], in: tableRows, displayIDs: displayIDs), tableRows: tableRows)

            #expect(clipboard.writes.last == "3\tCarol\tc@test.com\n1\tAlice\ta@test.com")
        }
    }
}
