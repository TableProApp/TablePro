import Foundation
@testable import TableProTabular
import TableProTabularIO
import XCTest

final class TabularEditingTests: XCTestCase {
    private func table(_ text: String) async throws -> TabularTable {
        TabularTable(source: try await TabularTableTests.delimitedSource(text), usesFirstRowAsHeader: true)
    }

    private func texts(_ table: TabularTable, column: Int) -> [String] {
        (0..<table.rowCount).map { table.cell(row: $0, column: column).text }
    }

    private func applying(_ values: [TabularColumnID: ColumnValues], to table: TabularTable) -> TabularTable {
        var updated = table
        for (id, columnValues) in values {
            updated.replaceValues(of: id, with: columnValues)
        }
        return updated
    }

    func testStatisticsCountDistinctEmptyAndNumbers() async throws {
        let table = try await table("n\n3\n1\n\n3\nx\n")
        let summary = try await TabularColumnStatistics.summarize(
            column: table.columns[0].id,
            kind: .integer,
            rows: Array(0..<table.rowCount),
            in: table
        )
        XCTAssertEqual(summary.rowCount, 5)
        XCTAssertEqual(summary.emptyCount, 1)
        XCTAssertEqual(summary.distinctCount, 4)
        XCTAssertEqual(summary.nonNumericCount, 1)
        XCTAssertEqual(summary.numeric?.minimum, 1)
        XCTAssertEqual(summary.numeric?.maximum, 3)
        XCTAssertEqual(summary.numeric?.median, 3)
        XCTAssertEqual(summary.numeric?.sum, 7)
        XCTAssertEqual(summary.topValues.first, TabularValueCount(value: "3", isEmpty: false, count: 2))
    }

    func testFindHonoursCaseWholeWordsAndRegex() async throws {
        let table = try await table("a,b\ncat,Category\nCAT,dog\nconcat,cat5\n")
        let all = Array(0..<table.rowCount)
        let plain = try await TabularFinder.findAll(TabularFindQuery(text: "cat", columns: table.columnIDs), rows: all, in: table)
        XCTAssertEqual(plain.count, 5)
        let cased = try await TabularFinder.findAll(
            TabularFindQuery(text: "cat", matchesCase: true, columns: table.columnIDs),
            rows: all,
            in: table
        )
        XCTAssertEqual(cased.count, 3)
        let words = try await TabularFinder.findAll(
            TabularFindQuery(text: "cat", matchesWholeWords: true, columns: table.columnIDs),
            rows: all,
            in: table
        )
        XCTAssertEqual(words.map(\.row), [0, 1])
        let regex = try await TabularFinder.findAll(
            TabularFindQuery(text: "^c.t\\d$", isRegularExpression: true, columns: table.columnIDs),
            rows: all,
            in: table
        )
        XCTAssertEqual(regex, [TabularFindMatch(row: 2, column: table.columns[1].id)])
        XCTAssertThrowsError(try TabularFindMatcher(TabularFindQuery(text: "(", isRegularExpression: true, columns: [])))
    }

    func testReplaceAllRewritesOnlyMatchingCellsAndKeepsEditsInScope() async throws {
        var table = try await table("a\nfoo bar\nbaz\nfoo\n")
        table.setCell(.text("foo edited"), row: 1, column: 0)
        let result = try await TabularFinder.replaceAll(
            TabularFindQuery(text: "(fo)o", isRegularExpression: true, columns: table.columnIDs),
            with: "$1x",
            rows: Array(0..<table.rowCount),
            in: table
        )
        XCTAssertEqual(result.changedCells, 3)
        XCTAssertEqual(result.replacements, 3)
        let updated = applying(result.values, to: table)
        XCTAssertEqual(texts(updated, column: 0), ["fox bar", "fox edited", "fox"])
        XCTAssertTrue(updated.columns[0].values.edits.isEmpty)
    }

    func testLiteralReplaceTreatsDollarSignsAsText() async throws {
        let table = try await table("a\nprice 5\n")
        let result = try await TabularFinder.replaceAll(
            TabularFindQuery(text: "5", columns: table.columnIDs),
            with: "$1",
            rows: Array(0..<table.rowCount),
            in: table
        )
        XCTAssertEqual(texts(applying(result.values, to: table), column: 0), ["price $1"])
    }

    func testCleanupOperationsReportChangedCells() async throws {
        let table = try await table("a,b\n  x  ,1\ny,2\n\t z ,3\n")
        let all = Array(0..<table.rowCount)
        let trimmed = try await TabularCleanup.apply(.trimWhitespace, columns: [table.columns[0].id], rows: all, in: table)
        XCTAssertEqual(trimmed.changedCells, 2)
        XCTAssertEqual(texts(applying(trimmed.values, to: table), column: 0), ["x", "y", "z"])

        let upper = try await TabularCleanup.apply(.changeCase(.uppercase), columns: [table.columns[0].id], rows: [1], in: table)
        XCTAssertEqual(texts(applying(upper.values, to: table), column: 0), ["  x  ", "Y", "\t z "])

        let filled = try await TabularCleanup.apply(.fillDown, columns: [table.columns[1].id], rows: [0, 1, 2], in: table)
        XCTAssertEqual(filled.changedCells, 2)
        XCTAssertEqual(texts(applying(filled.values, to: table), column: 1), ["1", "1", "1"])

        let everywhere = try await TabularCleanup.apply(.setValue("k"), columns: [table.columns[1].id], rows: all, in: table)
        XCTAssertEqual(everywhere.changedCells, 3)
        XCTAssertEqual(texts(applying(everywhere.values, to: table), column: 1), ["k", "k", "k"])
    }

    func testDuplicateRowsKeepTheFirstOccurrence() async throws {
        let table = try await table("a,b\nx,1\nX ,1\nx,1\ny,2\n")
        let all = Array(0..<table.rowCount)
        let exact = try await TabularDuplicates.duplicateRows(comparing: table.columnIDs, rows: all, in: table)
        XCTAssertEqual(exact, [2])
        let loose = try await TabularDuplicates.duplicateRows(
            comparing: table.columnIDs,
            rows: all,
            in: table,
            options: TabularDuplicateOptions(ignoresCase: true, ignoresSurroundingWhitespace: true)
        )
        XCTAssertEqual(loose, [1, 2])
    }

    func testTypeInferenceIsStrict() {
        XCTAssertEqual(TabularTypeInference.infer([(.text, "1"), (.text, "22")]), .integer)
        XCTAssertEqual(TabularTypeInference.infer([(.text, "007"), (.text, "12")]), .text)
        XCTAssertEqual(TabularTypeInference.infer([(.text, "1.5"), (.text, "2")]), .decimal)
        XCTAssertEqual(TabularTypeInference.infer([(.text, "NaN"), (.text, "2")]), .text)
        XCTAssertEqual(TabularTypeInference.infer([(.text, "0x1F")]), .text)
        XCTAssertEqual(TabularTypeInference.infer([(.text, "yes"), (.text, "No")]), .boolean)
        XCTAssertEqual(TabularTypeInference.infer([(.text, "2024-01-05"), (.text, "2024-02-10T10:00:00Z")]), .date)
        XCTAssertEqual(TabularTypeInference.infer([(.text, "05/01/2024")]), .text)
    }
}
