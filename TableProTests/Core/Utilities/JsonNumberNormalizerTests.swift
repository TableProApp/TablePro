//
//  JsonNumberNormalizerTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@Suite("JSON Number Normalizer")
struct JsonNumberNormalizerTests {
    // MARK: - Integer literals

    @Test("Plain integers wider than Int64 keep every digit")
    func wideIntegersKeepEveryDigit() {
        #expect(JsonNumberNormalizer.integerLiteral(from: "18446744073709551615") == "18446744073709551615")
        #expect(JsonNumberNormalizer.integerLiteral(from: "-9223372036854775809") == "-9223372036854775809")
        #expect(
            JsonNumberNormalizer.integerLiteral(from: "340282366920938463463374607431768211455")
                == "340282366920938463463374607431768211455"
        )
    }

    @Test("Integral spellings normalize to the same literal as the plain spelling")
    func integralSpellingsAgreeWithPlainSpelling() {
        let plain = "18446744073709551615"
        #expect(JsonNumberNormalizer.integerLiteral(from: "\(plain).0") == plain)
        #expect(JsonNumberNormalizer.integerLiteral(from: "\(plain)0e-1") == plain)
        #expect(JsonNumberNormalizer.integerLiteral(from: "1844674407370955.1615e4") == plain)
        #expect(JsonNumberNormalizer.integerLiteral(from: "+\(plain).00") == plain)
        #expect(JsonNumberNormalizer.integerLiteral(from: "0000\(plain)") == plain)
    }

    @Test("Compatibility spellings of small integers normalize")
    func smallIntegerSpellings() {
        #expect(JsonNumberNormalizer.integerLiteral(from: "42.0") == "42")
        #expect(JsonNumberNormalizer.integerLiteral(from: "1e3") == "1000")
        #expect(JsonNumberNormalizer.integerLiteral(from: "1.2e1") == "12")
        #expect(JsonNumberNormalizer.integerLiteral(from: "1000e-3") == "1")
        #expect(JsonNumberNormalizer.integerLiteral(from: "1.") == "1")
        #expect(JsonNumberNormalizer.integerLiteral(from: "-.0") == "0")
        #expect(JsonNumberNormalizer.integerLiteral(from: "+007") == "7")
        #expect(JsonNumberNormalizer.integerLiteral(from: "0.000e9") == "0")
    }

    @Test("A nonzero fractional part is not an integer")
    func fractionalValuesAreNotIntegers() {
        #expect(JsonNumberNormalizer.integerLiteral(from: "42.0000000000000000001") == nil)
        #expect(JsonNumberNormalizer.integerLiteral(from: "0.5") == nil)
        #expect(JsonNumberNormalizer.integerLiteral(from: ".5") == nil)
        #expect(JsonNumberNormalizer.integerLiteral(from: "-0.5") == nil)
        #expect(JsonNumberNormalizer.integerLiteral(from: "1234e-5") == nil)
    }

    @Test("A 9007199254740993 sized value survives that Double cannot represent")
    func valuesDoubleCannotRepresentSurvive() {
        #expect(JsonNumberNormalizer.integerLiteral(from: "9007199254740993.0") == "9007199254740993")
        #expect(JsonNumberNormalizer.integerLiteral(from: "9007199254740993e0") == "9007199254740993")
    }

    // MARK: - Exponent bounds

    @Test("An exponent past the digit budget is rejected instead of overflowing")
    func oversizedExponentsAreRejected() {
        #expect(JsonNumberNormalizer.integerLiteral(from: "1e9223372036854775807") == nil)
        #expect(JsonNumberNormalizer.integerLiteral(from: "1e-9223372036854775808") == nil)
        #expect(JsonNumberNormalizer.integerLiteral(from: "1e99999999999999999999999999") == nil)
        #expect(JsonNumberNormalizer.integerLiteral(from: "1e2000000000") == nil)
        #expect(JsonNumberNormalizer.numberLiteral(from: "+1e9223372036854775807") == nil)
    }

    @Test("The exponent budget admits its boundary and rejects one past it")
    func exponentBudgetBoundary() {
        let expanded = JsonNumberNormalizer.integerLiteral(from: "1e1000")
        #expect(expanded?.count == 1_001)
        #expect(expanded?.hasPrefix("10") == true)
        #expect(expanded?.dropFirst().allSatisfy { $0 == "0" } == true)
        #expect(JsonNumberNormalizer.integerLiteral(from: "1e1001") == nil)
    }

    // MARK: - Number literals

    @Test("Wide decimals keep every digit instead of narrowing through Double")
    func wideDecimalsKeepEveryDigit() {
        #expect(
            JsonNumberNormalizer.numberLiteral(from: "+12345678901234567890.12345")
                == "12345678901234567890.12345"
        )
        #expect(
            JsonNumberNormalizer.numberLiteral(from: ".123456789012345678901234567890")
                == "0.123456789012345678901234567890"
        )
        #expect(JsonNumberNormalizer.numberLiteral(from: "0.1000000000000000000001") == "0.1000000000000000000001")
    }

    @Test("Spellings JSON rejects are rewritten without losing digits")
    func nonJsonSpellingsAreRewritten() {
        #expect(JsonNumberNormalizer.numberLiteral(from: "007.5") == "7.5")
        #expect(JsonNumberNormalizer.numberLiteral(from: "1.") == "1")
        #expect(JsonNumberNormalizer.numberLiteral(from: "-.5") == "-0.5")
        #expect(JsonNumberNormalizer.numberLiteral(from: "+1.0E5") == "1.0e5")
        #expect(JsonNumberNormalizer.numberLiteral(from: "1.e-5") == "1e-5")
        #expect(JsonNumberNormalizer.numberLiteral(from: "-0.00") == "-0.00")
    }

    @Test("Trailing fraction zeros are scale, so a decimal keeps them")
    func decimalScaleIsPreserved() {
        #expect(JsonNumberNormalizer.numberLiteral(from: "+42.000") == "42.000")
        #expect(JsonNumberNormalizer.numberLiteral(from: "0009.9000") == "9.9000")
    }

    // MARK: - Rejection

    @Test("Non-numeric text is rejected rather than coerced")
    func nonNumericTextIsRejected() {
        for value in ["", "-", "+", ".", "abc", " 7", "7 ", "1.2.3", "1e", "1e+", "--1", "0x10"] {
            #expect(JsonNumberNormalizer.numberLiteral(from: value) == nil, "expected nil for \(value)")
            #expect(JsonNumberNormalizer.integerLiteral(from: value) == nil, "expected nil for \(value)")
        }
    }

    @Test("Floating point spellings that are not JSON numbers stay rejected")
    func floatingPointKeywordsAreRejected() {
        for value in ["inf", "-inf", "nan", "Infinity", "-Infinity", "NaN", "1e5f"] {
            #expect(JsonNumberNormalizer.numberLiteral(from: value) == nil, "expected nil for \(value)")
        }
    }

    @Test("Only ASCII digits count as digits")
    func onlyAsciiDigitsCount() {
        #expect(JsonNumberNormalizer.numberLiteral(from: "\u{0661}\u{0662}\u{0663}") == nil)
        #expect(JsonNumberNormalizer.integerLiteral(from: "1\u{0301}") == nil)
        #expect(JsonNumberNormalizer.integerLiteral(from: "\u{FF11}\u{FF12}") == nil)
    }
}
