import Foundation

public struct NumericSummaryAccumulator: Sendable {
    static let maximumLiteralLength = 256
    private static let fastScaleLimit = 18
    /// Enough digits to pin down any `Double`, so an approximate input adds no error a `Double`
    /// would not.
    private static let approximateDigits = 17
    private static let posix = Locale(identifier: "en_US_POSIX")

    public private(set) var count = 0
    private var buckets = [WideInteger](repeating: WideInteger(), count: fastScaleLimit + 1)
    private var usedScales: UInt32 = 0
    private var exactSum = ExactSum()
    private var hasApproximate = false
    private var fastMinimum: ScaledInteger?
    private var fastMaximum: ScaledInteger?
    private var slowMinimum: DecimalDigits?
    private var slowMaximum: DecimalDigits?
    private var scale = 0

    public init() {}

    public mutating func add(_ text: String) -> Bool {
        var copy = text
        return copy.withUTF8 { add($0) }
    }

    public mutating func add(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let trimmed = Self.trimmingSpaces(bytes)
        guard trimmed.count <= Self.maximumLiteralLength, let literal = NumericLiteral.scan(trimmed) else {
            return false
        }
        switch literal {
        case .scaled(let mantissa, let literalScale):
            addScaled(ScaledInteger(mantissa: mantissa, scale: literalScale))
        case .digits(let value, let literalScale):
            if value.fitsDecimal {
                exactSum.add(value)
            } else {
                guard let double = Double(value.exponentText), double.isFinite else {
                    return false
                }
                if double != 0 {
                    exactSum.add(value.rounded(significantDigits: Self.approximateDigits))
                }
                hasApproximate = true
            }
            if slowMinimum.map({ DecimalDigits.compare(value, $0) < 0 }) ?? true { slowMinimum = value }
            if slowMaximum.map({ DecimalDigits.compare(value, $0) > 0 }) ?? true { slowMaximum = value }
            scale = max(scale, literalScale)
        }
        count += 1
        return true
    }

    public mutating func merge(_ other: NumericSummaryAccumulator) {
        count += other.count
        for index in 0...Self.fastScaleLimit where other.usedScales & (1 << index) != 0 {
            buckets[index].add(other.buckets[index])
        }
        usedScales |= other.usedScales
        exactSum.add(other.exactSum)
        hasApproximate = hasApproximate || other.hasApproximate
        fastMinimum = ScaledInteger.extreme(fastMinimum, other.fastMinimum, keepingLower: true)
        fastMaximum = ScaledInteger.extreme(fastMaximum, other.fastMaximum, keepingLower: false)
        slowMinimum = Self.extreme(slowMinimum, other.slowMinimum, keepingLower: true)
        slowMaximum = Self.extreme(slowMaximum, other.slowMaximum, keepingLower: false)
        scale = max(scale, other.scale)
    }

    public func summary() -> ExactNumericSummary? {
        guard let minimum = Self.extreme(fastMinimum?.digits, slowMinimum, keepingLower: true),
              let maximum = Self.extreme(fastMaximum?.digits, slowMaximum, keepingLower: false)
        else {
            return nil
        }
        var exactTotal = exactSum
        for index in 0...Self.fastScaleLimit where usedScales & (1 << index) != 0 {
            exactTotal.add(buckets[index], scale: index)
        }
        let total = exactTotal.digits
        let isApproximate = hasApproximate || !total.fitsDecimal
        return ExactNumericSummary(
            count: count,
            sum: isApproximate ? ExactNumber(approximation: total.doubleValue) : total.exactNumber,
            minimum: minimum.exactNumber,
            maximum: maximum.exactNumber,
            mean: Self.mean(of: total, count: count, isApproximate: isApproximate),
            scale: scale
        )
    }

    private mutating func addScaled(_ value: ScaledInteger) {
        buckets[value.scale].add(value.mantissa)
        usedScales |= 1 << value.scale
        if fastMinimum.map({ value.compare(to: $0) < 0 }) ?? true { fastMinimum = value }
        if fastMaximum.map({ value.compare(to: $0) > 0 }) ?? true { fastMaximum = value }
        scale = max(scale, value.scale)
    }

    /// Divides the mantissa at exponent zero and shifts the quotient back, because
    /// `NSDecimalDivide` underflows on a tiny dividend whose quotient `Decimal` can still hold.
    private static func mean(of total: DecimalDigits, count: Int, isApproximate: Bool) -> ExactNumber {
        let dividend = total.rounded(significantDigits: 38)
        let mantissa = DecimalDigits(isNegative: dividend.isNegative, digits: dividend.digits, exponent: 0)
        var divisor = Decimal(count)
        var quotient = Decimal()
        guard var numerator = Decimal(string: mantissa.exponentText, locale: posix) else {
            return ExactNumber(approximation: total.doubleValue / Double(count))
        }
        let error = NSDecimalDivide(&quotient, &numerator, &divisor, .plain)
        guard error == .noError || error == .lossOfPrecision, !quotient.isNaN else {
            return ExactNumber(approximation: total.doubleValue / Double(count))
        }
        let shifted = DecimalDigits(decimal: quotient).rounded(significantDigits: 38)
        let mean = DecimalDigits(isNegative: shifted.isNegative, digits: shifted.digits, exponent: shifted.exponent + dividend.exponent)
        return isApproximate ? ExactNumber(approximation: mean.doubleValue) : mean.exactNumber
    }

    private static func extreme(_ lhs: DecimalDigits?, _ rhs: DecimalDigits?, keepingLower: Bool) -> DecimalDigits? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        let order = DecimalDigits.compare(rhs, lhs)
        return (keepingLower ? order < 0 : order > 0) ? rhs : lhs
    }

    private static func trimmingSpaces(_ bytes: UnsafeBufferPointer<UInt8>) -> UnsafeBufferPointer<UInt8> {
        var start = 0
        var end = bytes.count
        while start < end, bytes[start] == 0x20 || bytes[start] == 0x09 {
            start += 1
        }
        while end > start, bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09 {
            end -= 1
        }
        return UnsafeBufferPointer(rebasing: bytes[start..<end])
    }
}

enum NumericLiteral {
    case scaled(mantissa: Int64, scale: Int)
    case digits(DecimalDigits, scale: Int)

    private static let exponentLimit = 100_000_000

    /// `[+-]digits[.digits][(e|E)[+-]digits]`, where either digit run around the point may be
    /// empty but not both. A value whose digits fit an `Int64` at a scale of 0...18 comes back as
    /// a mantissa, the rest as digits.
    static func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> NumericLiteral? {
        let count = bytes.count
        guard count > 0 else { return nil }
        var index = 0
        let isNegative = bytes[0] == 0x2D
        if isNegative || bytes[0] == 0x2B {
            index = 1
        }
        let digitsStart = index
        var mantissa: UInt64 = 0
        var significantCount = 0
        var digitCount = 0
        var fractionCount = 0
        var seenPoint = false
        while index < count {
            let byte = bytes[index]
            let digit = byte &- 0x30
            if digit < 10 {
                if significantCount > 0 || digit != 0 { significantCount += 1 }
                if significantCount <= 19 { mantissa = mantissa &* 10 &+ UInt64(digit) }
                digitCount += 1
                if seenPoint { fractionCount += 1 }
            } else if byte == 0x2E, !seenPoint {
                seenPoint = true
            } else {
                break
            }
            index += 1
        }
        guard digitCount > 0 else { return nil }
        let mantissaEnd = index
        let fastMagnitude = significantCount <= 19 ? Int64(exactly: mantissa) : nil
        guard index < count else {
            if let fastMagnitude, let literal = scaled(fastMagnitude, isNegative: isNegative, exponent: -fractionCount) {
                return literal
            }
            return digits(bytes[digitsStart..<mantissaEnd], isNegative: isNegative, fractionCount: fractionCount, exponent: 0)
        }
        guard bytes[index] == 0x65 || bytes[index] == 0x45 else { return nil }
        index += 1
        var exponentIsNegative = false
        if index < count, bytes[index] == 0x2D || bytes[index] == 0x2B {
            exponentIsNegative = bytes[index] == 0x2D
            index += 1
        }
        var exponent = 0
        let exponentStart = index
        while index < count {
            let digit = bytes[index] &- 0x30
            guard digit < 10 else { return nil }
            exponent = min(exponent * 10 + Int(digit), exponentLimit)
            index += 1
        }
        guard index > exponentStart else { return nil }
        let signedExponent = exponentIsNegative ? -exponent : exponent
        if let fastMagnitude, let literal = scaled(fastMagnitude, isNegative: isNegative, exponent: signedExponent - fractionCount) {
            return literal
        }
        return digits(bytes[digitsStart..<mantissaEnd], isNegative: isNegative, fractionCount: fractionCount, exponent: signedExponent)
    }

    private static func scaled(_ magnitude: Int64, isNegative: Bool, exponent: Int) -> NumericLiteral? {
        let mantissa = isNegative ? -magnitude : magnitude
        if exponent <= 0 {
            guard exponent >= -18 else { return nil }
            return .scaled(mantissa: mantissa, scale: -exponent)
        }
        guard exponent <= 18 else { return nil }
        let (shifted, overflow) = mantissa.multipliedReportingOverflow(by: ScaledInteger.powersOfTen[exponent])
        return overflow ? nil : .scaled(mantissa: shifted, scale: 0)
    }

    private static func digits(
        _ mantissa: Slice<UnsafeBufferPointer<UInt8>>,
        isNegative: Bool,
        fractionCount: Int,
        exponent: Int
    ) -> NumericLiteral {
        var digits: [UInt8] = []
        digits.reserveCapacity(mantissa.count)
        for byte in mantissa where byte != 0x2E {
            digits.append(byte &- 0x30)
        }
        let value = DecimalDigits(isNegative: isNegative, digits: digits, exponent: exponent - fractionCount)
        return .digits(value, scale: max(0, fractionCount - exponent))
    }
}

struct ScaledInteger: Sendable {
    let mantissa: Int64
    let scale: Int

    static let powersOfTen: [Int64] = (0...18).map { power in
        (0..<power).reduce(Int64(1)) { result, _ in result * 10 }
    }

    var digits: DecimalDigits {
        DecimalDigits(mantissa: mantissa, scale: scale)
    }

    func compare(to other: ScaledInteger) -> Int {
        guard scale != other.scale else {
            return mantissa == other.mantissa ? 0 : (mantissa < other.mantissa ? -1 : 1)
        }
        let difference = abs(scale - other.scale)
        if scale < other.scale {
            let (scaled, overflow) = mantissa.multipliedReportingOverflow(by: Self.powersOfTen[difference])
            if overflow { return mantissa < 0 ? -1 : 1 }
            return scaled == other.mantissa ? 0 : (scaled < other.mantissa ? -1 : 1)
        }
        let (scaled, overflow) = other.mantissa.multipliedReportingOverflow(by: Self.powersOfTen[difference])
        if overflow { return other.mantissa < 0 ? 1 : -1 }
        return mantissa == scaled ? 0 : (mantissa < scaled ? -1 : 1)
    }

    static func extreme(_ lhs: ScaledInteger?, _ rhs: ScaledInteger?, keepingLower: Bool) -> ScaledInteger? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        let order = rhs.compare(to: lhs)
        return (keepingLower ? order < 0 : order > 0) ? rhs : lhs
    }
}

/// An exact sum of decimal values. Each addend joins the part for its exponent rounded down to a
/// multiple of nine, so adding never rescales by a large power of ten; the parts align once, when
/// the digits are read.
struct ExactSum: Sendable {
    private var parts: [Int: SignedLimbs] = [:]

    var digits: DecimalDigits {
        guard let lowest = parts.keys.min() else { return .zero }
        var total = SignedLimbs()
        for (exponent, part) in parts {
            var aligned = part
            Limbs.multiply(&aligned.magnitude, byPowerOfTen: exponent - lowest)
            total.add(aligned)
        }
        return DecimalDigits(isNegative: total.isNegative, digits: Limbs.decimalDigits(of: total.magnitude), exponent: lowest)
    }

    mutating func add(_ value: DecimalDigits) {
        add(SignedLimbs(isNegative: value.isNegative, magnitude: Limbs.magnitude(of: value.digits)), exponent: value.exponent)
    }

    mutating func add(_ value: WideInteger, scale: Int) {
        add(SignedLimbs(isNegative: value.isNegative, magnitude: value.magnitude), exponent: -scale)
    }

    mutating func add(_ other: ExactSum) {
        for (exponent, part) in other.parts {
            parts[exponent, default: SignedLimbs()].add(part)
        }
    }

    private mutating func add(_ value: SignedLimbs, exponent: Int) {
        guard !value.magnitude.isEmpty else { return }
        let offset = (exponent % 9 + 9) % 9
        var aligned = value
        Limbs.multiply(&aligned.magnitude, byPowerOfTen: offset)
        parts[exponent - offset, default: SignedLimbs()].add(aligned)
    }
}

struct SignedLimbs: Sendable {
    var isNegative = false
    var magnitude: [UInt32] = []

    mutating func add(_ other: SignedLimbs) {
        guard !other.magnitude.isEmpty else { return }
        guard !magnitude.isEmpty else {
            self = other
            return
        }
        if other.isNegative == isNegative {
            Limbs.add(other.magnitude, to: &magnitude)
        } else if Limbs.compare(magnitude, other.magnitude) >= 0 {
            Limbs.subtract(other.magnitude, from: &magnitude)
            if magnitude.isEmpty { isNegative = false }
        } else {
            var larger = other.magnitude
            Limbs.subtract(magnitude, from: &larger)
            magnitude = larger
            isNegative = other.isNegative
        }
    }
}

/// Unsigned integers as base 2^32 limbs, least significant first, with no trailing zero limbs.
enum Limbs {
    private static let chunkDivisor: UInt32 = 1_000_000_000
    private static let chunkPowers: [UInt32] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, chunkDivisor]

    static func magnitude(of digits: [UInt8]) -> [UInt32] {
        var limbs: [UInt32] = []
        var index = 0
        while index < digits.count {
            let end = min(index + 9, digits.count)
            var chunk: UInt32 = 0
            for digit in digits[index..<end] {
                chunk = chunk * 10 + UInt32(digit)
            }
            multiply(&limbs, by: chunkPowers[end - index], adding: chunk)
            index = end
        }
        return limbs
    }

    static func decimalDigits(of magnitude: [UInt32]) -> [UInt8] {
        var limbs = magnitude
        var chunks: [UInt32] = []
        while !limbs.isEmpty {
            var remainder: UInt64 = 0
            for index in limbs.indices.reversed() {
                let current = remainder << 32 | UInt64(limbs[index])
                limbs[index] = UInt32(current / UInt64(chunkDivisor))
                remainder = current % UInt64(chunkDivisor)
            }
            while limbs.last == 0 { limbs.removeLast() }
            chunks.append(UInt32(remainder))
        }
        var digits: [UInt8] = []
        digits.reserveCapacity(chunks.count * 9)
        for (position, chunk) in chunks.reversed().enumerated() {
            var chunkDigits = [UInt8](repeating: 0, count: 9)
            var value = chunk
            for slot in chunkDigits.indices.reversed() {
                chunkDigits[slot] = UInt8(value % 10)
                value /= 10
            }
            digits += position == 0 ? Array(chunkDigits.drop { $0 == 0 }) : chunkDigits
        }
        return digits
    }

    static func multiply(_ limbs: inout [UInt32], byPowerOfTen power: Int) {
        guard !limbs.isEmpty else { return }
        var remaining = power
        while remaining >= 9 {
            multiply(&limbs, by: chunkDivisor, adding: 0)
            remaining -= 9
        }
        if remaining > 0 {
            multiply(&limbs, by: chunkPowers[remaining], adding: 0)
        }
    }

    static func add(_ addend: [UInt32], to limbs: inout [UInt32]) {
        if limbs.count < addend.count {
            limbs += [UInt32](repeating: 0, count: addend.count - limbs.count)
        }
        var carry: UInt64 = 0
        for index in limbs.indices {
            let sum = UInt64(limbs[index]) + (index < addend.count ? UInt64(addend[index]) : 0) + carry
            limbs[index] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
            if carry == 0, index >= addend.count { break }
        }
        if carry > 0 { limbs.append(UInt32(carry)) }
    }

    /// Requires `limbs >= subtrahend`.
    static func subtract(_ subtrahend: [UInt32], from limbs: inout [UInt32]) {
        var borrow: Int64 = 0
        for index in limbs.indices {
            var difference = Int64(limbs[index]) - (index < subtrahend.count ? Int64(subtrahend[index]) : 0) - borrow
            borrow = difference < 0 ? 1 : 0
            if difference < 0 { difference += 1 << 32 }
            limbs[index] = UInt32(difference)
        }
        while limbs.last == 0 { limbs.removeLast() }
    }

    static func compare(_ lhs: [UInt32], _ rhs: [UInt32]) -> Int {
        guard lhs.count == rhs.count else { return lhs.count < rhs.count ? -1 : 1 }
        for index in lhs.indices.reversed() where lhs[index] != rhs[index] {
            return lhs[index] < rhs[index] ? -1 : 1
        }
        return 0
    }

    private static func multiply(_ limbs: inout [UInt32], by factor: UInt32, adding addend: UInt32) {
        var carry = UInt64(addend)
        for index in limbs.indices {
            let product = UInt64(limbs[index]) * UInt64(factor) + carry
            limbs[index] = UInt32(truncatingIfNeeded: product)
            carry = product >> 32
        }
        if carry > 0 { limbs.append(UInt32(carry)) }
    }
}

/// A two's complement 128-bit sum of `Int64` mantissas, which no count an `Int` can reach overflows.
struct WideInteger: Sendable {
    private var high: Int64 = 0
    private var low: UInt64 = 0

    var isNegative: Bool { high < 0 }

    var magnitude: [UInt32] {
        var upper = UInt64(bitPattern: high)
        var lower = low
        if high < 0 {
            let (negated, carry) = (~lower).addingReportingOverflow(1)
            lower = negated
            upper = ~upper &+ (carry ? 1 : 0)
        }
        var limbs = [lower, upper].flatMap { [UInt32(truncatingIfNeeded: $0), UInt32(truncatingIfNeeded: $0 >> 32)] }
        while limbs.last == 0 { limbs.removeLast() }
        return limbs
    }

    mutating func add(_ value: Int64) {
        let (sum, carry) = low.addingReportingOverflow(UInt64(bitPattern: value))
        low = sum
        high = high &+ (value < 0 ? -1 : 0) &+ (carry ? 1 : 0)
    }

    mutating func add(_ other: WideInteger) {
        let (sum, carry) = low.addingReportingOverflow(other.low)
        low = sum
        high = high &+ other.high &+ (carry ? 1 : 0)
    }
}
