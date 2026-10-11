import Foundation

/// DynamoDB's Number type: up to 38 significant digits, magnitude from 1E-130 to below 1E+126.
///
/// Carried as text end to end. A `Double` holds about 15 digits, so reading a Number through one
/// turns `12345678901234567890123456789012345678` into `...7525491324606797053952`.
enum DynamoDBNumber {
    static let maximumSignificantDigits = 38
    static let smallestExponent = -130
    static let largestExponent = 125

    struct Parts: Equatable {
        let isNegative: Bool
        let significantDigits: [UInt8]
        let leadingExponent: Int
    }

    static func isValid(_ text: String) -> Bool {
        guard let parts = parts(of: text) else { return false }
        guard !parts.significantDigits.isEmpty else { return true }
        guard parts.significantDigits.count <= maximumSignificantDigits else { return false }
        return (smallestExponent...largestExponent).contains(parts.leadingExponent)
    }

    /// Splits a number into sign, significant digits and the power of ten of its first digit, or nil
    /// when the text is not a number at all. Zero has no significant digits.
    static func parts(of text: String) -> Parts? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var scalars = Substring(trimmed)
        var isNegative = false
        if let sign = scalars.first, sign == "-" || sign == "+" {
            isNegative = sign == "-"
            scalars = scalars.dropFirst()
        }
        var mantissa = scalars
        var exponent = 0
        if let marker = scalars.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = scalars[..<marker]
            let exponentText = scalars[scalars.index(after: marker)...]
            guard !exponentText.isEmpty, let parsed = Int(exponentText) else { return nil }
            exponent = parsed
        }
        let pieces = mantissa.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { return nil }
        let integerPart = pieces[0]
        let fractionPart = pieces.count == 2 ? pieces[1] : ""
        guard !(integerPart.isEmpty && fractionPart.isEmpty) else { return nil }
        guard (integerPart + fractionPart).allSatisfy(\.isASCIIDigitCharacter) else { return nil }

        let digits = (integerPart + fractionPart).compactMap { $0.wholeNumberValue.map(UInt8.init) }
        guard let firstNonZero = digits.firstIndex(where: { $0 != 0 }) else {
            return Parts(isNegative: false, significantDigits: [], leadingExponent: 0)
        }
        let lastNonZero = digits.lastIndex(where: { $0 != 0 }) ?? firstNonZero
        let significant = Array(digits[firstNonZero...lastNonZero])
        let (leadingExponent, overflow) = (integerPart.count - 1 - firstNonZero).addingReportingOverflow(exponent)
        guard !overflow else { return nil }
        return Parts(isNegative: isNegative, significantDigits: significant, leadingExponent: leadingExponent)
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let left = parts(of: lhs), let right = parts(of: rhs) else {
            return lhs < rhs ? .orderedAscending : (lhs == rhs ? .orderedSame : .orderedDescending)
        }
        let leftSign = left.significantDigits.isEmpty ? 0 : (left.isNegative ? -1 : 1)
        let rightSign = right.significantDigits.isEmpty ? 0 : (right.isNegative ? -1 : 1)
        if leftSign != rightSign {
            return leftSign < rightSign ? .orderedAscending : .orderedDescending
        }
        guard leftSign != 0 else { return .orderedSame }
        let magnitude = compareMagnitude(left, right)
        return leftSign > 0 ? magnitude : magnitude.reversed
    }

    static func areEqual(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedSame
    }

    private static func compareMagnitude(_ left: Parts, _ right: Parts) -> ComparisonResult {
        if left.leadingExponent != right.leadingExponent {
            return left.leadingExponent < right.leadingExponent ? .orderedAscending : .orderedDescending
        }
        let count = max(left.significantDigits.count, right.significantDigits.count)
        for index in 0..<count {
            let leftDigit = index < left.significantDigits.count ? left.significantDigits[index] : 0
            let rightDigit = index < right.significantDigits.count ? right.significantDigits[index] : 0
            if leftDigit != rightDigit {
                return leftDigit < rightDigit ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool {
        guard let ascii = asciiValue else { return false }
        return (48...57).contains(ascii)
    }
}

private extension ComparisonResult {
    var reversed: ComparisonResult {
        switch self {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
