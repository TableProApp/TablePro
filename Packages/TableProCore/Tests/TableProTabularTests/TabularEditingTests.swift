import Foundation
import TableProNumberFormatting
@testable import TableProTabular
import TableProTabularIO
import Testing

struct TabularEditingTests {
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

    @Test func testStatisticsCountDistinctEmptyAndNumbers() async throws {
        let table = try await table("n\n3\n1\n\n3\nx\n")
        let summary = try await TabularColumnStatistics.summarize(
            column: table.columns[0].id,
            kind: .integer,
            keys: table.rowOrder.keys,
            in: table
        )
        #expect(summary.rowCount == 5)
        #expect(summary.emptyCount == 1)
        #expect(summary.distinctCount == 4)
        #expect(summary.nonNumericCount == 1)
        #expect(summary.numeric?.minimum == ExactNumber(decimal: 1))
        #expect(summary.numeric?.maximum == ExactNumber(decimal: 3))
        #expect(summary.numeric?.median == ExactNumber(decimal: 3))
        #expect(summary.numeric?.sum == ExactNumber(decimal: 7))
        #expect(summary.topValues.first == TabularValueCount(value: "3", isEmpty: false, count: 2))
    }

    @Test func testMedianMatchesASortedReference() {
        var generator = SystemRandomNumberGenerator()
        for count in [1, 2, 3, 4, 5, 10, 101, 1_000] {
            for _ in 0..<20 {
                var numbers = (0..<count).map { _ in Double(Int.random(in: -50...50, using: &generator)) }
                let sorted = numbers.sorted()
                let middle = count / 2
                let expected = count.isMultiple(of: 2) ? (sorted[middle - 1], sorted[middle]) : (sorted[middle], sorted[middle])
                let found = TabularColumnStatistics.middleValues(of: &numbers)
                #expect(found.lower == expected.0, "\(sorted)")
                #expect(found.upper == expected.1, "\(sorted)")
            }
        }
    }

    @Test func testTopValuesAcrossPartitionsMatchABruteForceRanking() async throws {
        var generator = SystemRandomNumberGenerator()
        let values = (0..<20_000).map { _ in "v\(Int.random(in: 0..<700, using: &generator))" }
        let table = try await table("v\n" + values.joined(separator: "\n") + "\n")
        let summary = try await TabularColumnStatistics.summarize(
            column: table.columns[0].id,
            kind: .text,
            keys: table.rowOrder.keys,
            in: table,
            topValueLimit: 25
        )
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        #expect(summary.distinctCount == counts.count)
        #expect(summary.topValues.count == 25)
        let threshold = counts.values.sorted(by: >)[24]
        for entry in summary.topValues {
            #expect(counts[entry.value] == entry.count)
            #expect(entry.count >= threshold)
        }
        #expect(summary.topValues.map(\.count) == summary.topValues.map(\.count).sorted(by: >))
        #expect(Set(summary.topValues.map(\.value)).count == 25)
    }

    @Test func testFindHonoursCaseWholeWordsAndRegex() async throws {
        let table = try await table("a,b\ncat,Category\nCAT,dog\nconcat,cat5\n")
        let all = table.rowOrder.keys
        let plain = try await TabularFinder.findAll(TabularFindQuery(text: "cat", columns: table.columnIDs), keys: all, in: table)
        #expect(plain.count == 5)
        let cased = try await TabularFinder.findAll(
            TabularFindQuery(text: "cat", matchesCase: true, columns: table.columnIDs),
            keys: all,
            in: table
        )
        #expect(cased.count == 3)
        let words = try await TabularFinder.findAll(
            TabularFindQuery(text: "cat", matchesWholeWords: true, columns: table.columnIDs),
            keys: all,
            in: table
        )
        #expect(words.map(\.key) == [1, 2])
        let regex = try await TabularFinder.findAll(
            TabularFindQuery(text: "^c.t\\d$", isRegularExpression: true, columns: table.columnIDs),
            keys: all,
            in: table
        )
        #expect(regex == [TabularFindMatch(key: 3, column: table.columns[1].id)])
        #expect(throws: (any Error).self) { try TabularFindMatcher(TabularFindQuery(text: "(", isRegularExpression: true, columns: [])) }
    }

    @Test func testReplaceAllRewritesOnlyMatchingCellsAndKeepsEditsInScope() async throws {
        var table = try await table("a\nfoo bar\nbaz\nfoo\n")
        table.setCell(.text("foo edited"), row: 1, column: 0)
        let result = try await TabularFinder.replaceAll(
            TabularFindQuery(text: "(fo)o", isRegularExpression: true, columns: table.columnIDs),
            with: "$1x",
            keys: table.rowOrder.keys,
            in: table
        )
        #expect(result.changedCells == 3)
        #expect(result.replacements == 3)
        let updated = applying(result.values, to: table)
        #expect(texts(updated, column: 0) == ["fox bar", "fox edited", "fox"])
        #expect(updated.columns[0].values.edits.isEmpty)
    }

    @Test func testLiteralReplaceTreatsDollarSignsAsText() async throws {
        let table = try await table("a\nprice 5\n")
        let result = try await TabularFinder.replaceAll(
            TabularFindQuery(text: "5", columns: table.columnIDs),
            with: "$1",
            keys: table.rowOrder.keys,
            in: table
        )
        #expect(texts(applying(result.values, to: table), column: 0) == ["price $1"])
    }

    @Test func testCleanupOperationsReportChangedCells() async throws {
        let table = try await table("a,b\n  x  ,1\ny,2\n\t z ,3\n")
        let all = table.rowOrder.keys
        let trimmed = try await TabularCleanup.apply(.trimWhitespace, columns: [table.columns[0].id], keys: all, in: table)
        #expect(trimmed.changedCells == 2)
        #expect(texts(applying(trimmed.values, to: table), column: 0) == ["x", "y", "z"])

        let upper = try await TabularCleanup.apply(.changeCase(.uppercase), columns: [table.columns[0].id], keys: [2], in: table)
        #expect(texts(applying(upper.values, to: table), column: 0) == ["  x  ", "Y", "\t z "])

        let filled = try await TabularCleanup.apply(.fillDown, columns: [table.columns[1].id], keys: [1, 2, 3], in: table)
        #expect(filled.changedCells == 2)
        #expect(texts(applying(filled.values, to: table), column: 1) == ["1", "1", "1"])

        let everywhere = try await TabularCleanup.apply(.setValue("k"), columns: [table.columns[1].id], keys: all, in: table)
        #expect(everywhere.changedCells == 3)
        #expect(texts(applying(everywhere.values, to: table), column: 1) == ["k", "k", "k"])
    }

    @Test func testDuplicateRowsKeepTheFirstOccurrence() async throws {
        let table = try await table("a,b\nx,1\nX ,1\nx,1\ny,2\n")
        let all = table.rowOrder.keys
        let exact = try await TabularDuplicates.duplicateKeys(comparing: table.columnIDs, keys: all, in: table)
        #expect(exact == [3])
        let loose = try await TabularDuplicates.duplicateKeys(
            comparing: table.columnIDs,
            keys: all,
            in: table,
            options: TabularDuplicateOptions(ignoresCase: true, ignoresSurroundingWhitespace: true)
        )
        #expect(loose == [2, 3])
    }

    @Test func testTypeInferenceIsStrict() {
        #expect(TabularTypeInference.infer([(.text, "1"), (.text, "22")]) == .integer)
        #expect(TabularTypeInference.infer([(.text, "007"), (.text, "12")]) == .text)
        #expect(TabularTypeInference.infer([(.text, "1.5"), (.text, "2")]) == .decimal)
        #expect(TabularTypeInference.infer([(.text, "NaN"), (.text, "2")]) == .text)
        #expect(TabularTypeInference.infer([(.text, "0x1F")]) == .text)
        #expect(TabularTypeInference.infer([(.text, "yes"), (.text, "No")]) == .boolean)
        #expect(TabularTypeInference.infer([(.text, "2024-01-05"), (.text, "2024-02-10T10:00:00Z")]) == .date)
        #expect(TabularTypeInference.infer([(.text, "05/01/2024")]) == .text)
    }

    @Test func testARunawayRegularExpressionStopsWhenItsTaskIsCancelled() async throws {
        let expression = try NSRegularExpression(pattern: "(a+)+b")
        let text = String(repeating: "a", count: 64)
        let task = Task { TabularRegex.firstMatch(expression, in: text) != nil }
        try await Task.sleep(for: .milliseconds(200))
        let cancelled = ContinuousClock.now
        task.cancel()
        let matched = await task.value
        #expect(!matched)
        #expect(ContinuousClock.now - cancelled < .seconds(2))
    }

    @Test func testRegularExpressionReplaceMatchesFoundationsOwnReplacement() throws {
        let query = TabularFindQuery(text: "(\\w+)@(\\w+)", isRegularExpression: true, columns: [])
        let matcher = try TabularFindMatcher(query)
        let text = "ann@x, bob@y and café@z"
        let expected = try NSRegularExpression(pattern: "(\\w+)@(\\w+)")
            .stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$2:$1")
        let replaced = matcher.replacing(in: text, with: "$2:$1")
        #expect(replaced.text == expected)
        #expect(replaced.replacements == 3)
    }

    @Test func testRegularExpressionReplaceThatChangesLengthReadsEachMatchsOwnGroups() throws {
        let query = TabularFindQuery(text: "(\\w+)_id", isRegularExpression: true, columns: [])
        let matcher = try TabularFindMatcher(query)
        let text = "user_id, order_id, item_id"
        let replaced = matcher.replacing(in: text, with: "$1Id")
        #expect(replaced.text == "userId, orderId, itemId")
        #expect(replaced.replacements == 3)
    }
}
