import Foundation
import TableProNumberFormatting
@testable import TableProTabular
import TableProTabularIO
import Testing

struct TabularColumnStatisticsPrecisionTests {
    private static let english = Locale(identifier: "en_US")

    private func numericSummary(_ values: [String], kind: TabularInferredKind = .decimal) async throws -> TabularColumnSummary {
        let source = try await TabularTableTests.delimitedSource("v\n" + values.joined(separator: "\n") + "\n")
        let table = TabularTable(source: source, usesFirstRowAsHeader: true)
        return try await TabularColumnStatistics.summarize(
            column: table.columns[0].id,
            kind: kind,
            keys: table.rowOrder.keys,
            in: table
        )
    }

    private func exact(_ text: String) throws -> ExactNumber {
        ExactNumber(decimal: try #require(Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))))
    }

    @Test("A column of nanoscale values is not summed to zero")
    func tinyValuesKeepTheirDigits() async throws {
        let numeric = try #require(try await numericSummary(["3.2e-9", "1.6e-9"]).numeric)
        #expect(numeric.sum == (try exact("4.8e-9")))
        #expect(numeric.scale == 10)
        #expect(ExactNumberFormat.string(numeric.sum, fractionDigits: numeric.scale...numeric.scale, locale: Self.english) == "0.0000000048")
        #expect(ExactNumberFormat.string(numeric.minimum, fractionDigits: numeric.scale...numeric.scale, locale: Self.english) == "0.0000000016")
        #expect(ExactNumberFormat.string(numeric.mean, fractionDigits: 0...(numeric.scale + 4), locale: Self.english) == "0.0000000024")
        #expect(numeric.median == (try exact("2.4e-9")))
    }

    @Test("The mean and median of tiny values stay exact")
    func tinyMeanAndMedian() async throws {
        let numeric = try #require(try await numericSummary(["1e-95", "3e-95"]).numeric)
        #expect(numeric.mean == (try exact("2e-95")))
        #expect(numeric.median == (try exact("2e-95")))
        #expect(!numeric.mean.isApproximate)
    }

    @Test("Nineteen-digit IDs keep every digit in the sum, minimum and maximum")
    func bigIdentifiersStayExact() async throws {
        let numeric = try #require(try await numericSummary(["1712345678901234599", "1712345678901234567"], kind: .integer).numeric)
        #expect(numeric.minimum.plainText == "1712345678901234567")
        #expect(numeric.maximum.plainText == "1712345678901234599")
        #expect(numeric.sum.plainText == "3424691357802469166")
        #expect(numeric.mean.plainText == "1712345678901234583")
        #expect(numeric.median.isApproximate)
    }

    @Test("The median of an odd count is the middle value")
    func oddMedian() async throws {
        let numeric = try #require(try await numericSummary(["5", "1", "3"], kind: .integer).numeric)
        #expect(numeric.median == ExactNumber(decimal: 3))
    }

    @Test("The median of an even count averages the middle values in Decimal")
    func evenMedian() async throws {
        let integers = try #require(try await numericSummary(["4", "1", "3", "2"], kind: .integer).numeric)
        #expect(integers.median == (try exact("2.5")))
        let tenths = try #require(try await numericSummary(["0.2", "0.1"]).numeric)
        #expect(tenths.median == (try exact("0.15")))
        #expect(!tenths.median.isApproximate)
    }

    @Test("Sums stay exact across every scan partition")
    func partitionsMergeExactly() async throws {
        let numeric = try #require(try await numericSummary(Array(repeating: "0.1", count: 20_000)).numeric)
        #expect(numeric.count == 20_000)
        #expect(numeric.sum == ExactNumber(decimal: 2_000))
        #expect(numeric.mean == (try exact("0.1")))
        #expect(numeric.median == (try exact("0.1")))
    }

    @Test("An overflowing literal is not a number, a space-padded one still is")
    func grammarEdges() async throws {
        let summary = try await numericSummary(["1", "1e400", "\u{00A0}7"], kind: .integer)
        #expect(summary.nonNumericCount == 1)
        #expect(summary.numeric?.count == 2)
        #expect(summary.numeric?.sum == ExactNumber(decimal: 8))
    }
}
