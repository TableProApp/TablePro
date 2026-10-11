import Foundation
@testable import TableProNumberFormatting
import Testing

struct NumericSummaryAccumulatorTests {
    private func summary(_ literals: [String]) throws -> ExactNumericSummary {
        var accumulator = NumericSummaryAccumulator()
        for literal in literals {
            let accepted = accumulator.add(literal)
            #expect(accepted, "\(literal)")
        }
        return try #require(accumulator.summary())
    }

    private func decimal(_ text: String) throws -> Decimal {
        try #require(Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")))
    }

    @Test("Ten times 0.1 is exactly 1")
    func tenthsSumExactly() throws {
        let result = try summary(Array(repeating: "0.1", count: 10))
        #expect(result.sum.decimal == 1)
        #expect(!result.sum.isApproximate)
        #expect(result.sum.plainText == "1")
        #expect(result.scale == 1)
        #expect(result.count == 10)
    }

    @Test("Two int8 maximums add without rounding")
    func int64MaximumsAddExactly() throws {
        let result = try summary(["9223372036854775807", "9223372036854775807"])
        #expect(result.sum.decimal == (try decimal("18446744073709551614")))
        #expect(result.sum.plainText == "18446744073709551614")
        #expect(result.mean.plainText == "9223372036854775807")
    }

    @Test("BIGINT UNSIGNED maximum stays exact")
    func unsignedMaximumIsExact() throws {
        let result = try summary(["18446744073709551615"])
        #expect(result.sum.plainText == "18446744073709551615")
        #expect(result.minimum.plainText == "18446744073709551615")
        #expect(result.maximum.plainText == "18446744073709551615")
        #expect(!result.sum.isApproximate)
    }

    @Test("Sums past the Int64 range stay exact in both directions")
    func sumsPastInt64() throws {
        let result = try summary(Array(repeating: "999999999999999999", count: 100) + ["-1"])
        #expect(result.sum.plainText == "99999999999999999899")
        #expect(!result.sum.isApproximate)
        let negative = try summary(Array(repeating: "-9223372036854775807", count: 3) + ["0.5"])
        #expect(negative.sum.plainText == "-27670116110564327420.5")
        #expect(negative.minimum.plainText == "-9223372036854775807")
        #expect(negative.maximum.plainText == "0.5")
    }

    @Test("A 65-digit DECIMAL value is summed approximately")
    func wideDecimalIsApproximate() throws {
        let literal = "12345678901234567890123456789012345.123456789012345678901234567891"
        let result = try summary([literal, "1"])
        #expect(result.sum.isApproximate)
        #expect(result.minimum.plainText == "1")
        #expect(result.maximum.isApproximate)
        #expect(abs(result.sum.approximation - 1.2345678901234568e34) < 1e19)
    }

    @Test("An approximate sum past the Double range is a signed infinity, never NaN")
    func overflowingApproximateSum() throws {
        let largest = "1.7976931348623157e308"
        let doubled = try summary([largest, largest])
        #expect(doubled.sum.isApproximate)
        #expect(doubled.sum.approximation == .infinity)
        #expect(doubled.mean.approximation == .greatestFiniteMagnitude)
        #expect(try summary([largest, largest]) == doubled)
        let negative = try summary(["-9e307", "-9e307"])
        #expect(negative.sum.approximation == -.infinity)
        #expect(negative.mean.approximation == -9e307)
    }

    @Test("An approximate sum that overflows midway comes back finite and correct")
    func approximateSumCancels() throws {
        let result = try summary(["1e308", "1e308", "-1e308"])
        #expect(result.sum.isApproximate)
        #expect(result.sum.approximation == 1e308)
        #expect(try summary(["1e308", "1e308", "-1e308"]) == result)
        let cancelled = try summary(["1.7976931348623157e+308", "2.5", "-1.7976931348623157e+308"])
        #expect(cancelled.sum.approximation == 2.5)
    }

    @Test("The mean of tiny exact values stays exact")
    func tinyMeanIsExact() throws {
        let result = try summary(["1e-100", "2e-100"])
        #expect(!result.mean.isApproximate)
        #expect(result.mean.decimal == (try decimal("1.5e-100")))
        #expect(try summary(["1e-95", "3e-95"]).mean.decimal == (try decimal("2e-95")))
    }

    @Test("A sum wider than 38 digits is approximate, one that cancels back is exact")
    func resultWidthDecidesExactness() throws {
        #expect(try summary(["1e20", "1e-20"]).sum.isApproximate)
        let cancelled = try summary(["1e127", "1", "-1e127"])
        #expect(cancelled.sum.decimal == 1)
        let carried = try summary(["99999999999999999999999999999999999999", "1"])
        #expect(carried.sum.decimal == (try decimal("1e38")))
    }

    @Test(
        "Literals outside the grammar are not numbers",
        arguments: [
            "NaN", "nan", "Infinity", "-Infinity", "inf", "$1,234.56", "1,234.56", "1.234,56", "12abc",
            "0x10", "0x1p3", "١٢", "１２", "", " ", "-", "+", ".", "-.", "e5", "1e", "1e+", "1.2.3", "1_000",
            "1 000", "1e5.5", "1e400", "-1e400", "\u{00A0}7",
        ]
    )
    func rejects(_ literal: String) {
        var accumulator = NumericSummaryAccumulator()
        let accepted = accumulator.add(literal)
        #expect(!accepted)
        #expect(accumulator.summary() == nil)
    }

    @Test(
        "Plain decimal and exponent literals are numbers",
        arguments: [" 7", "7\t", "\t 7 ", "+12", "-0", ".5", "5.", "-.5", "1e5", "1E-5", "3.2e-9", "5.e3", "0.000", "1e-400"]
    )
    func accepts(_ literal: String) {
        var accumulator = NumericSummaryAccumulator()
        let accepted = accumulator.add(literal)
        #expect(accepted)
        #expect(accumulator.count == 1)
    }

    @Test("The byte limit is 256 after trimming")
    func lengthLimit() {
        let longest = "1" + String(repeating: "0", count: 255)
        var accumulator = NumericSummaryAccumulator()
        let acceptedLongest = accumulator.add("  \(longest)  ")
        let acceptedLonger = accumulator.add(longest + "0")
        #expect(acceptedLongest)
        #expect(!acceptedLonger)
        #expect(accumulator.count == 1)
    }

    @Test("Scale counts the fraction digits an exponent leaves")
    func scaleFollowsTheExponent() throws {
        #expect(try summary(["3.2e-9"]).scale == 10)
        #expect(try summary(["1.5e3"]).scale == 0)
        #expect(try summary(["1.50", "2", "0.125"]).scale == 3)
        #expect(try summary(["1.5E-2"]).sum.plainText == "0.015")
    }

    @Test("An exponent literal and its plain spelling give the same summary")
    func exponentFormsMatchPlainForms() throws {
        let exponents = try summary(["1.2345e+02", "-5e-3", "1.50e1", "9.223372036854775807e18", "4e18", "1e-18"])
        let plain = try summary(["123.45", "-0.005", "15.0", "9223372036854775807", "4000000000000000000", "0.000000000000000001"])
        #expect(exponents == plain)
        #expect(exponents.scale == 18)
        #expect(exponents.sum.plainText == "13223372036854775945.445000000000000001")
    }

    @Test("The mean divides the exact sum")
    func meanIsSumOverCount() throws {
        #expect(try summary(["1.50", "2.25", "3"]).mean.plainText == "2.25")
        let thirds = try summary(["1", "2", "2"])
        #expect(!thirds.mean.isApproximate)
        #expect(ExactNumberFormat.plainText(thirds.mean, fractionDigits: 0...4) == "1.6667")
        #expect(try summary(["1", "2"]).mean.decimal == (try decimal("1.5")))
    }

    @Test("Minimum and maximum compare digits that share a Double")
    func extremesAreExact() throws {
        let ids = ["1712345678901234599", "1712345678901234567", "1712345678901234580"]
        let result = try summary(ids)
        #expect(result.minimum.plainText == "1712345678901234567")
        #expect(result.maximum.plainText == "1712345678901234599")
        #expect(result.minimum.approximation == result.maximum.approximation)
        #expect(result.minimum < result.maximum)

        let fast = try summary(["171234567890123457", "171234567890123456", "-1.5", "-1.50000000000000001"])
        #expect(fast.maximum.plainText == "171234567890123457")
        #expect(fast.minimum.plainText == "-1.50000000000000001")

        let mixed = try summary(["2.5", "2.50", "2.4999999999999999999999", "1e-200"])
        #expect(mixed.maximum.plainText == "2.5")
        #expect(mixed.minimum.isApproximate)
    }

    @Test("Merging partial accumulators gives the single-pass result")
    func mergeMatchesOnePass() throws {
        var generator = SeededGenerator(seed: 0x5EED)
        let literals = (0..<5_000).map { _ in Self.literal(using: &generator) }
        var single = NumericSummaryAccumulator()
        for literal in literals { _ = single.add(literal) }
        for parts in [1, 2, 7, 64] {
            var merged = NumericSummaryAccumulator()
            let size = (literals.count + parts - 1) / parts
            for start in stride(from: 0, to: literals.count, by: size) {
                var part = NumericSummaryAccumulator()
                for literal in literals[start..<min(start + size, literals.count)] { _ = part.add(literal) }
                merged.merge(part)
            }
            #expect(merged.count == single.count)
            #expect(merged.summary() == single.summary())
        }
        let result = try #require(single.summary())
        #expect(!result.sum.isApproximate)
    }

    @Test("Byte input and string input agree")
    func bytesMatchStrings() {
        var fromText = NumericSummaryAccumulator()
        var fromBytes = NumericSummaryAccumulator()
        for literal in ["12.5", " -3", "1e3", "abc", "18446744073709551615"] {
            let textAccepted = fromText.add(literal)
            let bytesAccepted = Array(literal.utf8).withUnsafeBufferPointer { fromBytes.add($0) }
            #expect(textAccepted == bytesAccepted)
        }
        #expect(fromText.summary() == fromBytes.summary())
    }

    @Test("Exact and approximate numbers order and compare consistently")
    func exactNumberOrdering() throws {
        let one = ExactNumber(decimal: 1)
        let onePointZero = ExactNumber(decimal: try decimal("1.0"))
        let approximateOne = ExactNumber(approximation: 1)
        #expect(one == onePointZero)
        #expect(one.hashValue == onePointZero.hashValue)
        #expect(one != approximateOne)
        #expect(approximateOne < one)
        #expect(ExactNumber(decimal: try decimal("9007199254740992")) < ExactNumber(decimal: try decimal("9007199254740993")))
        #expect(ExactNumber(decimal: try decimal("3.2e-9")).plainText == "0.0000000032")
        #expect(ExactNumber(approximation: 1.5e300).plainText == "1.5e+300")
        let notANumber = ExactNumber(decimal: .nan)
        #expect(notANumber == ExactNumber(decimal: Decimal.nan))
        #expect(notANumber < one)
    }

    private static func literal(using generator: inout SeededGenerator) -> String {
        switch generator.next() % 6 {
        case 0:
            return String(Int64.random(in: -1_000_000...1_000_000, using: &generator))
        case 1:
            let cents = Int64.random(in: -100_000_000...100_000_000, using: &generator)
            return String(format: "%@%lld.%02lld", cents < 0 ? "-" : "", abs(cents) / 100, abs(cents) % 100)
        case 2:
            return String(Int64.random(in: 900_000_000_000_000_000...999_999_999_999_999_999, using: &generator))
        case 3:
            return String(UInt64.random(in: UInt64(Int64.max)...UInt64.max, using: &generator))
        case 4:
            return "\(Int.random(in: 1...999, using: &generator))e-\(Int.random(in: 0...6, using: &generator))"
        default:
            return "0.\(UInt32.random(in: 0...UInt32.max, using: &generator))"
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
