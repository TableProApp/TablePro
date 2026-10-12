import Foundation
import TableProNumberFormatting
import Testing

struct ExactNumberFormatTests {
    private static let english = Locale(identifier: "en_US")
    private static let german = Locale(identifier: "de_DE")
    private static let vietnamese = Locale(identifier: "vi_VN")

    private func exact(_ text: String) throws -> ExactNumber {
        ExactNumber(decimal: try #require(Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))))
    }

    @Test("Grouping and the decimal separator follow the locale")
    func groupsPerLocale() throws {
        let value = try exact("1234567.5")
        #expect(ExactNumberFormat.string(value, fractionDigits: 2...2, locale: Self.english) == "1,234,567.50")
        #expect(ExactNumberFormat.string(value, fractionDigits: 2...2, locale: Self.german) == "1.234.567,50")
        #expect(ExactNumberFormat.string(value, fractionDigits: 2...2, locale: Self.vietnamese) == "1.234.567,50")
        #expect(ExactNumberFormat.string(try exact("-1234.5"), fractionDigits: 2...2, locale: Self.english) == "-1,234.50")
    }

    @Test("A range trims trailing zeros down to its lower bound")
    func trimsToTheRange() throws {
        #expect(ExactNumberFormat.string(try exact("2.25"), fractionDigits: 0...6, locale: Self.english) == "2.25")
        #expect(ExactNumberFormat.string(try exact("2"), fractionDigits: 0...6, locale: Self.english) == "2")
        #expect(ExactNumberFormat.string(try exact("2"), fractionDigits: 1...6, locale: Self.english) == "2.0")
    }

    @Test("Rounding is half away from zero and never shows a negative zero")
    func roundsHalfAwayFromZero() throws {
        #expect(ExactNumberFormat.string(try exact("0.125"), fractionDigits: 0...2, locale: Self.english) == "0.13")
        #expect(ExactNumberFormat.string(try exact("-0.125"), fractionDigits: 0...2, locale: Self.english) == "-0.13")
        #expect(ExactNumberFormat.string(try exact("-0.001"), fractionDigits: 2...2, locale: Self.english) == "0.00")
        #expect(ExactNumberFormat.string(try exact("9.9999"), fractionDigits: 0...2, locale: Self.english) == "10")
    }

    @Test("Tiny values keep their digits instead of rounding to zero")
    func tinyValuesShow() throws {
        let value = try exact("3.2e-9")
        #expect(ExactNumberFormat.string(value, fractionDigits: 10...10, locale: Self.english) == "0.0000000032")
        #expect(ExactNumberFormat.string(value, fractionDigits: 10...10, locale: Self.german) == "0,0000000032")
        #expect(ExactNumberFormat.string(try exact("1e-100"), fractionDigits: 100...100, locale: Self.english) == "1E-100")
        #expect(ExactNumberFormat.string(try exact("1e-100"), fractionDigits: 0...4, locale: Self.english) == "0")
    }

    @Test("Every integer digit of a wide exact value is printed")
    func wideIntegersStayExact() throws {
        let value = try exact("12345678901234567890123456789012345678")
        #expect(
            ExactNumberFormat.string(value, fractionDigits: 0...0, locale: Self.english)
                == "12,345,678,901,234,567,890,123,456,789,012,345,678"
        )
        #expect(ExactNumberFormat.plainText(value, fractionDigits: 0...0) == "12345678901234567890123456789012345678")
    }

    @Test("A scale padded past the limit stays plain while the digits fit")
    func paddingIsCapped() throws {
        let value = try exact("12.5")
        #expect(ExactNumberFormat.string(value, fractionDigits: 30...30, locale: Self.english) == "12.500000000000000")
        #expect(ExactNumberFormat.plainText(value, fractionDigits: 30...30) == "12.500000000000000")
    }

    @Test("Approximate values carry a marker and switch to scientific when large")
    func approximateValues() {
        let huge = ExactNumber(approximation: 1.5e300)
        #expect(ExactNumberFormat.string(huge, fractionDigits: 0...2, locale: Self.english) == "≈ 1.5E300")
        #expect(ExactNumberFormat.string(huge, fractionDigits: 0...2, locale: Self.german) == "≈ 1,5E300")
        #expect(ExactNumberFormat.string(huge, fractionDigits: 0...2, locale: Self.vietnamese) == "≈ 1,5E300")
        #expect(ExactNumberFormat.plainText(huge, fractionDigits: 0...2) == "1.5E300")

        let moderate = ExactNumber(approximation: 12_345.678)
        #expect(ExactNumberFormat.string(moderate, fractionDigits: 0...30, locale: Self.english) == "≈ 12,345.678")
        #expect(ExactNumberFormat.string(moderate, fractionDigits: 2...2, locale: Self.english) == "≈ 12,345.68")
        #expect(ExactNumberFormat.plainText(moderate, fractionDigits: 0...30) == "12345.678")

        let tiny = ExactNumber(approximation: 1e-200)
        #expect(ExactNumberFormat.string(tiny, fractionDigits: 0...200, locale: Self.english) == "≈ 1E-200")
    }

    @Test("The largest Double prints its digits, and only a true overflow prints infinity")
    func largestDoublePrints() throws {
        let largest = ExactNumber(approximation: .greatestFiniteMagnitude)
        #expect(ExactNumberFormat.string(largest, fractionDigits: 0...0, locale: Self.english) == "≈ 1.79769313486232E308")
        #expect(ExactNumberFormat.string(largest, fractionDigits: 0...0, locale: Self.german) == "≈ 1,79769313486232E308")
        let smallest = ExactNumber(approximation: -.greatestFiniteMagnitude)
        #expect(ExactNumberFormat.string(smallest, fractionDigits: 0...0, locale: Self.english) == "≈ -1.79769313486232E308")
        #expect(ExactNumberFormat.plainText(largest, fractionDigits: 0...0) == "1.7976931348623157E308")

        var accumulator = NumericSummaryAccumulator()
        _ = accumulator.add("1.7976931348623157e308")
        _ = accumulator.add("0")
        let sum = try #require(accumulator.summary()).sum
        #expect(ExactNumberFormat.string(sum, fractionDigits: 0...0, locale: Self.english) == "≈ 1.79769313486232E308")

        let infinite = ExactNumber(approximation: .infinity)
        #expect(ExactNumberFormat.string(infinite, fractionDigits: 0...0, locale: Self.english) == "≈ ∞")
        #expect(ExactNumberFormat.string(ExactNumber(approximation: -.infinity), fractionDigits: 0...0, locale: Self.english) == "≈ -∞")
    }

    @Test("Plain text is POSIX, ungrouped and exponent-free for exact values")
    func plainTextIsPOSIX() throws {
        #expect(ExactNumberFormat.plainText(try exact("1234.5"), fractionDigits: 2...2) == "1234.50")
        #expect(ExactNumberFormat.plainText(try exact("1234.5"), fractionDigits: 0...6) == "1234.5")
        #expect(ExactNumberFormat.plainText(try exact("-0.0000000032"), fractionDigits: 0...14) == "-0.0000000032")
        #expect(ExactNumberFormat.plainText(try exact("1e20"), fractionDigits: 0...0) == "100000000000000000000")
        #expect(ExactNumberFormat.plainText(try exact("1e-100"), fractionDigits: 0...104) == "1E-100")
        #expect(ExactNumberFormat.plainText(try exact("1.25e-30"), fractionDigits: 0...40) == "1.25E-30")
    }
}
