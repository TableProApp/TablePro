import Foundation
@testable import TableProTabular
import TableProTabularIO
import XCTest

final class TabularQueryTests: XCTestCase {
    private func table(_ text: String) async throws -> TabularTable {
        TabularTable(source: try await TabularTableTests.delimitedSource(text), usesFirstRowAsHeader: true)
    }

    private func operand(_ text: String) -> TabularOperand {
        TabularOperand(text: text, number: TabularValueGrammar.number(text), boolean: TabularValueGrammar.boolean(text))
    }

    private func matches(_ table: TabularTable, _ predicate: TabularRowPredicate) async throws -> [Int] {
        try await TabularScanEngine.matchingRows(in: table, matcher: TabularRowMatcher(predicate: predicate))
    }

    private func expect(
        _ table: TabularTable,
        _ predicate: TabularRowPredicate,
        _ expected: [Int],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let actual = try await matches(table, predicate)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func cell(
        _ table: TabularTable,
        _ column: Int,
        _ comparison: TabularComparison,
        _ value: String,
        kind: TabularValueKind = .text,
        caseSensitive: Bool = false,
        second: String = "",
        list: [String] = []
    ) -> TabularRowPredicate {
        .cell(TabularCellPredicate(
            column: table.columns[column].id,
            comparison: comparison,
            valueKind: kind,
            operand: operand(value),
            secondOperand: operand(second),
            listOperands: list.map(operand),
            isCaseSensitive: caseSensitive
        ))
    }

    func testTextOperatorsFollowCaseSensitivity() async throws {
        let table = try await table("name\nAlice\nalice\nBob\n")
        try await expect(table, cell(table, 0, .equal, "ALICE"), [0, 1])
        try await expect(table, cell(table, 0, .equal, "ALICE", caseSensitive: true), [])
        try await expect(table, cell(table, 0, .contains, "LI"), [0, 1])
        try await expect(table, cell(table, 0, .notContains, "li"), [2])
        try await expect(table, cell(table, 0, .startsWith, "b"), [2])
        try await expect(table, cell(table, 0, .endsWith, "CE"), [0, 1])
    }

    func testNumericColumnsCompareAsNumbersAndFallBackToTextForOtherCells() async throws {
        let table = try await table("n\n5\n10\n5.0\nx\n\n")
        try await expect(table, cell(table, 0, .equal, "5", kind: .numeric), [0, 2])
        try await expect(table, cell(table, 0, .greaterThan, "6", kind: .numeric), [1, 3])
        try await expect(table, cell(table, 0, .between, "4", kind: .numeric, second: "6"), [0, 2])
        try await expect(table, cell(table, 0, .isEmpty, ""), [4])
        try await expect(table, cell(table, 0, .inList, "", kind: .numeric, list: ["10", "x"]), [1, 3])
    }

    func testOrderingOnATextColumnPrefersNumbersWhenBothSidesParse() async throws {
        let table = try await table("v\n9\n10\nabc\n")
        try await expect(table, cell(table, 0, .greaterThan, "9"), [1, 2])
    }

    func testRegexAndAnyOf() async throws {
        let table = try await table("code,city\nA1,Paris\nB2,Rome\nC3,Oslo\n")
        try await expect(table, cell(table, 0, .regex, "^[AB]\\d$"), [0, 1])
        let either = TabularRowPredicate.any([cell(table, 1, .equal, "rome"), cell(table, 1, .equal, "oslo")])
        try await expect(table, either, [1, 2])
        let both = TabularRowPredicate.all([cell(table, 0, .startsWith, "b"), cell(table, 1, .equal, "rome")])
        try await expect(table, both, [1])
    }

    func testQuickSearchIgnoresCaseAndDiacritics() async throws {
        let table = try await table("a,b\nCafé,1\nnothing,2\nx,CAFE\n")
        let search = TabularRowPredicate.search(TabularSearch(text: "cafe", columns: table.columnIDs))
        try await expect(table, search, [0, 2])
    }

    func testCSVCellsAreNeverNull() async throws {
        let table = try await table("a\n\nNULL\n")
        try await expect(table, cell(table, 0, .isNull, ""), [])
        try await expect(table, cell(table, 0, .equal, "NULL"), [1])
    }

    func testSortPutsBlanksLastAndSortsNaturally() async throws {
        let table = try await table("name,n\nItem 10,3\nItem 2,\nitem 1,20\n,x\n")
        let byName = try await TabularSorter.sortedKeys(
            table.rowOrder.keys,
            in: table,
            by: [TabularSortKey(column: table.columns[0].id, ascending: true, numeric: false)]
        )
        XCTAssertEqual(byName, [3, 2, 1, 4])
        let byNumberDescending = try await TabularSorter.sortedKeys(
            table.rowOrder.keys,
            in: table,
            by: [TabularSortKey(column: table.columns[1].id, ascending: false, numeric: true)]
        )
        XCTAssertEqual(byNumberDescending, [3, 1, 4, 2])
    }

    func testSortIsStableForEqualKeys() async throws {
        let table = try await table("k,v\nb,1\na,2\nb,3\na,4\n")
        let sorted = try await TabularSorter.sortedKeys(
            table.rowOrder.keys,
            in: table,
            by: [TabularSortKey(column: table.columns[0].id, ascending: true, numeric: false)]
        )
        XCTAssertEqual(sorted, [2, 4, 1, 3])
    }

    func testNaturalSortOrdersDigitRunsByMagnitudeAndIgnoresCase() async throws {
        let values = [
            "Item 10", "Item 2", "Item 100", "Item 20", "file10.txt", "file9.txt",
            "v1.10.0", "v1.2.3", "ABC", "abc", "x007", "x7"
        ]
        let table = try await table("v\n" + values.joined(separator: "\n") + "\n")
        let sorted = try await TabularSorter.sortedKeys(
            table.rowOrder.keys,
            in: table,
            by: [TabularSortKey(column: table.columns[0].id, ascending: true, numeric: false)]
        )
        XCTAssertEqual(sorted, [9, 10, 6, 5, 2, 1, 4, 3, 8, 7, 11, 12])
    }

    func testASortAcrossManyChunksMatchesAStableReferenceSort() async throws {
        let count = TabularChunking.minimumChunkSize * 9 + 37
        var generator = SystemRandomNumberGenerator()
        let values = (0..<count).map { _ in Int.random(in: 0..<500, using: &generator) }
        let text = "n,label\n" + values.map { "\($0),item \($0 % 7)" }.joined(separator: "\n") + "\n"
        let table = try await table(text)
        let byNumber = try await TabularSorter.sortedKeys(
            table.rowOrder.keys,
            in: table,
            by: [TabularSortKey(column: table.columns[0].id, ascending: false, numeric: true)]
        )
        let expectedByNumber = table.rowOrder.keys.enumerated()
            .sorted { lhs, rhs in
                let left = values[lhs.offset]
                let right = values[rhs.offset]
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
        XCTAssertEqual(byNumber, expectedByNumber)
        let byLabelThenNumber = try await TabularSorter.sortedKeys(
            table.rowOrder.keys,
            in: table,
            by: [
                TabularSortKey(column: table.columns[1].id, ascending: true, numeric: false),
                TabularSortKey(column: table.columns[0].id, ascending: true, numeric: true)
            ]
        )
        let expectedByLabel = table.rowOrder.keys.enumerated()
            .sorted { lhs, rhs in
                let left = (values[lhs.offset] % 7, values[lhs.offset], lhs.offset)
                let right = (values[rhs.offset] % 7, values[rhs.offset], rhs.offset)
                return left < right
            }
            .map(\.element)
        XCTAssertEqual(byLabelThenNumber, expectedByLabel)
    }
}
