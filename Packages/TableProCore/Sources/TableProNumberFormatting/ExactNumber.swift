import Foundation

public struct ExactNumber: Sendable, Hashable, Comparable {
    public let decimal: Decimal?
    /// Finite, except for a sum past the `Double` range, which is a signed infinity, and a NaN
    /// `Decimal` passed to `init(decimal:)`.
    public let approximation: Double

    public var isApproximate: Bool { decimal == nil }

    public var plainText: String {
        decimal?.description ?? approximation.description
    }

    public init(decimal: Decimal) {
        guard !decimal.isNaN else {
            self.decimal = nil
            approximation = .nan
            return
        }
        self.decimal = decimal
        approximation = Double(decimal.description) ?? NSDecimalNumber(decimal: decimal).doubleValue
    }

    public init(approximation: Double) {
        decimal = nil
        self.approximation = approximation
    }

    public static func == (lhs: ExactNumber, rhs: ExactNumber) -> Bool {
        guard lhs.approximation == rhs.approximation || (lhs.approximation.isNaN && rhs.approximation.isNaN) else {
            return false
        }
        switch (lhs.decimal, rhs.decimal) {
        case let (left?, right?):
            return DecimalDigits(decimal: left) == DecimalDigits(decimal: right)
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(approximation.isNaN ? Double.nan : approximation)
        hasher.combine(isApproximate)
    }

    /// Orders by the approximation first, which rounding keeps monotonic, so the exact digit
    /// comparison only runs on values that share a `Double`. NaN sorts first.
    public static func < (lhs: ExactNumber, rhs: ExactNumber) -> Bool {
        guard !lhs.approximation.isNaN, !rhs.approximation.isNaN else {
            return lhs.approximation.isNaN && !rhs.approximation.isNaN
        }
        guard lhs.approximation == rhs.approximation else { return lhs.approximation < rhs.approximation }
        switch (lhs.decimal, rhs.decimal) {
        case let (left?, right?):
            return DecimalDigits.compare(DecimalDigits(decimal: left), DecimalDigits(decimal: right)) < 0
        case (nil, .some):
            return true
        default:
            return false
        }
    }
}

public struct ExactNumericSummary: Sendable, Equatable {
    public let count: Int
    public let sum: ExactNumber
    public let minimum: ExactNumber
    public let maximum: ExactNumber
    public let mean: ExactNumber
    public let scale: Int

    public init(count: Int, sum: ExactNumber, minimum: ExactNumber, maximum: ExactNumber, mean: ExactNumber, scale: Int) {
        self.count = count
        self.sum = sum
        self.minimum = minimum
        self.maximum = maximum
        self.mean = mean
        self.scale = scale
    }
}

/// A decimal value as `±digits × 10^exponent`, with no leading or trailing zero digits, so two
/// equal values always have the same fields.
struct DecimalDigits: Sendable, Hashable {
    static let zero = DecimalDigits(isNegative: false, digits: [], exponent: 0)

    let isNegative: Bool
    let digits: [UInt8]
    let exponent: Int

    init(isNegative: Bool, digits: [UInt8], exponent: Int) {
        let first = digits.firstIndex { $0 != 0 }
        guard let first, let last = digits.lastIndex(where: { $0 != 0 }) else {
            self.isNegative = false
            self.digits = []
            self.exponent = 0
            return
        }
        self.isNegative = isNegative
        self.digits = Array(digits[first...last])
        self.exponent = exponent + (digits.count - 1 - last)
    }

    init(mantissa: Int64, scale: Int) {
        var remaining = mantissa.magnitude
        var reversed: [UInt8] = []
        while remaining > 0 {
            reversed.append(UInt8(remaining % 10))
            remaining /= 10
        }
        self.init(isNegative: mantissa < 0, digits: reversed.reversed(), exponent: -scale)
    }

    init(decimal: Decimal) {
        self = Self(literal: decimal.description) ?? .zero
    }

    init?(double: Double) {
        guard double.isFinite else { return nil }
        self.init(literal: double.description)
    }

    init?(literal: String) {
        var text = literal
        let scanned = text.withUTF8 { NumericLiteral.scan($0) }
        switch scanned {
        case .scaled(let mantissa, let scale):
            self.init(mantissa: mantissa, scale: scale)
        case .digits(let value, _):
            self = value
        case nil:
            return nil
        }
    }

    var isZero: Bool { digits.isEmpty }

    /// One past the position of the leading digit: `10^(p-1) <= |x| < 10^p`.
    var leadingPosition: Int { exponent + digits.count }

    var fractionDigitCount: Int { max(0, -exponent) }

    var fitsDecimal: Bool {
        digits.count <= 38 && (-128...127).contains(exponent)
    }

    /// `-15e2` form, which both `Decimal(string:)` and `Double(_:)` read without rounding when
    /// the value fits them.
    var exponentText: String {
        var text = isNegative ? "-" : ""
        text.reserveCapacity(digits.count + 8)
        if digits.isEmpty {
            text += "0"
        } else {
            for digit in digits {
                text.unicodeScalars.append(Unicode.Scalar(digit + 0x30))
            }
        }
        return text + "e" + String(exponent)
    }

    var doubleValue: Double {
        Double(exponentText) ?? 0
    }

    var exactNumber: ExactNumber {
        guard fitsDecimal, let decimal = Decimal(string: exponentText, locale: Self.posix) else {
            return ExactNumber(approximation: doubleValue)
        }
        return ExactNumber(decimal: decimal)
    }

    static func compare(_ lhs: DecimalDigits, _ rhs: DecimalDigits) -> Int {
        let left = lhs.signum
        let right = rhs.signum
        guard left == right else { return left < right ? -1 : 1 }
        let magnitude = compareMagnitude(lhs, rhs)
        return left < 0 ? -magnitude : magnitude
    }

    func rounded(fractionDigits: Int) -> DecimalDigits {
        guard exponent < -fractionDigits else { return self }
        return dropping(-fractionDigits - exponent)
    }

    func rounded(significantDigits: Int) -> DecimalDigits {
        guard digits.count > significantDigits else { return self }
        return dropping(digits.count - significantDigits)
    }

    func plainText(fractionDigits: Int) -> String {
        var integer: ArraySlice<UInt8>
        var fraction: [UInt8]
        if exponent >= 0 {
            integer = ArraySlice(digits + [UInt8](repeating: 0, count: digits.isEmpty ? 0 : exponent))
            fraction = []
        } else if digits.count > -exponent {
            integer = digits[..<(digits.count + exponent)]
            fraction = Array(digits[(digits.count + exponent)...])
        } else {
            integer = []
            fraction = [UInt8](repeating: 0, count: -exponent - digits.count) + digits
        }
        if integer.isEmpty { integer = [0] }
        if fraction.count < fractionDigits {
            fraction += [UInt8](repeating: 0, count: fractionDigits - fraction.count)
        }
        var text = isNegative ? "-" : ""
        text.reserveCapacity(integer.count + fraction.count + 2)
        Self.append(integer, to: &text)
        if !fraction.isEmpty {
            text += "."
            Self.append(fraction[...], to: &text)
        }
        return text
    }

    var scientificText: String {
        guard let first = digits.first else { return "0E0" }
        var text = isNegative ? "-" : ""
        text.unicodeScalars.append(Unicode.Scalar(first + 0x30))
        if digits.count > 1 {
            text += "."
            Self.append(digits.dropFirst(), to: &text)
        }
        return text + "E" + String(leadingPosition - 1)
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    private var signum: Int {
        guard !digits.isEmpty else { return 0 }
        return isNegative ? -1 : 1
    }

    private static func compareMagnitude(_ lhs: DecimalDigits, _ rhs: DecimalDigits) -> Int {
        guard lhs.leadingPosition == rhs.leadingPosition else {
            return lhs.leadingPosition < rhs.leadingPosition ? -1 : 1
        }
        for (left, right) in zip(lhs.digits, rhs.digits) where left != right {
            return left < right ? -1 : 1
        }
        guard lhs.digits.count != rhs.digits.count else { return 0 }
        return lhs.digits.count < rhs.digits.count ? -1 : 1
    }

    /// Drops the last `count` digits, rounding half away from zero like `NSDecimalNumber.plain`.
    private func dropping(_ count: Int) -> DecimalDigits {
        let keep = digits.count - count
        guard keep >= 0 else { return .zero }
        var kept = Array(digits[..<keep])
        if digits[keep] >= 5 {
            var index = kept.count - 1
            while index >= 0, kept[index] == 9 {
                kept[index] = 0
                index -= 1
            }
            if index >= 0 {
                kept[index] += 1
            } else {
                kept.insert(1, at: 0)
            }
        }
        return DecimalDigits(isNegative: isNegative, digits: kept, exponent: exponent + count)
    }

    private static func append(_ digits: ArraySlice<UInt8>, to text: inout String) {
        for digit in digits {
            text.unicodeScalars.append(Unicode.Scalar(digit + 0x30))
        }
    }
}
