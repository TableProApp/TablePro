import Foundation
import TableProPluginKit
import Testing

struct DynamoDBNumberTests {
    struct PartsCase: Sendable, CustomTestStringConvertible {
        let text: String
        let isNegative: Bool
        let digits: [UInt8]
        let leadingExponent: Int
        var testDescription: String { text }
    }

    struct ComparisonCase: Sendable, CustomTestStringConvertible {
        let lhs: String
        let rhs: String
        let expected: ComparisonResult
        var testDescription: String { "\(lhs) vs \(rhs)" }
    }

    private static let largestNumber = "9." + String(repeating: "9", count: 37) + "E+125"

    @Test("Thirty-eight significant digits are valid and thirty-nine are not")
    func significantDigitLimit() {
        let thirtyEight = "12345678901234567890123456789012345678"
        let thirtyNine = thirtyEight + "9"
        #expect(DynamoDBNumber.isValid(thirtyEight))
        #expect(!DynamoDBNumber.isValid(thirtyNine))
        #expect(!DynamoDBNumber.isValid("-" + thirtyNine))
        #expect(!DynamoDBNumber.isValid("0." + thirtyNine))
    }

    @Test("Leading and trailing zeros are not significant digits")
    func zerosAreNotSignificant() {
        let thirtyEight = "12345678901234567890123456789012345678"
        #expect(DynamoDBNumber.isValid(thirtyEight + "000"))
        #expect(DynamoDBNumber.isValid("000" + thirtyEight))
        #expect(DynamoDBNumber.isValid("0.000" + thirtyEight))
        #expect(DynamoDBNumber.isValid("1.2345678901234567890123456789012345678000"))
    }

    @Test("The magnitude limits are 1E-130 and below 1E+126")
    func magnitudeLimits() {
        #expect(DynamoDBNumber.isValid(Self.largestNumber))
        #expect(DynamoDBNumber.isValid("-" + Self.largestNumber))
        #expect(!DynamoDBNumber.isValid("1E+126"))
        #expect(!DynamoDBNumber.isValid("-1E+126"))
        #expect(!DynamoDBNumber.isValid("10E+125"))
        #expect(DynamoDBNumber.isValid("1E-130"))
        #expect(DynamoDBNumber.isValid("-1E-130"))
        #expect(DynamoDBNumber.isValid("1.5E-130"))
        #expect(!DynamoDBNumber.isValid("1E-131"))
        #expect(!DynamoDBNumber.isValid("0.1E-130"))
        #expect(DynamoDBNumber.isValid("0.0001e129"))
        #expect(!DynamoDBNumber.isValid("0.0001e130"))
    }

    @Test(
        "Forms DynamoDB accepts are valid",
        arguments: ["0", "-0.000", ".5", "5.", "+5", "007.50e1", "-12.5", "1e2", "1E+2", "2e-3", "  42  "]
    )
    func acceptsNumberForms(text: String) {
        #expect(DynamoDBNumber.isValid(text))
    }

    @Test(
        "Text that is not a number is invalid",
        arguments: ["", " ", "abc", "1e", "e5", "--1", "+-1", "NaN", "Infinity", ".", "1.2.3", "1,5", "0x10", "1e+-5", "１"]
    )
    func rejectsNonNumbers(text: String) {
        #expect(!DynamoDBNumber.isValid(text))
        #expect(DynamoDBNumber.parts(of: text) == nil)
    }

    @Test("An exponent at the edge of Int is rejected rather than overflowing")
    func extremeExponentIsInvalid() {
        #expect(!DynamoDBNumber.isValid("10e9223372036854775807"))
        #expect(!DynamoDBNumber.isValid("0.01e-9223372036854775808"))
        #expect(!DynamoDBNumber.isValid("1e99999999999999999999"))
    }

    @Test(
        "parts splits the sign, the significant digits and the power of ten of the first digit",
        arguments: [
            PartsCase(text: "0", isNegative: false, digits: [], leadingExponent: 0),
            PartsCase(text: "-0.000", isNegative: false, digits: [], leadingExponent: 0),
            PartsCase(text: "-12.340", isNegative: true, digits: [1, 2, 3, 4], leadingExponent: 1),
            PartsCase(text: "0.00123", isNegative: false, digits: [1, 2, 3], leadingExponent: -3),
            PartsCase(text: "007.50e1", isNegative: false, digits: [7, 5], leadingExponent: 1),
            PartsCase(text: ".5", isNegative: false, digits: [5], leadingExponent: -1),
            PartsCase(text: "5.", isNegative: false, digits: [5], leadingExponent: 0),
            PartsCase(text: "+5", isNegative: false, digits: [5], leadingExponent: 0),
            PartsCase(text: "1E-130", isNegative: false, digits: [1], leadingExponent: -130),
            PartsCase(text: "12000", isNegative: false, digits: [1, 2], leadingExponent: 4)
        ]
    )
    func splitsParts(expected: PartsCase) {
        #expect(
            DynamoDBNumber.parts(of: expected.text)
                == DynamoDBNumber.Parts(
                    isNegative: expected.isNegative,
                    significantDigits: expected.digits,
                    leadingExponent: expected.leadingExponent
                )
        )
    }

    @Test(
        "compare orders by numeric value",
        arguments: [
            ComparisonCase(lhs: "-5", rhs: "3", expected: .orderedAscending),
            ComparisonCase(lhs: "3", rhs: "-5", expected: .orderedDescending),
            ComparisonCase(lhs: "-1", rhs: "0", expected: .orderedAscending),
            ComparisonCase(lhs: "0", rhs: "1e-130", expected: .orderedAscending),
            ComparisonCase(lhs: "-1e-130", rhs: "0", expected: .orderedAscending),
            ComparisonCase(lhs: "1e2", rhs: "99", expected: .orderedDescending),
            ComparisonCase(lhs: "9.9e1", rhs: "1e2", expected: .orderedAscending),
            ComparisonCase(lhs: "-1e2", rhs: "-99", expected: .orderedAscending),
            ComparisonCase(lhs: "0.001", rhs: "0.01", expected: .orderedAscending),
            ComparisonCase(lhs: "9", rhs: "10", expected: .orderedAscending),
            ComparisonCase(lhs: "1.23", rhs: "1.2", expected: .orderedDescending),
            ComparisonCase(lhs: "-1.23", rhs: "-1.2", expected: .orderedAscending),
            ComparisonCase(
                lhs: "12345678901234567890123456789012345678",
                rhs: "12345678901234567890123456789012345677",
                expected: .orderedDescending
            ),
            ComparisonCase(lhs: "1.0", rhs: "1", expected: .orderedSame),
            ComparisonCase(lhs: "1e2", rhs: "100", expected: .orderedSame),
            ComparisonCase(lhs: "100", rhs: "1E+2", expected: .orderedSame),
            ComparisonCase(lhs: "-0", rhs: "0.000", expected: .orderedSame),
            ComparisonCase(lhs: "0.5", rhs: ".5", expected: .orderedSame),
            ComparisonCase(lhs: "+5", rhs: "5.", expected: .orderedSame),
            ComparisonCase(lhs: "007.50e1", rhs: "75", expected: .orderedSame)
        ]
    )
    func comparesNumerically(comparison: ComparisonCase) {
        #expect(DynamoDBNumber.compare(comparison.lhs, comparison.rhs) == comparison.expected)
    }

    @Test(
        "compare is antisymmetric",
        arguments: [
            ComparisonCase(lhs: "-5", rhs: "3", expected: .orderedAscending),
            ComparisonCase(lhs: "1e2", rhs: "99", expected: .orderedDescending),
            ComparisonCase(lhs: "1.0", rhs: "1", expected: .orderedSame)
        ]
    )
    func compareIsAntisymmetric(comparison: ComparisonCase) {
        let forward = DynamoDBNumber.compare(comparison.lhs, comparison.rhs)
        let backward = DynamoDBNumber.compare(comparison.rhs, comparison.lhs)
        #expect(forward.rawValue == -backward.rawValue)
    }

    @Test("areEqual treats different spellings of one value as equal")
    func areEqualIgnoresSpelling() {
        #expect(DynamoDBNumber.areEqual("1.0", "1"))
        #expect(DynamoDBNumber.areEqual("1e2", "100"))
        #expect(DynamoDBNumber.areEqual("-0", "0"))
        #expect(!DynamoDBNumber.areEqual("1", "1.0000000000000000000000000000000000001"))
    }

    @Test("Text that is not a number compares as text")
    func unparseableComparesAsText() {
        #expect(DynamoDBNumber.compare("abc", "abd") == .orderedAscending)
        #expect(DynamoDBNumber.compare("abc", "abc") == .orderedSame)
        #expect(DynamoDBNumber.compare("b", "a") == .orderedDescending)
    }
}
